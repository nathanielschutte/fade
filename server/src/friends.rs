use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    db::{self, now, pair, Message, UserPublic},
    error::{AppError, AppResult},
    ws::Event,
    SharedState,
};

#[derive(FromRow)]
struct ChatRow {
    id: i64,
    username: String,
    public_key: String,
    last_id: Option<i64>,
    unread: i64,
}

#[derive(Serialize)]
pub struct ChatSummary {
    id: i64,
    username: String,
    /// The friend's SPKI public key. Clients pin it on first sight.
    public_key: String,
    last_message: Option<Message>,
    /// Unread texts plus unopened snaps from this friend.
    unread: i64,
}

/// The home screen: every friend, with their latest message, newest chats first.
pub async fn list_chats(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Vec<ChatSummary>>> {
    let rows = sqlx::query_as::<_, ChatRow>(
        "SELECT u.id, u.username, u.public_key,
            (SELECT m.id FROM messages m
              WHERE (m.sender_id = ? AND m.recipient_id = u.id)
                 OR (m.sender_id = u.id AND m.recipient_id = ?)
              ORDER BY m.id DESC LIMIT 1) AS last_id,
            (SELECT COUNT(*) FROM messages m
              WHERE m.sender_id = u.id AND m.recipient_id = ?
                AND ((m.kind = 'text' AND m.read_at IS NULL)
                  OR (m.kind = 'snap' AND m.snap_state = 'pending'))) AS unread
         FROM friendships f
         JOIN users u ON u.id = CASE WHEN f.user_lo = ? THEN f.user_hi ELSE f.user_lo END
         WHERE f.user_lo = ? OR f.user_hi = ?",
    )
    .bind(me.id)
    .bind(me.id)
    .bind(me.id)
    .bind(me.id)
    .bind(me.id)
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;

    let mut chats = Vec::with_capacity(rows.len());
    for row in rows {
        let last_message = match row.last_id {
            Some(id) => db::get_message(&state.db, id).await?,
            None => None,
        };
        chats.push(ChatSummary {
            id: row.id,
            username: row.username,
            public_key: row.public_key,
            last_message,
            unread: row.unread,
        });
    }
    chats.sort_by(|a, b| {
        let ka = a.last_message.as_ref().map(|m| m.id).unwrap_or(0);
        let kb = b.last_message.as_ref().map(|m| m.id).unwrap_or(0);
        kb.cmp(&ka)
            .then_with(|| a.username.to_lowercase().cmp(&b.username.to_lowercase()))
    });
    Ok(Json(chats))
}

#[derive(Serialize, FromRow)]
pub struct RequestEntry {
    id: i64,
    username: String,
    created_at: i64,
}

#[derive(Serialize)]
pub struct Requests {
    incoming: Vec<RequestEntry>,
    outgoing: Vec<RequestEntry>,
}

pub async fn list_requests(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Requests>> {
    let incoming = sqlx::query_as::<_, RequestEntry>(
        "SELECT u.id, u.username, r.created_at FROM friend_requests r
         JOIN users u ON u.id = r.from_id WHERE r.to_id = ? ORDER BY r.created_at DESC",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    let outgoing = sqlx::query_as::<_, RequestEntry>(
        "SELECT u.id, u.username, r.created_at FROM friend_requests r
         JOIN users u ON u.id = r.to_id WHERE r.from_id = ? ORDER BY r.created_at DESC",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(Requests { incoming, outgoing }))
}

#[derive(Deserialize)]
pub struct AddFriend {
    username: String,
}

/// Removes any requests between the two users and records the friendship.
async fn make_friends(db: &SqlitePool, a: i64, b: i64) -> sqlx::Result<()> {
    let (lo, hi) = pair(a, b);
    let mut tx = db.begin().await?;
    sqlx::query(
        "DELETE FROM friend_requests WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)",
    )
    .bind(a)
    .bind(b)
    .bind(b)
    .bind(a)
    .execute(&mut *tx)
    .await?;
    sqlx::query("INSERT OR IGNORE INTO friendships (user_lo, user_hi, created_at) VALUES (?, ?, ?)")
        .bind(lo)
        .bind(hi)
        .bind(now())
        .execute(&mut *tx)
        .await?;
    tx.commit().await
}

pub async fn send_request(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<AddFriend>,
) -> AppResult<Json<Value>> {
    let target = sqlx::query_as::<_, UserPublic>("SELECT id, username FROM users WHERE username = ?")
        .bind(req.username.trim())
        .fetch_optional(&state.db)
        .await?
        .ok_or_else(|| AppError::not_found("No one has that username."))?;

    if target.id == me.id {
        return Err(AppError::bad("That's you."));
    }
    if db::are_friends(&state.db, me.id, target.id).await? {
        return Err(AppError::Conflict(format!(
            "You're already friends with {}.",
            target.username
        )));
    }

    // If they already asked us, sending a request back just accepts theirs.
    let reverse: Option<(i64,)> =
        sqlx::query_as("SELECT 1 FROM friend_requests WHERE from_id = ? AND to_id = ?")
            .bind(target.id)
            .bind(me.id)
            .fetch_optional(&state.db)
            .await?;

    let status = if reverse.is_some() {
        make_friends(&state.db, me.id, target.id).await?;
        "friends"
    } else {
        sqlx::query(
            "INSERT OR IGNORE INTO friend_requests (from_id, to_id, created_at) VALUES (?, ?, ?)",
        )
        .bind(me.id)
        .bind(target.id)
        .bind(now())
        .execute(&state.db)
        .await?;
        "requested"
    };

    state.hub.send_both(me.id, target.id, &Event::FriendsChanged);
    Ok(Json(json!({ "status": status, "user": target })))
}

pub async fn accept(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    let exists: Option<(i64,)> =
        sqlx::query_as("SELECT 1 FROM friend_requests WHERE from_id = ? AND to_id = ?")
            .bind(user_id)
            .bind(me.id)
            .fetch_optional(&state.db)
            .await?;
    if exists.is_none() {
        return Err(AppError::not_found("That friend request no longer exists."));
    }
    make_friends(&state.db, me.id, user_id).await?;
    state.hub.send_both(me.id, user_id, &Event::FriendsChanged);
    Ok(Json(json!({ "status": "friends" })))
}

/// Declines an incoming request or cancels an outgoing one.
pub async fn delete_request(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    sqlx::query(
        "DELETE FROM friend_requests WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)",
    )
    .bind(me.id)
    .bind(user_id)
    .bind(user_id)
    .bind(me.id)
    .execute(&state.db)
    .await?;
    state.hub.send_both(me.id, user_id, &Event::FriendsChanged);
    Ok(Json(json!({ "ok": true })))
}

pub async fn remove(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    let (lo, hi) = pair(me.id, user_id);
    sqlx::query("DELETE FROM friendships WHERE user_lo = ? AND user_hi = ?")
        .bind(lo)
        .bind(hi)
        .execute(&state.db)
        .await?;
    state.hub.send_both(me.id, user_id, &Event::FriendsChanged);
    Ok(Json(json!({ "ok": true })))
}

/// Shared guard for chat endpoints.
pub async fn require_friend(state: &SharedState, me: i64, friend: i64) -> AppResult<()> {
    if db::are_friends(&state.db, me, friend).await? {
        Ok(())
    } else {
        Err(AppError::not_found("You can only message friends."))
    }
}

