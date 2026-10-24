//! Invite links and QR codes (F14). A link (`/i/<token>`) does two things:
//! someone new signs up with it (no invite code needed) and becomes friends
//! with whoever made it; someone with an account adds that person in one tap.
//!
//! A link works for MAX_USES people within INVITE_DAYS, can be revoked, and
//! still counts against the account cap (guard.rs). Only a hash of the token
//! is stored, like session tokens. Lookups are rate-limited like sign-in, so
//! links can't be guessed (and at 128 random bits, they couldn't anyway).

use axum::{
    extract::{Extension, Path, State},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::{check_ip, hash_token, AuthUser},
    db::{now, UserPublic},
    error::{AppError, AppResult},
    ratelimit::ClientInfo,
    ws::Event,
    SharedState,
};

pub const INVITE_DAYS: i64 = 7;
pub const MAX_USES: i64 = 10;
/// Live links per person; making another retires the oldest.
const MAX_LIVE: i64 = 10;

fn new_token() -> String {
    let mut raw = [0u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut raw);
    URL_SAFE_NO_PAD.encode(raw)
}

/// Tokens are 22 base64url characters; anything else can't be one.
fn plausible(token: &str) -> bool {
    token.len() == 22
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// A link that still works: (invite id, who made it).
pub async fn find_valid(db: &SqlitePool, token: &str) -> sqlx::Result<Option<(i64, UserPublic)>> {
    if !plausible(token) {
        return Ok(None);
    }
    let row: Option<(i64, i64, String)> = sqlx::query_as(
        "SELECT i.id, u.id, u.username FROM invites i JOIN users u ON u.id = i.created_by
         WHERE i.token_hash = ? AND i.revoked_at IS NULL AND i.expires_at > ?
           AND (SELECT COUNT(*) FROM invite_uses x WHERE x.invite_id = i.id) < i.max_uses
           -- A turned-off account's links stop working (admin_users.rs).
           AND NOT EXISTS (SELECT 1 FROM deactivations d WHERE d.user_id = u.id AND d.reactivated_at IS NULL)",
    )
    .bind(hash_token(token))
    .bind(now())
    .fetch_optional(db)
    .await?;
    Ok(row.map(|(id, uid, username)| (id, UserPublic { id: uid, username })))
}

/// Records that `user` came in through invite `id`.
pub async fn record_use(db: &SqlitePool, id: i64, user: i64, kind: &str) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO invite_uses (invite_id, user_id, kind, created_at) VALUES (?, ?, ?, ?)",
    )
    .bind(id)
    .bind(user)
    .bind(kind)
    .bind(now())
    .execute(db)
    .await?;
    Ok(())
}

/// Friends now, and both apps (and the inviter's phone) hear about it.
pub async fn befriend_inviter(
    state: &SharedState,
    joiner: &UserPublic,
    inviter: &UserPublic,
) -> AppResult<()> {
    crate::friends::make_friends(&state.db, joiner.id, inviter.id).await?;
    state
        .hub
        .send_both(joiner.id, inviter.id, &Event::FriendsChanged);
    crate::push::notify(
        state,
        inviter.id,
        crate::push::Note {
            title: "napsack".into(),
            body: format!("{} joined you through your invite", joiner.username),
            tag: format!("dm-{}", joiner.id),
            url: format!("/#chat={}", joiner.id),
        },
    );
    Ok(())
}

/// `POST /api/invites`: a new link. The token is shown once; only its hash is kept.
pub async fn create(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    if !state.invite_create_limit.allow(&me.id.to_string()) {
        return Err(AppError::TooManyRequests(
            "That's a lot of invite links for one day. Try again tomorrow.".into(),
        ));
    }
    let token = new_token();
    let at = now();
    let mut tx = state.db.begin().await?;
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO invites (created_by, token_hash, created_at, expires_at, max_uses) VALUES (?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(me.id)
    .bind(hash_token(&token))
    .bind(at)
    .bind(at + INVITE_DAYS * 86_400)
    .bind(MAX_USES)
    .fetch_one(&mut *tx)
    .await?;
    // Keep the newest few live.
    sqlx::query(
        "UPDATE invites SET revoked_at = ? WHERE created_by = ? AND revoked_at IS NULL AND expires_at > ?
           AND id NOT IN (SELECT id FROM invites WHERE created_by = ? AND revoked_at IS NULL
                          ORDER BY id DESC LIMIT ?)",
    )
    .bind(at)
    .bind(me.id)
    .bind(at)
    .bind(me.id)
    .bind(MAX_LIVE)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    tracing::info!(user_id = me.id, invite_id = id, "invite link made");
    Ok(Json(json!({
        "id": id,
        "path": format!("/i/{token}"),
        "expires_at": at + INVITE_DAYS * 86_400,
        "max_uses": MAX_USES,
    })))
}

#[derive(Serialize, FromRow)]
struct InviteRow {
    id: i64,
    created_at: i64,
    expires_at: i64,
    max_uses: i64,
    revoked_at: Option<i64>,
}

/// `GET /api/invites`: my links, newest first, with who joined through each.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    let invites: Vec<InviteRow> = sqlx::query_as(
        "SELECT id, created_at, expires_at, max_uses, revoked_at FROM invites
         WHERE created_by = ? ORDER BY id DESC LIMIT 50",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    let mut out = Vec::with_capacity(invites.len());
    for i in invites {
        let joined: Vec<(i64, String, String)> = sqlx::query_as(
            "SELECT u.id, u.username, x.kind FROM invite_uses x JOIN users u ON u.id = x.user_id
             WHERE x.invite_id = ? ORDER BY x.id",
        )
        .bind(i.id)
        .fetch_all(&state.db)
        .await?;
        out.push(json!({
            "id": i.id,
            "created_at": i.created_at,
            "expires_at": i.expires_at,
            "max_uses": i.max_uses,
            "revoked_at": i.revoked_at,
            "live": i.revoked_at.is_none() && i.expires_at > now() && (joined.len() as i64) < i.max_uses,
            "joined": joined.iter().map(|(id, username, kind)| json!({ "id": id, "username": username, "kind": kind })).collect::<Vec<_>>(),
        }));
    }
    Ok(Json(json!(out)))
}

/// `POST /api/invites/{id}/revoke`
pub async fn revoke(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<Value>> {
    let ended = sqlx::query(
        "UPDATE invites SET revoked_at = ? WHERE id = ? AND created_by = ? AND revoked_at IS NULL",
    )
    .bind(now())
    .bind(id)
    .bind(me.id)
    .execute(&state.db)
    .await?
    .rows_affected();
    if ended == 0 {
        return Err(AppError::not_found(
            "That invite link doesn't exist or was already turned off.",
        ));
    }
    tracing::info!(user_id = me.id, invite_id = id, "invite link revoked");
    Ok(Json(json!({ "ok": true })))
}

fn gone() -> AppError {
    AppError::not_found("This invite link has expired, been used up, or been turned off.")
}

/// `GET /api/invites/lookup/{token}`: signed out or in. Who made the link,
/// if it still works. Limited per address like sign-in.
pub async fn lookup(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
    Path(token): Path<String>,
) -> AppResult<Json<Value>> {
    check_ip(&state, &who, "invite lookup")?;
    let (_, inviter) = find_valid(&state.db, &token).await?.ok_or_else(gone)?;
    Ok(Json(
        json!({ "inviter": { "id": inviter.id, "username": inviter.username } }),
    ))
}

#[derive(Deserialize)]
pub struct Accept {
    token: String,
}

/// `POST /api/invites/accept`: signed in; become friends with whoever made the link.
pub async fn accept(
    State(state): State<SharedState>,
    Extension(who): Extension<ClientInfo>,
    AuthUser(me): AuthUser,
    Json(req): Json<Accept>,
) -> AppResult<Json<Value>> {
    check_ip(&state, &who, "invite accept")?;
    let (id, inviter) = find_valid(&state.db, &req.token).await?.ok_or_else(gone)?;
    if inviter.id == me.id {
        return Err(AppError::bad(
            "That's your own invite link. Send it to a friend.",
        ));
    }
    let already = crate::db::are_friends(&state.db, me.id, inviter.id).await?;
    if !already {
        record_use(&state.db, id, me.id, "added").await?;
        befriend_inviter(&state, &me, &inviter).await?;
        tracing::info!(
            user_id = me.id,
            inviter_id = inviter.id,
            invite_id = id,
            "friends through an invite"
        );
    }
    Ok(Json(
        json!({ "friend": { "id": inviter.id, "username": inviter.username }, "already": already }),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[tokio::test]
    async fn links_work_until_used_up_expired_or_revoked() {
        let db = temp_db().await;
        sqlx::query(
            "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at)
             VALUES (1, 'ana', 'h', 'k', 'w', 0), (2, 'ben', 'h', 'k', 'w', 0)",
        )
        .execute(&db)
        .await
        .unwrap();
        let add = |token: &'static str, expires: i64, max: i64| {
            let db = db.clone();
            async move {
                sqlx::query("INSERT INTO invites (created_by, token_hash, created_at, expires_at, max_uses) VALUES (1, ?, 0, ?, ?) RETURNING id")
                    .bind(hash_token(token))
                    .bind(expires)
                    .bind(max)
                    .execute(&db)
                    .await
                    .unwrap();
            }
        };
        let fresh = "AAAAAAAAAAAAAAAAAAAAAA";
        let stale = "BBBBBBBBBBBBBBBBBBBBBB";
        add(fresh, now() + 3600, 1).await;
        add(stale, now() - 1, 5).await;
        let (id, inviter) = find_valid(&db, fresh).await.unwrap().expect("works");
        assert_eq!(inviter.username, "ana");
        assert!(find_valid(&db, stale).await.unwrap().is_none(), "expired");
        assert!(
            find_valid(&db, "nope").await.unwrap().is_none(),
            "malformed"
        );
        record_use(&db, id, 2, "signed_up").await.unwrap();
        assert!(find_valid(&db, fresh).await.unwrap().is_none(), "used up");
        assert!(plausible(&new_token()));
    }
}
