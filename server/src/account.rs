//! Account recovery and safety (F2, F8): change password, recovery keys,
//! admin-issued reset codes, and signing out other devices.
//!
//! The server never sees a password or a recovery key, only keys derived from
//! them (shared/crypto/crypto.js), the same way sign-in works. Two ways back
//! in for someone who forgot their password:
//! - Their recovery key: unwraps a second copy of their private key, so
//!   everything comes back, history included.
//! - A reset code from an admin: they get the account and friends back with a
//!   new key pair. Old messages can't be read any more (nobody else holds the
//!   old key), and friends see a changed safety code.
//!
//! Every credential an account ever had is kept in `credential_history`
//! before it's replaced (Rule 1): someone who later remembers an old password
//! could still unlock the history it protected.

use axum::{
    extract::{Extension, Path, State},
    http::HeaderMap,
    Json,
};
use rand::RngCore;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sqlx::SqliteConnection;

use crate::{
    auth::{
        self, bearer_token, check_ip, create_session, hash_secret, validate_auth_key,
        verify_secret, AuthUser, Me, SessionResponse,
    },
    db::{is_base64, now, UserPublic},
    error::{AppError, AppResult},
    ratelimit::ClientInfo,
    ws::Event,
    SharedState,
};

/// How long an admin's reset code works.
const RESET_CODE_SECS: i64 = 24 * 3600;

/// Copies the account's current credentials into the history before a change.
async fn keep_history(db: &mut SqliteConnection, user: i64, reason: &str) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO credential_history
            (user_id, auth_hash, public_key, wrapped_private_key, recovery_hash, recovery_wrapped_key, replaced_at, reason)
         SELECT id, auth_hash, public_key, wrapped_private_key, recovery_hash, recovery_wrapped_key, ?, ?
         FROM users WHERE id = ?",
    )
    .bind(now())
    .bind(reason)
    .bind(user)
    .execute(db)
    .await?;
    Ok(())
}

/// Ends every session for `user` except `keep` (a token hash), and closes
/// their live connections. Returns how many sessions ended.
pub(crate) async fn end_sessions(
    state: &SharedState,
    user: i64,
    keep: Option<&str>,
) -> sqlx::Result<u64> {
    let ended = sqlx::query(
        "UPDATE sessions SET revoked_at = ?
         WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ? AND token_hash != ?",
    )
    .bind(now())
    .bind(user)
    .bind(now())
    .bind(keep.unwrap_or(""))
    .execute(&state.db)
    .await?
    .rows_affected();
    state.hub.end_sessions(user, keep);
    Ok(ended)
}

fn malformed() -> AppError {
    AppError::bad("Key data was malformed. Reload the page and try again.")
}

fn check_wrapped(b64: &str) -> AppResult<()> {
    if is_base64(b64, 2048) {
        Ok(())
    } else {
        Err(malformed())
    }
}

/// The caller's current password, proven by its auth key. Failures count
/// toward the same per-username limit as sign-in.
async fn require_password(state: &SharedState, me: &UserPublic, auth_key: &str) -> AppResult<()> {
    let account = me.username.to_lowercase();
    if state.login_fail_limit.exhausted(&account) {
        return Err(AppError::TooManyRequests(auth::TOO_MANY.into()));
    }
    validate_auth_key(auth_key)?;
    let stored: String = sqlx::query_scalar("SELECT auth_hash FROM users WHERE id = ?")
        .bind(me.id)
        .fetch_one(&state.db)
        .await?;
    if verify_secret(stored, auth_key.to_owned()).await? {
        Ok(())
    } else {
        state.login_fail_limit.allow(&account);
        tracing::info!(user_id = me.id, "password check failed");
        Err(AppError::bad("Your current password isn't right."))
    }
}

fn session_hash(headers: &HeaderMap) -> Option<String> {
    bearer_token(headers).map(auth::hash_token)
}

// ---------- signed in ----------

#[derive(Deserialize)]
pub struct Unlock {
    auth_key: String,
}

/// `POST /api/auth/unlock`: signed in *and* the password. Returns the
/// password-wrapped private key (as sign-in does), so the client can wrap it
/// again: under a new password, or for a recovery key.
pub async fn unlock(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<Unlock>,
) -> AppResult<Json<Value>> {
    require_password(&state, &me, &req.auth_key).await?;
    let wrapped: String = sqlx::query_scalar("SELECT wrapped_private_key FROM users WHERE id = ?")
        .bind(me.id)
        .fetch_one(&state.db)
        .await?;
    Ok(Json(json!({ "wrapped_private_key": wrapped })))
}

#[derive(Deserialize)]
pub struct ChangePassword {
    auth_key: String,
    new_auth_key: String,
    new_wrapped_private_key: String,
}

/// `POST /api/me/password`: the same private key, wrapped by the new password.
/// Every other session ends.
pub async fn change_password(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    headers: HeaderMap,
    Json(req): Json<ChangePassword>,
) -> AppResult<Json<Value>> {
    require_password(&state, &me, &req.auth_key).await?;
    validate_auth_key(&req.new_auth_key)?;
    check_wrapped(&req.new_wrapped_private_key)?;
    let hash = hash_secret(req.new_auth_key).await?;
    let mut tx = crate::db::write_tx(&state.db).await?;
    keep_history(&mut tx, me.id, "password_changed").await?;
    sqlx::query("UPDATE users SET auth_hash = ?, wrapped_private_key = ? WHERE id = ?")
        .bind(&hash)
        .bind(&req.new_wrapped_private_key)
        .bind(me.id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    let ended = end_sessions(&state, me.id, session_hash(&headers).as_deref()).await?;
    tracing::info!(user_id = me.id, sessions_ended = ended, "password changed");
    Ok(Json(json!({ "sessions_ended": ended })))
}

#[derive(Deserialize)]
pub struct Rename {
    username: String,
    /// The password, proven under the current username.
    auth_key: String,
    /// The same password under the new username (it's the salt), and the
    /// private key locked again with it.
    new_auth_key: String,
    new_wrapped_private_key: String,
}

/// `POST /api/me/username`: a new username (plan X30). It works like a
/// password change, because the username salts the password. The old name
/// is kept, reserved for this person forever (usernames.rs). Once a week,
/// except for Admins. Sessions stay signed in.
pub async fn rename(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<Rename>,
) -> AppResult<Json<Value>> {
    use crate::usernames;
    let username = req.username.trim().to_owned();
    auth::validate_username(&username)?;
    if username.eq_ignore_ascii_case(&me.username) {
        return Err(AppError::bad("That's already your username."));
    }
    require_password(&state, &me, &req.auth_key).await?;
    validate_auth_key(&req.new_auth_key)?;
    check_wrapped(&req.new_wrapped_private_key)?;
    let admin = usernames::is_listed_admin(&state.db, &state.admins, me.id, &me.username).await?;
    let at = now();
    if let Some(last) = usernames::last_rename(&state.db, me.id).await? {
        if !admin && at - last < usernames::RENAME_EVERY_SECS {
            let days = (usernames::RENAME_EVERY_SECS - (at - last) + 86_399) / 86_400;
            return Err(AppError::bad(format!(
                "You can change your username once a week. Try again in {days} {}.",
                if days == 1 { "day" } else { "days" }
            )));
        }
    }
    if !usernames::available_to(&state.db, me.id, &username).await? {
        return Err(AppError::bad("That username is taken."));
    }
    let hash = hash_secret(req.new_auth_key).await?;
    let mut tx = crate::db::write_tx(&state.db).await?;
    // The credentials change exactly as in a password change (the username
    // is the password's salt), and past_usernames records the rename itself.
    // credential_history's reasons are fixed by a CHECK in its table.
    keep_history(&mut tx, me.id, "password_changed").await?;
    // Going back to one of your own old names: it's already reserved for you.
    sqlx::query("INSERT OR IGNORE INTO past_usernames (user_id, username, until) VALUES (?, ?, ?)")
        .bind(me.id)
        .bind(&me.username)
        .bind(at)
        .execute(&mut *tx)
        .await?;
    let renamed = sqlx::query(
        "UPDATE users SET username = ?, auth_hash = ?, wrapped_private_key = ? WHERE id = ?",
    )
    .bind(&username)
    .bind(&hash)
    .bind(&req.new_wrapped_private_key)
    .bind(me.id)
    .execute(&mut *tx)
    .await;
    match renamed {
        Ok(_) => tx.commit().await?,
        // Someone took it in the moment between the check and now.
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            return Err(AppError::bad("That username is taken."))
        }
        Err(e) => return Err(e.into()),
    }
    tracing::info!(user_id = me.id, from = ?me.username, to = ?username, admin, "username changed");
    let mut ids: Vec<i64> = crate::profiles::friends_of(&state.db, me.id)
        .await?
        .into_iter()
        .map(|f| f.id)
        .collect();
    ids.push(me.id);
    state.hub.send_many(&ids, &Event::FriendsChanged);
    Ok(Json(json!({ "username": username })))
}

#[derive(Deserialize)]
pub struct SetRecovery {
    auth_key: String,
    recovery_auth_key: String,
    recovery_wrapped_key: String,
}

/// `PUT /api/me/recovery`: a new recovery key (replacing any old one). Needs
/// the password too, so a stolen session can't plant a key and take over.
pub async fn set_recovery(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<SetRecovery>,
) -> AppResult<Json<Value>> {
    require_password(&state, &me, &req.auth_key).await?;
    validate_auth_key(&req.recovery_auth_key)?;
    check_wrapped(&req.recovery_wrapped_key)?;
    let hash = hash_secret(req.recovery_auth_key).await?;
    let at = now();
    let mut tx = crate::db::write_tx(&state.db).await?;
    keep_history(&mut tx, me.id, "recovery_key_set").await?;
    sqlx::query(
        "UPDATE users SET recovery_hash = ?, recovery_wrapped_key = ?, recovery_set_at = ? WHERE id = ?",
    )
    .bind(&hash)
    .bind(&req.recovery_wrapped_key)
    .bind(at)
    .bind(me.id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    tracing::info!(user_id = me.id, "recovery key set");
    Ok(Json(json!({ "recovery_set_at": at })))
}

/// `GET /api/me/security`
pub async fn security(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    let (recovery_set_at, key_reset_at): (Option<i64>, Option<i64>) =
        sqlx::query_as("SELECT recovery_set_at, key_reset_at FROM users WHERE id = ?")
            .bind(me.id)
            .fetch_one(&state.db)
            .await?;
    let sessions: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sessions WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ?",
    )
    .bind(me.id)
    .bind(now())
    .fetch_one(&state.db)
    .await?;
    Ok(Json(json!({
        "recovery_set_at": recovery_set_at,
        "key_reset_at": key_reset_at,
        "active_sessions": sessions,
    })))
}

/// `POST /api/me/sessions/end-others`: sign out everywhere else.
pub async fn end_other_sessions(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    headers: HeaderMap,
) -> AppResult<Json<Value>> {
    let ended = end_sessions(&state, me.id, session_hash(&headers).as_deref()).await?;
    tracing::info!(
        user_id = me.id,
        sessions_ended = ended,
        "signed out other devices"
    );
    Ok(Json(json!({ "sessions_ended": ended })))
}

// ---------- signed out: recovery key ----------

#[derive(Deserialize)]
pub struct RecoverStart {
    username: String,
    recovery_auth_key: String,
}

/// id, username, recovery_hash, recovery_wrapped_key, public_key
type RecoveryRow = (i64, String, Option<String>, Option<String>, String);

/// Looks the account up and checks its recovery key. Shared by both steps;
/// failures count toward the per-username sign-in limit.
async fn check_recovery(
    state: &SharedState,
    who: &ClientInfo,
    username: &str,
    recovery_auth_key: &str,
) -> AppResult<(UserPublic, String, String)> {
    check_ip(state, who, "recover")?;
    let account = username.trim().to_lowercase();
    if state.login_fail_limit.exhausted(&account) {
        tracing::warn!(ip = %who.ip, username = ?account, "recovery rate limited");
        return Err(AppError::TooManyRequests(auth::TOO_MANY.into()));
    }
    let failed = |reason: &str| {
        state.login_fail_limit.allow(&account);
        tracing::info!(ip = %who.ip, username = ?account, reason, "recovery failed");
        AppError::bad("That username and recovery key don't match.")
    };
    validate_auth_key(recovery_auth_key).map_err(|_| failed("malformed key"))?;
    let row: Option<RecoveryRow> = sqlx::query_as(
        "SELECT id, username, recovery_hash, recovery_wrapped_key, public_key FROM users WHERE username = ?",
    )
    .bind(username.trim())
    .fetch_optional(&state.db)
    .await?;
    let Some((id, name, Some(hash), Some(wrapped), public_key)) = row else {
        return Err(failed("no such user or no recovery key"));
    };
    if !verify_secret(hash, recovery_auth_key.to_owned()).await? {
        return Err(failed("wrong recovery key"));
    }
    if crate::admin_users::is_deactivated(&state.db, id).await? {
        tracing::info!(ip = %who.ip, user_id = id, "recovery refused: account turned off");
        return Err(AppError::bad(auth::TURNED_OFF));
    }
    Ok((UserPublic { id, username: name }, wrapped, public_key))
}

/// `POST /api/auth/recover/start`: the recovery copy of the private key,
/// which only the recovery key can unwrap.
pub async fn recover_start(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
    Json(req): Json<RecoverStart>,
) -> AppResult<Json<Value>> {
    let (user, wrapped, _) =
        check_recovery(&state, &who, &req.username, &req.recovery_auth_key).await?;
    tracing::info!(ip = %who.ip, user_id = user.id, "recovery started");
    Ok(Json(json!({ "recovery_wrapped_key": wrapped })))
}

#[derive(Deserialize)]
pub struct RecoverFinish {
    username: String,
    recovery_auth_key: String,
    new_auth_key: String,
    new_wrapped_private_key: String,
}

/// `POST /api/auth/recover/finish`: a new password for the same key. Every
/// old session ends; this one starts.
pub async fn recover_finish(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
    Json(req): Json<RecoverFinish>,
) -> AppResult<Json<SessionResponse>> {
    let (user, _, public_key) =
        check_recovery(&state, &who, &req.username, &req.recovery_auth_key).await?;
    validate_auth_key(&req.new_auth_key)?;
    check_wrapped(&req.new_wrapped_private_key)?;
    let hash = hash_secret(req.new_auth_key).await?;
    let mut tx = crate::db::write_tx(&state.db).await?;
    keep_history(&mut tx, user.id, "recovered").await?;
    sqlx::query("UPDATE users SET auth_hash = ?, wrapped_private_key = ? WHERE id = ?")
        .bind(&hash)
        .bind(&req.new_wrapped_private_key)
        .bind(user.id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    let ended = end_sessions(&state, user.id, None).await?;
    let token = create_session(&state, user.id).await?;
    tracing::info!(ip = %who.ip, user_id = user.id, sessions_ended = ended, "recovered with recovery key");
    Ok(Json(SessionResponse {
        token,
        user: Me::load(&state, user).await?,
        public_key,
        wrapped_private_key: req.new_wrapped_private_key,
    }))
}

// ---------- signed out: admin reset code ----------

fn code_hash(code: &str) -> String {
    let clean: String = code
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect();
    Sha256::digest(clean.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// 16 characters from an alphabet without look-alikes (about 78 bits), shown in groups of four.
fn new_code() -> String {
    const ALPHABET: &[u8] = b"23456789ABCDEFGHJKMNPQRSTVWXYZ";
    let mut raw = [0u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut raw);
    raw.iter()
        .map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char)
        .collect::<Vec<_>>()
        .chunks(4)
        .map(|c| c.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join("-")
}

/// `POST /api/admin/users/{id}/reset-code`: admins only. Any older unused code
/// for that account stops working. The code is shown once and never stored.
pub async fn issue_reset_code(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user): Path<i64>,
) -> AppResult<Json<Value>> {
    // Admins only (roles.md); anyone else gets 404.
    crate::roles::require(&state, &me, crate::roles::Role::Admin).await?;
    let username: Option<String> = sqlx::query_scalar("SELECT username FROM users WHERE id = ?")
        .bind(user)
        .fetch_optional(&state.db)
        .await?;
    let username = username.ok_or_else(|| AppError::not_found("No such user."))?;
    if crate::team::is_system(&state.db, user).await? {
        return Err(AppError::bad(
            "That's napsack's own account: it has no password.",
        ));
    }
    let code = new_code();
    let at = now();
    let mut tx = crate::db::write_tx(&state.db).await?;
    sqlx::query(
        "UPDATE reset_codes SET revoked_at = ? WHERE user_id = ? AND used_at IS NULL AND revoked_at IS NULL",
    )
    .bind(at)
    .bind(user)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO reset_codes (user_id, code_hash, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(user)
    .bind(code_hash(&code))
    .bind(me.id)
    .bind(at)
    .bind(at + RESET_CODE_SECS)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    crate::admin_users::record(&state.db, me.id, "reset_code", Some(user), json!({})).await?;
    tracing::info!(admin_id = me.id, user_id = user, "reset code issued");
    Ok(Json(
        json!({ "username": username, "code": code, "expires_at": at + RESET_CODE_SECS }),
    ))
}

#[derive(Deserialize)]
pub struct ResetWithCode {
    username: String,
    code: String,
    new_auth_key: String,
    public_key: String,
    wrapped_private_key: String,
}

/// `POST /api/auth/reset`: an admin's code, a new password, and a new key
/// pair. The old key (and the recovery key, which wraps it) go to history.
pub async fn reset_with_code(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
    Json(req): Json<ResetWithCode>,
) -> AppResult<Json<SessionResponse>> {
    check_ip(&state, &who, "reset")?;
    let account = req.username.trim().to_lowercase();
    if state.login_fail_limit.exhausted(&account) {
        return Err(AppError::TooManyRequests(auth::TOO_MANY.into()));
    }
    let failed = |reason: &str| {
        state.login_fail_limit.allow(&account);
        tracing::info!(ip = %who.ip, username = ?account, reason, "reset failed");
        AppError::bad("That username and reset code don't match, or the code has expired.")
    };
    validate_auth_key(&req.new_auth_key)?;
    if !is_base64(&req.public_key, 512) {
        return Err(malformed());
    }
    check_wrapped(&req.wrapped_private_key)?;
    let at = now();
    let found: Option<(i64, String, i64)> = sqlx::query_as(
        "SELECT u.id, u.username, c.id FROM users u JOIN reset_codes c ON c.user_id = u.id
         WHERE u.username = ? AND c.code_hash = ? AND c.used_at IS NULL AND c.revoked_at IS NULL
           AND c.expires_at > ?",
    )
    .bind(req.username.trim())
    .bind(code_hash(&req.code))
    .bind(at)
    .fetch_optional(&state.db)
    .await?;
    let Some((id, username, code_id)) = found else {
        return Err(failed("no matching code"));
    };
    if crate::admin_users::is_deactivated(&state.db, id).await? {
        tracing::info!(ip = %who.ip, user_id = id, "reset refused: account turned off");
        return Err(AppError::bad(auth::TURNED_OFF));
    }
    let hash = hash_secret(req.new_auth_key).await?;
    let mut tx = crate::db::write_tx(&state.db).await?;
    let claimed =
        sqlx::query("UPDATE reset_codes SET used_at = ? WHERE id = ? AND used_at IS NULL")
            .bind(at)
            .bind(code_id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
    if claimed == 0 {
        return Err(failed("code already used"));
    }
    keep_history(&mut tx, id, "admin_reset").await?;
    sqlx::query(
        "UPDATE users SET auth_hash = ?, public_key = ?, wrapped_private_key = ?,
            recovery_hash = NULL, recovery_wrapped_key = NULL, recovery_set_at = NULL, key_reset_at = ?
         WHERE id = ?",
    )
    .bind(&hash)
    .bind(&req.public_key)
    .bind(&req.wrapped_private_key)
    .bind(at)
    .bind(id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    let ended = end_sessions(&state, id, None).await?;
    let token = create_session(&state, id).await?;
    tracing::info!(ip = %who.ip, user_id = id, sessions_ended = ended, "account reset with code");
    // Friends need the new public key (and will see a changed safety code).
    let mut ids: Vec<i64> = crate::profiles::friends_of(&state.db, id)
        .await?
        .into_iter()
        .map(|f| f.id)
        .collect();
    ids.push(id);
    state.hub.send_many(&ids, &Event::FriendsChanged);
    Ok(Json(SessionResponse {
        token,
        user: Me::load(&state, UserPublic { id, username }).await?,
        public_key: req.public_key,
        wrapped_private_key: req.wrapped_private_key,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reset_codes_are_long_unambiguous_and_forgiving() {
        let a = new_code();
        assert_eq!(a.len(), 19, "{a}");
        assert!(a.split('-').all(|g| g.len() == 4));
        assert!(!a.contains(['0', '1', 'I', 'L', 'O', 'U']), "{a}");
        assert_ne!(a, new_code());
        // Lowercase, spaces, or missing dashes still match.
        assert_eq!(
            code_hash(&a),
            code_hash(&a.to_lowercase().replace('-', " "))
        );
        assert_ne!(code_hash(&a), code_hash(&new_code()));
    }
}
