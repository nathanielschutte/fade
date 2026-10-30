//! Each person's "add a friend" link and QR code (`/i/<token>`; X25, X39).
//! It does both jobs: someone with an account who opens it becomes their
//! friend in one tap, and someone new signs up with it (no invite code
//! needed) and starts out as their friend. There's one per person, with no
//! limit on uses, and it never changes.
//!
//! Its token is derived (HMAC of a server key, the person, and which link
//! of theirs it is), so it can be shown again while only its hash is stored,
//! like session tokens. Lookups are rate-limited like sign-in, so links
//! can't be guessed (and at 128 random bits, they couldn't anyway).
//!
//! One-time invite links (10 people, 7 days) and resetting your link are
//! gone (X39). Their rows stay (Rule 1); they just aren't honored, and a
//! link reset before then stays off.

use axum::{
    extract::{Extension, Path, State},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::{check_ip, hash_token, AuthUser},
    db::{now, UserPublic},
    error::{AppError, AppResult},
    ratelimit::ClientInfo,
    ws::Event,
    SharedState,
};

/// A personal link has no practical end.
const PERSONAL_USES: i64 = 1_000_000_000;
const PERSONAL_DAYS: i64 = 365 * 100;

/// Tokens are 22 base64url characters; anything else can't be one.
fn plausible(token: &str) -> bool {
    token.len() == 22
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// A link that still works: (invite id, who made it). Only personal links:
/// one-time invite links aren't honored any more (X39).
pub async fn find_valid(db: &SqlitePool, token: &str) -> sqlx::Result<Option<(i64, UserPublic)>> {
    if !plausible(token) {
        return Ok(None);
    }
    let row: Option<(i64, i64, String)> = sqlx::query_as(
        "SELECT i.id, u.id, u.username FROM invites i JOIN users u ON u.id = i.created_by
         WHERE i.token_hash = ? AND i.personal = 1 AND i.revoked_at IS NULL AND i.expires_at > ?
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

fn gone() -> AppError {
    AppError::not_found("This link doesn't work. Ask your friend for their code again.")
}

// ---------- personal links (X25) ----------

/// The token for someone's `n`th personal link (0, 1, ...): the same every
/// time it's worked out, unguessable without the server's key.
fn personal_token(key: &[u8], user: i64, n: i64) -> String {
    use hmac::{Hmac, Mac};
    let mut mac = Hmac::<sha2::Sha256>::new_from_slice(key).expect("HMAC takes any key length");
    mac.update(format!("napsack/friend-link/{user}/{n}").as_bytes());
    URL_SAFE_NO_PAD.encode(&mac.finalize().into_bytes()[..16])
}

async fn link_key(db: &SqlitePool) -> sqlx::Result<Vec<u8>> {
    use base64::engine::general_purpose::STANDARD;
    let fresh: [u8; 32] = rand::random();
    sqlx::query(
        "INSERT OR IGNORE INTO server_keys (name, value, created_at) VALUES ('friend_link', ?, ?)",
    )
    .bind(STANDARD.encode(fresh))
    .bind(now())
    .execute(db)
    .await?;
    let value: String =
        sqlx::query_scalar("SELECT value FROM server_keys WHERE name = 'friend_link'")
            .fetch_one(db)
            .await?;
    Ok(STANDARD.decode(value).unwrap_or_default())
}

/// Someone's personal link: the current one, or a new one if they have none
/// (a link reset before X39 stays off, and the next one is made).
/// Returns (path, created_at, how many have used it).
async fn personal_link(db: &SqlitePool, user: i64) -> sqlx::Result<(String, i64, i64)> {
    let key = link_key(db).await?;
    let current: Option<(i64, i64)> = sqlx::query_as(
        "SELECT id, created_at FROM invites WHERE created_by = ? AND personal = 1 AND revoked_at IS NULL
         ORDER BY id DESC LIMIT 1",
    )
    .bind(user)
    .fetch_optional(db)
    .await?;
    let (id, created_at, n) = match current {
        Some((id, created_at)) => {
            let n: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM invites WHERE created_by = ? AND personal = 1 AND id < ?",
            )
            .bind(user)
            .bind(id)
            .fetch_one(db)
            .await?;
            (id, created_at, n)
        }
        None => {
            let n: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM invites WHERE created_by = ? AND personal = 1",
            )
            .bind(user)
            .fetch_one(db)
            .await?;
            let at = now();
            let id: i64 = sqlx::query_scalar(
                "INSERT INTO invites (created_by, token_hash, created_at, expires_at, max_uses, personal)
                 VALUES (?, ?, ?, ?, ?, 1) RETURNING id",
            )
            .bind(user)
            .bind(hash_token(&personal_token(&key, user, n)))
            .bind(at)
            .bind(at + PERSONAL_DAYS * 86_400)
            .bind(PERSONAL_USES)
            .fetch_one(db)
            .await?;
            (id, at, n)
        }
    };
    let uses: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM invite_uses WHERE invite_id = ?")
        .bind(id)
        .fetch_one(db)
        .await?;
    Ok((
        format!("/i/{}", personal_token(&key, user, n)),
        created_at,
        uses,
    ))
}

/// `GET /api/friend-link`: my personal "add me" link (made the first time).
pub async fn friend_link(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    let (path, created_at, uses) = personal_link(&state.db, me.id).await?;
    Ok(Json(
        json!({ "path": path, "created_at": created_at, "uses": uses }),
    ))
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
    async fn a_personal_link_is_the_same_every_time() {
        let db = temp_db().await;
        sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (1, 'ana', 'h', 'k', 'w', 0)")
            .execute(&db).await.unwrap();
        let (first, _, _) = personal_link(&db, 1).await.unwrap();
        assert_eq!(
            personal_link(&db, 1).await.unwrap().0,
            first,
            "the same link each time"
        );
        let token = first.trim_start_matches("/i/").to_owned();
        assert!(plausible(&token));
        assert_eq!(find_valid(&db, &token).await.unwrap().unwrap().1.id, 1);
        // One reset before X39: that link stays off, and a different one works.
        sqlx::query("UPDATE invites SET revoked_at = 1 WHERE created_by = 1 AND personal = 1")
            .execute(&db)
            .await
            .unwrap();
        let (second, _, _) = personal_link(&db, 1).await.unwrap();
        assert_ne!(second, first);
        assert!(find_valid(&db, &token).await.unwrap().is_none());
        assert!(find_valid(&db, second.trim_start_matches("/i/"))
            .await
            .unwrap()
            .is_some());
        assert!(
            find_valid(&db, "nope").await.unwrap().is_none(),
            "malformed"
        );
    }

    /// One-time invite links from before X39 aren't honored, even unexpired
    /// and unused; their rows stay (Rule 1).
    #[tokio::test]
    async fn one_time_links_no_longer_work() {
        let db = temp_db().await;
        sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (1, 'ana', 'h', 'k', 'w', 0)")
            .execute(&db).await.unwrap();
        let token = "AAAAAAAAAAAAAAAAAAAAAA";
        sqlx::query("INSERT INTO invites (created_by, token_hash, created_at, expires_at, max_uses) VALUES (1, ?, 0, ?, 10)")
            .bind(hash_token(token))
            .bind(now() + 3600)
            .execute(&db)
            .await
            .unwrap();
        assert!(find_valid(&db, token).await.unwrap().is_none());
        let kept: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM invites")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(kept, 1);
    }
}
