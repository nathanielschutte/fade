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
        user_for_token(&state.db, token)
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

fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

pub async fn user_for_token(db: &SqlitePool, token: &str) -> sqlx::Result<Option<UserPublic>> {
    let at = now();
    let user = sqlx::query_as::<_, UserPublic>(
        "SELECT u.id, u.username FROM sessions s JOIN users u ON u.id = s.user_id
         WHERE s.token_hash = ? AND s.expires_at > ? AND s.revoked_at IS NULL",
    )
    .bind(hash_token(token))
    .bind(at)
    .fetch_optional(db)
    .await?;
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

async fn create_session(state: &SharedState, user_id: i64) -> AppResult<String> {
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
    token: String,
    user: Me,
    public_key: String,
    wrapped_private_key: String,
}

/// The signed-in user as they see themselves.
#[derive(Serialize)]
pub struct Me {
    id: i64,
    username: String,
    /// Shows the admin link. The admin API checks again on every request.
    is_admin: bool,
}

impl Me {
    fn new(state: &SharedState, user: UserPublic) -> Self {
        let is_admin = state.config.is_admin(&user.username);
        Self {
            id: user.id,
            username: user.username,
            is_admin,
        }
    }
}

/// Auth keys are 32 bytes, base64 (44 chars). Allow some slack for future formats.
fn validate_auth_key(key: &str) -> AppResult<()> {
    if is_base64(key, 128) {
        Ok(())
    } else {
        Err(AppError::bad(
            "Sign-in data was malformed. Reload the page and try again.",
        ))
    }
}

fn validate_username(name: &str) -> AppResult<()> {
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

/// Compare digests rather than raw strings so the check takes the same time either way.
fn same_secret(a: &str, b: &str) -> bool {
    Sha256::digest(a.as_bytes()) == Sha256::digest(b.as_bytes())
}

const TOO_MANY: &str = "Too many attempts. Wait a few minutes and try again.";

/// Sign-in and sign-up attempts per address. Local, un-proxied requests
/// (development and tests) aren't limited by address.
fn check_ip(state: &SharedState, who: &ClientInfo, action: &str) -> AppResult<()> {
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
    if let Some(expected) = &state.config.invite_code {
        let given = req.invite_code.as_deref().unwrap_or("").trim();
        if !same_secret(given, expected) {
            tracing::info!(ip = %who.ip, username = ?req.username.trim(), "sign-up rejected: wrong invite code");
            return Err(AppError::bad("That invite code isn't valid."));
        }
    }

    let username = req.username.trim().to_string();
    validate_username(&username)?;
    validate_auth_key(&req.auth_key)?;
    // P-256 SPKI is 91 bytes; a wrapped PKCS#8 key is ~180. Generous caps.
    if !is_base64(&req.public_key, 512) || !is_base64(&req.wrapped_private_key, 2048) {
        return Err(AppError::bad(
            "Key data was malformed. Reload the page and try again.",
        ));
    }

    // Argon2 is deliberately slow; keep it off the async workers. The auth key
    // is already high-entropy, but hashing it means a DB leak can't be replayed.
    let auth_key = req.auth_key;
    let hash = tokio::task::spawn_blocking(move || {
        let salt = SaltString::generate(&mut OsRng);
        Argon2::default()
            .hash_password(auth_key.as_bytes(), &salt)
            .map(|h| h.to_string())
    })
    .await?
    .map_err(|e| AppError::Internal(format!("hash: {e}")))?;

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
    tracing::info!(ip = %who.ip, user_id = user.id, username = %user.username, "account created");
    Ok(Json(SessionResponse {
        token,
        user: Me::new(&state, user),
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
    // Failed sign-ins per username, whatever address they come from. Checked
    // before the (slow) password check, so guessing can't burn the CPU either.
    let account = req.username.trim().to_lowercase();
    if state.login_fail_limit.exhausted(&account) {
        tracing::warn!(ip = %who.ip, username = ?account, "sign-in rate limited");
        return Err(AppError::TooManyRequests(TOO_MANY.into()));
    }
    let failed = |reason: &str| {
        state.login_fail_limit.allow(&account);
        tracing::info!(ip = %who.ip, username = ?account, reason, "sign-in failed");
        AppError::bad("Wrong username or password.")
    };
    validate_auth_key(&req.auth_key).map_err(|_| failed("malformed key"))?;

    let row: Option<(i64, String, String, String, String)> = sqlx::query_as(
        "SELECT id, username, auth_hash, public_key, wrapped_private_key
         FROM users WHERE username = ?",
    )
    .bind(req.username.trim())
    .fetch_optional(&state.db)
    .await?;
    let Some((id, username, stored, public_key, wrapped_private_key)) = row else {
        return Err(failed("no such user"));
    };

    let auth_key = req.auth_key;
    let valid = tokio::task::spawn_blocking(move || {
        PasswordHash::new(&stored)
            .map(|parsed| {
                Argon2::default()
                    .verify_password(auth_key.as_bytes(), &parsed)
                    .is_ok()
            })
            .unwrap_or(false)
    })
    .await?;

    if !valid {
        return Err(failed("wrong password"));
    }

    // The wrapped key is only useful with the password, which the server never sees.
    let token = create_session(&state, id).await?;
    tracing::info!(ip = %who.ip, user_id = id, %username, "signed in");
    Ok(Json(SessionResponse {
        token,
        user: Me::new(&state, UserPublic { id, username }),
        public_key,
        wrapped_private_key,
    }))
}

pub async fn logout(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> AppResult<Json<serde_json::Value>> {
    if let Some(token) = bearer_token(&headers) {
        // Revoked, not removed: the session row stays as a record.
        let ended = sqlx::query(
            "UPDATE sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL",
        )
        .bind(now())
        .bind(hash_token(token))
        .execute(&state.db)
        .await?
        .rows_affected();
        tracing::debug!(ended, "signed out");
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn me(State(state): State<SharedState>, AuthUser(user): AuthUser) -> Json<Me> {
    Json(Me::new(&state, user))
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn secrets_compare_by_value() {
        assert!(same_secret("letmein", "letmein"));
        assert!(!same_secret("letmein", "letmeout"));
        assert!(!same_secret("", "letmein"));
    }
}
