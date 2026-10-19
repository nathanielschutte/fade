use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    extract::{FromRequestParts, State},
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

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
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
         WHERE s.token_hash = ? AND s.expires_at > ?",
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

pub async fn register(
    State(state): State<SharedState>,
    Json(req): Json<Register>,
) -> AppResult<Json<SessionResponse>> {
    if let Some(expected) = &state.config.invite_code {
        let given = req.invite_code.as_deref().unwrap_or("").trim();
        if !same_secret(given, expected) {
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
            return Err(AppError::Conflict("That username is taken.".into()))
        }
        Err(e) => return Err(e.into()),
    };

    let token = create_session(&state, user.id).await?;
    Ok(Json(SessionResponse {
        token,
        user: Me::new(&state, user),
        public_key: req.public_key,
        wrapped_private_key: req.wrapped_private_key,
    }))
}

pub async fn login(
    State(state): State<SharedState>,
    Json(req): Json<Login>,
) -> AppResult<Json<SessionResponse>> {
    let bad_login = || AppError::bad("Wrong username or password.");
    validate_auth_key(&req.auth_key).map_err(|_| bad_login())?;

    let row: Option<(i64, String, String, String, String)> = sqlx::query_as(
        "SELECT id, username, auth_hash, public_key, wrapped_private_key
         FROM users WHERE username = ?",
    )
    .bind(req.username.trim())
    .fetch_optional(&state.db)
    .await?;
    let (id, username, stored, public_key, wrapped_private_key) = row.ok_or_else(bad_login)?;

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
        return Err(bad_login());
    }

    // The wrapped key is only useful with the password, which the server never sees.
    let token = create_session(&state, id).await?;
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
        sqlx::query("DELETE FROM sessions WHERE token_hash = ?")
            .bind(hash_token(token))
            .execute(&state.db)
            .await?;
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn me(State(state): State<SharedState>, AuthUser(user): AuthUser) -> Json<Me> {
    Json(Me::new(&state, user))
}
