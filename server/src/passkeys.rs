//! Passkeys (F26, docs/design/passkeys.md): signing in with Face ID, a
//! fingerprint, or a security key instead of the password.
//!
//! A passkey alone only proves who you are; napsack also needs your private
//! key on the device. So each passkey brings a third wrapped copy of it,
//! beside the password's and the recovery key's: wrapped by a secret only
//! that passkey can produce (WebAuthn's PRF extension), which the server
//! never sees. Signing in with one hands back that copy, and the device
//! opens it. The password keeps working, and changing it leaves passkeys
//! working (the key is the same); an admin's reset code (a new key) ends them.
//!
//! Adding one needs the password, as a recovery key does, so a stolen
//! session can't plant a way in. The checks are in webauthn.rs.

use axum::{
    extract::{Extension, Path, State},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{
    auth::{check_ip, create_session, AuthUser, Me, SessionResponse},
    db::{is_base64, now, UserPublic},
    error::{AppError, AppResult},
    ratelimit::ClientInfo,
    webauthn::{self, Purpose},
    SharedState,
};

/// Passkeys per account at once (security.md).
pub const MAX_PASSKEYS: i64 = 10;

fn busy() -> AppError {
    AppError::Unavailable("napsack is busy. Try again in a minute.".into())
}

fn malformed() -> AppError {
    AppError::bad("The passkey's answer was malformed. Try again.")
}

/// Base64url from a client, bounded before it's decoded.
fn decode(s: &str, max_bytes: usize) -> AppResult<Vec<u8>> {
    if s.len() > max_bytes * 4 / 3 + 4 {
        return Err(malformed());
    }
    webauthn::b64url(s)
        .filter(|b| !b.is_empty())
        .ok_or_else(malformed)
}

/// `POST /api/me/passkeys/options`: what the browser or app needs to make a
/// passkey for this account.
pub async fn register_options(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    let existing: Vec<String> = sqlx::query_scalar(
        "SELECT credential_id FROM passkeys WHERE user_id = ? AND ended_at IS NULL ORDER BY id",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    if existing.len() as i64 >= MAX_PASSKEYS {
        return Err(too_many());
    }
    let challenge = state
        .challenges
        .issue(Purpose::Register, Some(me.id))
        .ok_or_else(busy)?;
    Ok(Json(json!({
        "challenge": URL_SAFE_NO_PAD.encode(challenge),
        "rp_id": state.rp.id,
        "rp_name": "napsack",
        // The account's id: a passkey manager keeps one passkey per account and site.
        "user_id": URL_SAFE_NO_PAD.encode(me.id.to_be_bytes()),
        "user_name": me.username,
        // Not the same one twice.
        "exclude": existing,
    })))
}

fn too_many() -> AppError {
    AppError::bad(format!(
        "You have {MAX_PASSKEYS} passkeys, the most there can be. Remove one first."
    ))
}

#[derive(Deserialize)]
pub struct AddPasskey {
    auth_key: String,
    client_data_json: String,
    attestation_object: String,
    /// The private key wrapped by the passkey's PRF secret (crypto.js), base64.
    wrapped_key: String,
}

/// `POST /api/me/passkeys`: the new passkey, checked, and its wrapped copy of the key.
pub async fn add(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<AddPasskey>,
) -> AppResult<Json<Value>> {
    let client_data = decode(&req.client_data_json, 4096)?;
    let attestation = decode(&req.attestation_object, 16_384)?;
    if !is_base64(&req.wrapped_key, 2048) {
        return Err(malformed());
    }
    // Used up whatever happens next: each answer counts once.
    let challenge = webauthn::challenge_of(&client_data).ok_or_else(malformed)?;
    if !state
        .challenges
        .take(&challenge, Purpose::Register, Some(me.id))
    {
        return Err(AppError::bad(
            "That took too long. Try adding the passkey again.",
        ));
    }
    crate::account::require_password(&state, &me, &req.auth_key).await?;
    let made = webauthn::verify_registration(&state.rp, &challenge, &client_data, &attestation)
        .map_err(|reason| {
            tracing::info!(user_id = me.id, reason, "passkey refused");
            AppError::bad("That passkey couldn't be added. Try again.")
        })?;
    let provider = webauthn::provider(&made.aaguid);
    let at = now();
    let mut tx = crate::db::write_tx(&state.db).await?;
    let count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM passkeys WHERE user_id = ? AND ended_at IS NULL")
            .bind(me.id)
            .fetch_one(&mut *tx)
            .await?;
    if count >= MAX_PASSKEYS {
        return Err(too_many());
    }
    let inserted = sqlx::query_scalar::<_, i64>(
        "INSERT INTO passkeys (user_id, credential_id, public_key, sign_count, wrapped_key, provider, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(me.id)
    .bind(URL_SAFE_NO_PAD.encode(&made.credential_id))
    .bind(&made.public_key)
    .bind(made.sign_count as i64)
    .bind(&req.wrapped_key)
    .bind(provider)
    .bind(at)
    .fetch_one(&mut *tx)
    .await;
    let id = match inserted {
        Ok(id) => id,
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            return Err(AppError::Conflict("That passkey is already added.".into()));
        }
        Err(e) => return Err(e.into()),
    };
    tx.commit().await?;
    tracing::info!(user_id = me.id, passkey_id = id, provider, "passkey added");
    Ok(Json(
        json!({ "id": id, "provider": provider, "created_at": at }),
    ))
}

#[derive(Serialize, sqlx::FromRow)]
struct Listed {
    id: i64,
    /// Not a secret: it names the passkey to the browser, so it can be
    /// taken out of the password manager too once it's removed.
    credential_id: String,
    provider: Option<String>,
    created_at: i64,
    last_used_at: Option<i64>,
}

/// `GET /api/me/passkeys`: yours, oldest first (at most `MAX_PASSKEYS`).
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    let passkeys: Vec<Listed> = sqlx::query_as(
        "SELECT id, credential_id, provider, created_at, last_used_at FROM passkeys
         WHERE user_id = ? AND ended_at IS NULL ORDER BY id",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(json!({ "passkeys": passkeys, "rp_id": state.rp.id })))
}

/// `POST /api/me/passkeys/{id}/remove`: it stops working (the row stays, ended).
pub async fn remove(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<Value>> {
    let ended = sqlx::query(
        "UPDATE passkeys SET ended_at = ?, end_reason = 'removed'
         WHERE id = ? AND user_id = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(id)
    .bind(me.id)
    .execute(&state.db)
    .await?
    .rows_affected();
    if ended == 0 {
        return Err(AppError::NotFound(
            "That passkey isn't there any more.".into(),
        ));
    }
    tracing::info!(user_id = me.id, passkey_id = id, "passkey removed");
    Ok(Json(json!({ "removed": true })))
}

/// Ends every passkey of an account whose key was replaced (an admin's reset
/// code): their copies are of the old key.
pub(crate) async fn end_for_key_reset(
    tx: &mut sqlx::SqliteConnection,
    user: i64,
) -> sqlx::Result<u64> {
    Ok(sqlx::query(
        "UPDATE passkeys SET ended_at = ?, end_reason = 'key_reset' WHERE user_id = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(user)
    .execute(tx)
    .await?
    .rows_affected())
}

/// `POST /api/auth/passkey/options`: a challenge for signing in. Any of the
/// site's passkeys may answer it; the browser or app asks which.
pub async fn sign_in_options(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
) -> AppResult<Json<Value>> {
    check_ip(&state, &who, "passkey options")?;
    let challenge = state
        .challenges
        .issue(Purpose::SignIn, None)
        .ok_or_else(busy)?;
    Ok(Json(json!({
        "challenge": URL_SAFE_NO_PAD.encode(challenge),
        "rp_id": state.rp.id,
    })))
}

#[derive(Deserialize)]
pub struct PasskeySignIn {
    credential_id: String,
    client_data_json: String,
    authenticator_data: String,
    signature: String,
}

/// A passkey and its account, for signing in.
#[derive(sqlx::FromRow)]
struct Found {
    passkey: i64,
    id: i64,
    username: String,
    key: Vec<u8>,
    count: i64,
    passkey_wrapped_key: String,
    public_key: String,
    wrapped_private_key: String,
}

/// A sign-in's answer, plus the passkey's wrapped copy of the private key.
#[derive(Serialize)]
pub struct PasskeySession {
    #[serde(flatten)]
    session: SessionResponse,
    passkey_wrapped_key: String,
}

/// `POST /api/auth/passkey`: signs in with a passkey.
pub async fn sign_in(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
    Json(req): Json<PasskeySignIn>,
) -> AppResult<Json<PasskeySession>> {
    check_ip(&state, &who, "passkey sign-in")?;
    let failed = |reason: &str| {
        tracing::info!(ip = %who.ip, reason, "passkey sign-in failed");
        AppError::bad("That passkey didn't work. Try again, or sign in with your password.")
    };
    let credential = decode(&req.credential_id, 1023)?;
    let client_data = decode(&req.client_data_json, 4096)?;
    let auth_data = decode(&req.authenticator_data, 1024)?;
    let signature = decode(&req.signature, 128)?;
    let challenge = webauthn::challenge_of(&client_data).ok_or_else(malformed)?;
    if !state.challenges.take(&challenge, Purpose::SignIn, None) {
        return Err(AppError::bad("That took too long. Try signing in again."));
    }
    let found: Option<Found> = sqlx::query_as(
        "SELECT p.id AS passkey, u.id, u.username, p.public_key AS key, p.sign_count AS count,
                p.wrapped_key AS passkey_wrapped_key, u.public_key, u.wrapped_private_key
         FROM passkeys p JOIN users u ON u.id = p.user_id
         WHERE p.credential_id = ? AND p.ended_at IS NULL",
    )
    .bind(URL_SAFE_NO_PAD.encode(&credential))
    .fetch_optional(&state.db)
    .await?;
    let Some(Found {
        passkey,
        id,
        username,
        key,
        count,
        passkey_wrapped_key,
        public_key,
        wrapped_private_key,
    }) = found
    else {
        tracing::info!(ip = %who.ip, "passkey sign-in with an unknown or removed passkey");
        return Err(AppError::bad(
            "That passkey isn't set up for napsack any more. Sign in with your password.",
        ));
    };
    if crate::team::is_system(&state.db, id).await? {
        return Err(failed("system account"));
    }
    let new_count = webauthn::verify_assertion(
        &state.rp,
        &challenge,
        &client_data,
        &auth_data,
        &signature,
        &key,
        count as u32,
    )
    .map_err(failed)?;
    // Said only after the passkey checked out, as with the password.
    if let Some(why) = crate::admin_users::refusal(&state.db, id).await? {
        tracing::info!(ip = %who.ip, user_id = id, "passkey sign-in refused: account turned off");
        return Err(AppError::bad(why));
    }
    sqlx::query(
        "UPDATE passkeys SET sign_count = MAX(sign_count, ?), last_used_at = ? WHERE id = ?",
    )
    .bind(new_count as i64)
    .bind(now())
    .bind(passkey)
    .execute(&state.db)
    .await?;
    let token = create_session(&state, id).await?;
    tracing::info!(ip = %who.ip, user_id = id, passkey_id = passkey, %username, "signed in with a passkey");
    Ok(Json(PasskeySession {
        session: SessionResponse {
            token,
            user: Me::load(&state, UserPublic { id, username }).await?,
            public_key,
            wrapped_private_key,
        },
        passkey_wrapped_key,
    }))
}
