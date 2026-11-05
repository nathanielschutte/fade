use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    extract::{Extension, FromRequestParts, State},
    http::{header::AUTHORIZATION, request::Parts, HeaderMap},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;
use std::{
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::sync::Semaphore;

use crate::{
    db::{is_base64, now, UserPublic},
    error::{AppError, AppResult},
    ratelimit::ClientInfo,
    SharedState,
};

/// Authenticated caller. Add it as a handler argument to require a valid session.
/// Clients send `Authorization: Bearer <token>`; the same works for a future mobile app.
pub struct AuthUser(pub UserPublic);

impl FromRequestParts<SharedState> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &SharedState,
    ) -> Result<Self, Self::Rejection> {
        let token = bearer_token(&parts.headers).ok_or(AppError::Unauthorized)?;
        user_for_token(&state.db, token, state.config.session_days)
            .await?
            .map(AuthUser)
            .ok_or(AppError::Unauthorized)
    }
}

pub fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|t| !t.is_empty())
}

pub fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// What someone whose account an Admin turned off sees when they try to get in.
pub const TURNED_OFF: &str =
    "This account has been turned off. Ask whoever runs napsack to turn it back on.";

/// Who a session token belongs to, if it's live. A session in use renews:
/// at most once an hour it notes the use and pushes its end out to
/// `session_days` from now, so a device that's used never gets signed out.
pub async fn user_for_token(
    db: &SqlitePool,
    token: &str,
    session_days: i64,
) -> sqlx::Result<Option<UserPublic>> {
    let at = now();
    let user = sqlx::query_as::<_, UserPublic>(
        "SELECT u.id, u.username FROM sessions s JOIN users u ON u.id = s.user_id
         WHERE s.token_hash = ? AND s.expires_at > ? AND s.revoked_at IS NULL
           AND NOT EXISTS (SELECT 1 FROM deactivations d WHERE d.user_id = u.id AND d.reactivated_at IS NULL)",
    )
    .bind(hash_token(token))
    .bind(at)
    .fetch_optional(db)
    .await?;
    if user.is_some() {
        sqlx::query(
            "UPDATE sessions SET last_used_at = ?1, expires_at = MAX(expires_at, ?1 + ?2)
             WHERE token_hash = ?3 AND (last_used_at IS NULL OR last_used_at < ?1 - 3600)",
        )
        .bind(at)
        .bind(session_days * 86_400)
        .bind(hash_token(token))
        .execute(db)
        .await?;
    }
    if let Some(u) = &user {
        // Coarse on purpose: one write a minute per user at most.
        sqlx::query(
            "UPDATE users SET last_seen_at = ?
             WHERE id = ? AND (last_seen_at IS NULL OR last_seen_at < ?)",
        )
        .bind(at)
        .bind(u.id)
        .bind(at - 60)
        .execute(db)
        .await?;
    }
    Ok(user)
}

/// Password checks (Argon2) running at once, whole server: one per CPU,
/// from 2 to 4. Each takes about 19 MiB for its moment, so without a bound a
/// burst of sign-ins could take the server past its 400 MB memory ceiling
/// (40 at once reached 840 MB). They're CPU-bound, so more at once than CPUs
/// buys nothing: production's two vCPUs get two (38 MiB at most), and no
/// machine more than four (76 MiB).
pub const ARGON2_AT_ONCE: std::ops::RangeInclusive<usize> = 2..=4;
/// How long a password check waits for its turn before "busy".
const ARGON2_WAIT: Duration = Duration::from_secs(5);
pub const BUSY: &str = "napsack is busy. Try again in a moment.";

fn argon2_permits(cpus: usize) -> usize {
    cpus.clamp(*ARGON2_AT_ONCE.start(), *ARGON2_AT_ONCE.end())
}

fn argon2_gate() -> &'static Arc<Semaphore> {
    static GATE: OnceLock<Arc<Semaphore>> = OnceLock::new();
    GATE.get_or_init(|| {
        let cpus = std::thread::available_parallelism().map_or(2, |n| n.get());
        Arc::new(Semaphore::new(argon2_permits(cpus)))
    })
}

/// Runs `work` off the async workers once `gate` lets it in, waiting up to
/// `wait`; past that, 503 busy. The permit goes with the work, so it's held
/// until the work ends even if the request that asked for it is dropped.
async fn gated<T: Send + 'static>(
    gate: &Arc<Semaphore>,
    wait: Duration,
    work: impl FnOnce() -> T + Send + 'static,
) -> AppResult<T> {
    let permit = match tokio::time::timeout(wait, gate.clone().acquire_owned()).await {
        Ok(Ok(permit)) => permit,
        _ => {
            tracing::warn!("password check refused: too many at once");
            return Err(AppError::Unavailable(BUSY.into()));
        }
    };
    Ok(tokio::task::spawn_blocking(move || {
        let _permit = permit;
        work()
    })
    .await?)
}

/// Argon2 of a high-entropy derived key (an auth key or a recovery auth key),
/// off the async workers, a few at a time. A leaked database can't be replayed.
pub async fn hash_secret(secret: String) -> AppResult<String> {
    gated(argon2_gate(), ARGON2_WAIT, move || {
        let salt = SaltString::generate(&mut OsRng);
        Argon2::default()
            .hash_password(secret.as_bytes(), &salt)
            .map(|h| h.to_string())
    })
    .await?
    .map_err(|e| AppError::Internal(format!("hash: {e}")))
}

pub async fn verify_secret(stored: String, given: String) -> AppResult<bool> {
    gated(argon2_gate(), ARGON2_WAIT, move || {
        PasswordHash::new(&stored)
            .map(|parsed| {
                Argon2::default()
                    .verify_password(given.as_bytes(), &parsed)
                    .is_ok()
            })
            .unwrap_or(false)
    })
    .await
}

pub async fn create_session(state: &SharedState, user_id: i64) -> AppResult<String> {
    let mut raw = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut raw);
    let token = URL_SAFE_NO_PAD.encode(raw);
    let created = now();
    sqlx::query(
        "INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
    )
    .bind(hash_token(&token))
    .bind(user_id)
    .bind(created)
    .bind(created + state.config.session_days * 86_400)
    .execute(&state.db)
    .await?;
    // Up to 10 devices per person; a new sign-in past that ends the one used least recently (guard.rs).
    crate::guard::trim_sessions(state, user_id, state.config.limits.max_sessions).await?;
    Ok(token)
}

/// The client never sends the password. It runs the password through PBKDF2
/// and sends one derived key (`auth_key`) to sign in. A second derived key,
/// which never leaves the device, wraps the private key.
#[derive(Deserialize)]
pub struct Register {
    username: String,
    auth_key: String,
    invite_code: Option<String>,
    /// From an invite link (`/i/<token>`): stands in for the invite code, and
    /// makes the new account friends with whoever made the link (invites.rs).
    invite_token: Option<String>,
    /// SPKI, base64. Friends encrypt to this.
    public_key: String,
    /// PKCS#8 private key, AES-GCM encrypted by the client, base64.
    wrapped_private_key: String,
}

#[derive(Deserialize)]
pub struct Login {
    username: String,
    auth_key: String,
}

#[derive(Serialize)]
pub struct SessionResponse {
    pub token: String,
    pub user: Me,
    pub public_key: String,
    pub wrapped_private_key: String,
}

/// The signed-in user as they see themselves.
#[derive(Serialize)]
pub struct Me {
    id: i64,
    username: String,
    /// Kept for older clients; `role` says more.
    is_admin: bool,
    /// "user", "power" or "admin" (roles.md): shows the System link and its
    /// tabs. The server checks again on every request.
    role: crate::roles::Role,
    /// What your friends see you as (people.rs).
    display_name: Option<String>,
    avatar_id: Option<i64>,
    /// Whether a recovery key is set (account.rs). The app nudges until it is.
    has_recovery_key: bool,
    /// When an admin reset gave this account a new key; messages from before can't be read.
    key_reset_at: Option<i64>,
    /// Friends see when you're active and typing (presence.rs).
    share_activity: bool,
}

impl Me {
    pub async fn load(state: &SharedState, user: UserPublic) -> AppResult<Self> {
        let role = crate::roles::role_of(state, &user).await?;
        let is_admin = role == crate::roles::Role::Admin;
        let (display_name, avatar_id) = crate::people::own_profile(&state.db, user.id).await?;
        let (has_recovery_key, key_reset_at, share_activity): (bool, Option<i64>, bool) = sqlx::query_as(
            "SELECT recovery_hash IS NOT NULL, key_reset_at, share_activity FROM users WHERE id = ?",
        )
        .bind(user.id)
        .fetch_one(&state.db)
        .await?;
        Ok(Self {
            id: user.id,
            username: user.username,
            is_admin,
            role,
            display_name,
            avatar_id,
            has_recovery_key,
            key_reset_at,
            share_activity,
        })
    }
}

/// Auth keys are 32 bytes, base64 (44 chars). Allow some slack for future formats.
pub fn validate_auth_key(key: &str) -> AppResult<()> {
    if is_base64(key, 128) {
        Ok(())
    } else {
        Err(AppError::bad(
            "Sign-in data was malformed. Reload the page and try again.",
        ))
    }
}

pub(crate) fn validate_username(name: &str) -> AppResult<()> {
    let ok_len = (3..=20).contains(&name.len());
    let ok_chars = name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.');
    if ok_len && ok_chars {
        Ok(())
    } else {
        Err(AppError::bad(
            "Usernames are 3 to 20 characters: letters, numbers, dots, and underscores.",
        ))
    }
}

/// A username someone typed to sign in or recover with, checked before it's
/// counted, logged, or looked up: one that can't exist gets `wrong` at once,
/// and is never kept (a megabyte "name" would otherwise sit in the limiter
/// and the log viewer).
pub(crate) fn typed_username(name: &str, wrong: &'static str) -> AppResult<String> {
    let name = name.trim();
    if validate_username(name).is_err() {
        tracing::info!(length = name.len(), "username malformed");
        return Err(AppError::bad(wrong));
    }
    Ok(name.to_owned())
}

/// Compare digests rather than raw strings so the check takes the same time either way.
fn same_secret(a: &str, b: &str) -> bool {
    Sha256::digest(a.as_bytes()) == Sha256::digest(b.as_bytes())
}

pub const TOO_MANY: &str = "Too many attempts. Wait a few minutes and try again.";
const WRONG_SIGN_IN: &str = "Wrong username or password.";

/// Sign-in and sign-up attempts per address. Local, un-proxied requests
/// (development and tests) aren't limited by address.
pub fn check_ip(state: &SharedState, who: &ClientInfo, action: &str) -> AppResult<()> {
    if who.local || state.auth_ip_limit.allow(&who.ip) {
        Ok(())
    } else {
        tracing::warn!(ip = %who.ip, action, "rate limited");
        Err(AppError::TooManyRequests(TOO_MANY.into()))
    }
}

pub async fn register(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
    Json(req): Json<Register>,
) -> AppResult<Json<SessionResponse>> {
    check_ip(&state, &who, "sign-up")?;
    // First, so nothing below logs or looks up a name that can't exist.
    let username = req.username.trim().to_string();
    validate_username(&username)?;
    let invite = match req.invite_token.as_deref() {
        Some(token) => Some(crate::invites::find_valid(&state.db, token).await?.ok_or_else(|| {
            tracing::info!(ip = %who.ip, ?username, "sign-up rejected: invite link not valid");
            AppError::bad("That invite link has expired, been used up, or been turned off.")
        })?),
        None => None,
    };
    if let (Some(expected), None) = (&state.config.invite_code, &invite) {
        let given = req.invite_code.as_deref().unwrap_or("").trim();
        if !same_secret(given, expected) {
            tracing::info!(ip = %who.ip, ?username, "sign-up rejected: wrong invite code");
            return Err(AppError::bad("That invite code isn't valid."));
        }
    }

    // Someone's old username stays theirs (usernames.rs).
    if crate::usernames::past_holder(&state.db, &username)
        .await?
        .is_some()
        // A deleted account's, held for 30 days (deletion.rs).
        || crate::deletion::held(&state.db, &username).await?
    {
        return Err(AppError::bad("That username is taken."));
    }
    if crate::guard::accounts_full(&state.db, state.config.limits.max_accounts).await? {
        tracing::warn!(ip = %who.ip, max = state.config.limits.max_accounts, "sign-up refused: account cap reached");
        return Err(AppError::Unavailable(
            "napsack isn't taking new accounts right now.".into(),
        ));
    }
    validate_auth_key(&req.auth_key)?;
    // P-256 SPKI is 91 bytes; a wrapped PKCS#8 key is ~180. Generous caps.
    if !is_base64(&req.public_key, 512) || !is_base64(&req.wrapped_private_key, 2048) {
        return Err(AppError::bad(
            "Key data was malformed. Reload the page and try again.",
        ));
    }

    let hash = hash_secret(req.auth_key).await?;

    let inserted = sqlx::query_as::<_, UserPublic>(
        "INSERT INTO users (username, auth_hash, public_key, wrapped_private_key, created_at)
         VALUES (?, ?, ?, ?, ?)
         RETURNING id, username",
    )
    .bind(&username)
    .bind(&hash)
    .bind(&req.public_key)
    .bind(&req.wrapped_private_key)
    .bind(now())
    .fetch_one(&state.db)
    .await;

    let user = match inserted {
        Ok(u) => u,
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            tracing::debug!(?username, "sign-up rejected: username taken");
            return Err(AppError::Conflict("That username is taken.".into()));
        }
        Err(e) => return Err(e.into()),
    };

    let token = create_session(&state, user.id).await?;
    tracing::info!(ip = %who.ip, user_id = user.id, username = %user.username, invited = invite.is_some(), "account created");
    if let Some((invite_id, inviter)) = &invite {
        crate::invites::record_use(&state.db, *invite_id, user.id, "signed_up").await?;
        crate::invites::befriend_inviter(&state, &user, inviter).await?;
    }
    Ok(Json(SessionResponse {
        token,
        user: Me::load(&state, user).await?,
        public_key: req.public_key,
        wrapped_private_key: req.wrapped_private_key,
    }))
}

pub async fn login(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
    Json(req): Json<Login>,
) -> AppResult<Json<SessionResponse>> {
    check_ip(&state, &who, "sign-in")?;
    let name = typed_username(&req.username, WRONG_SIGN_IN)?;
    // Failed sign-ins per username, whatever address they come from. An
    // attempt is counted before the (slow) password check, so guessing can't
    // burn the CPU, and attempts made at once can't all slip under the limit;
    // the right password gives its attempt back.
    let account = name.to_lowercase();
    let Some(attempt) = state.login_fail_limit.reserve(&account) else {
        tracing::warn!(ip = %who.ip, username = ?account, "sign-in rate limited");
        return Err(AppError::TooManyRequests(TOO_MANY.into()));
    };
    let failed = |reason: &str| {
        tracing::info!(ip = %who.ip, username = ?account, reason, "sign-in failed");
        AppError::bad(WRONG_SIGN_IN)
    };
    validate_auth_key(&req.auth_key).map_err(|_| failed("malformed key"))?;

    let row: Option<(i64, String, String, String, String)> = sqlx::query_as(
        "SELECT id, username, auth_hash, public_key, wrapped_private_key
         FROM users WHERE username = ?",
    )
    .bind(&name)
    .fetch_optional(&state.db)
    .await?;
    let Some((id, username, stored, public_key, wrapped_private_key)) = row else {
        // An old username: its owner signs in with the new one (which isn't
        // said here; they know it).
        if crate::usernames::past_holder(&state.db, &name)
            .await?
            .is_some()
        {
            tracing::info!(ip = %who.ip, username = ?account, "sign-in with an old username");
            return Err(AppError::bad(
                "That username was changed. Sign in with the new one.",
            ));
        }
        return Err(failed("no such user"));
    };

    // Team Napsack and the like never sign in (team.rs).
    if crate::team::is_system(&state.db, id).await? {
        return Err(failed("system account"));
    }
    if !verify_secret(stored, req.auth_key).await? {
        return Err(failed("wrong password"));
    }
    state.login_fail_limit.refund(&account, attempt);
    // Said only after the right password, so it reveals nothing to a guesser.
    if let Some(why) = crate::admin_users::refusal(&state.db, id).await? {
        tracing::info!(ip = %who.ip, user_id = id, "sign-in refused: account turned off");
        return Err(AppError::bad(why));
    }

    // The wrapped key is only useful with the password, which the server never sees.
    let token = create_session(&state, id).await?;
    tracing::info!(ip = %who.ip, user_id = id, %username, "signed in");
    Ok(Json(SessionResponse {
        token,
        user: Me::load(&state, UserPublic { id, username }).await?,
        public_key,
        wrapped_private_key,
    }))
}

pub async fn logout(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> AppResult<Json<serde_json::Value>> {
    if let Some(token) = bearer_token(&headers) {
        let hash = hash_token(token);
        // Revoked, not removed: the session row stays as a record.
        let ended: Option<i64> = sqlx::query_scalar(
            "UPDATE sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL
             RETURNING user_id",
        )
        .bind(now())
        .bind(&hash)
        .fetch_optional(&state.db)
        .await?;
        crate::push::end_for_session(&state.db, &hash).await?;
        // Its live connections close too, as when any other session ends.
        if let Some(user_id) = ended {
            state.hub.end_session(user_id, &hash);
        }
        tracing::debug!(ended = ended.is_some(), "signed out");
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn me(State(state): State<SharedState>, AuthUser(user): AuthUser) -> AppResult<Json<Me>> {
    Ok(Json(Me::load(&state, user).await?))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A session in use renews: its end moves out to a year from now (at most
    /// once an hour); one that isn't used keeps its end.
    #[tokio::test]
    async fn a_session_in_use_renews() {
        let db = crate::db::tests::temp_db().await;
        sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (1, 'ana', 'h', 'k', 'w', 0)")
            .execute(&db).await.unwrap();
        let soon = now() + 86_400;
        for token in ["used", "idle"] {
            sqlx::query("INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, 1, 0, ?)")
                .bind(hash_token(token)).bind(soon).execute(&db).await.unwrap();
        }
        assert_eq!(
            user_for_token(&db, "used", 365).await.unwrap().unwrap().id,
            1
        );
        let ends = |t: &'static str| {
            let db = db.clone();
            async move {
                sqlx::query_as::<_, (i64, Option<i64>)>(
                    "SELECT expires_at, last_used_at FROM sessions WHERE token_hash = ?",
                )
                .bind(hash_token(t))
                .fetch_one(&db)
                .await
                .unwrap()
            }
        };
        let (until, used) = ends("used").await;
        assert!(until >= now() + 364 * 86_400 && used.is_some());
        assert_eq!(ends("idle").await, (soon, None));
        // Within the hour: no second write.
        sqlx::query("UPDATE sessions SET expires_at = 5 + expires_at WHERE token_hash = ?")
            .bind(hash_token("used"))
            .execute(&db)
            .await
            .unwrap();
        user_for_token(&db, "used", 365).await.unwrap();
        assert_eq!(ends("used").await.0, until + 5);
    }

    #[test]
    fn usernames() {
        for ok in ["nate", "a_b.c", "abc", "x2345678901234567890"] {
            assert!(validate_username(ok).is_ok(), "{ok}");
        }
        for bad in [
            "ab",
            "x23456789012345678901",
            "has space",
            "dash-name",
            "émile",
            "",
        ] {
            assert!(validate_username(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn auth_keys_are_base64_and_bounded() {
        // What the client sends: 32 bytes, standard base64.
        assert!(validate_auth_key("q3V0Jm9XcLk2eY1aGfQ8m0Ht2pWQv4Lr1nZ7uIcS0dE=").is_ok());
        assert!(validate_auth_key("correct horse battery staple").is_err());
        assert!(validate_auth_key(&"A".repeat(132)).is_err());
    }

    #[test]
    fn tokens_hash_to_stable_hex() {
        let h = hash_token("abc");
        assert_eq!(h.len(), 64);
        assert_eq!(h, hash_token("abc"));
        assert_ne!(h, hash_token("abd"));
        // SHA-256("abc"), so a change to the scheme can't slip by unnoticed.
        assert_eq!(
            h,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    /// However many password checks arrive at once, only `permits` run at a
    /// time; one that can't get a turn in time is turned away as busy.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn password_checks_run_a_few_at_a_time() {
        use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
        let gate = Arc::new(Semaphore::new(2));
        let (running, most) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
        let checks: Vec<_> = (0..12)
            .map(|_| {
                let (gate, running, most) = (gate.clone(), running.clone(), most.clone());
                tokio::spawn(async move {
                    gated(&gate, Duration::from_secs(30), move || {
                        let now = running.fetch_add(1, SeqCst) + 1;
                        most.fetch_max(now, SeqCst);
                        std::thread::sleep(Duration::from_millis(30));
                        running.fetch_sub(1, SeqCst);
                    })
                    .await
                })
            })
            .collect();
        for check in checks {
            assert!(check.await.unwrap().is_ok());
        }
        assert_eq!(most.load(SeqCst), 2);

        // Both turns taken and not given back in time: busy (503).
        let _a = gate.clone().acquire_owned().await.unwrap();
        let _b = gate.clone().acquire_owned().await.unwrap();
        let busy = gated(&gate, Duration::from_millis(20), || ()).await;
        assert!(matches!(busy, Err(AppError::Unavailable(m)) if m == BUSY));

        // One per CPU, from 2 to 4: production's two vCPUs get two.
        assert_eq!([1, 2, 3, 16].map(argon2_permits), [2, 2, 3, 4]);
    }

    #[test]
    fn typed_usernames_that_cant_exist_are_refused_first() {
        assert_eq!(typed_username("  Ana_1 ", WRONG_SIGN_IN).unwrap(), "Ana_1");
        for bad in ["x".repeat(10_000), "a b".into(), "".into(), "émile".into()] {
            assert!(typed_username(&bad, WRONG_SIGN_IN).is_err());
        }
    }

    #[test]
    fn secrets_compare_by_value() {
        assert!(same_secret("letmein", "letmein"));
        assert!(!same_secret("letmein", "letmeout"));
        assert!(!same_secret("", "letmein"));
    }
}
