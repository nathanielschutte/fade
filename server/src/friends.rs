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
         WHERE (f.user_lo = ? OR f.user_hi = ?) AND f.ended_at IS NULL",
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
         JOIN users u ON u.id = r.from_id
         WHERE r.to_id = ? AND r.resolved_at IS NULL ORDER BY r.created_at DESC",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    let outgoing = sqlx::query_as::<_, RequestEntry>(
        "SELECT u.id, u.username, r.created_at FROM friend_requests r
         JOIN users u ON u.id = r.to_id
         WHERE r.from_id = ? AND r.resolved_at IS NULL ORDER BY r.created_at DESC",
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

/// Appends to the friendship history. Never updated or deleted.
pub async fn record_event<'e, E: sqlx::SqliteExecutor<'e>>(
    db: E,
    actor: i64,
    other: i64,
    kind: &str,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO friend_events (actor_id, other_id, kind, created_at) VALUES (?, ?, ?, ?)",
    )
    .bind(actor)
    .bind(other)
    .bind(kind)
    .bind(now())
    .execute(db)
    .await
    .map(|_| ())
}

/// `accepter` says yes: pending requests between the two are resolved as
/// accepted, and the friendship starts (or restarts, if they were friends before).
async fn make_friends(db: &SqlitePool, accepter: i64, other: i64) -> sqlx::Result<()> {
    let (lo, hi) = pair(accepter, other);
    let at = now();
    let mut tx = db.begin().await?;
    sqlx::query(
        "UPDATE friend_requests SET resolved_at = ?, resolution = 'accepted'
         WHERE ((from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)) AND resolved_at IS NULL",
    )
    .bind(at)
    .bind(accepter)
    .bind(other)
    .bind(other)
    .bind(accepter)
    .execute(&mut *tx)
    .await?;
    // A past friendship reuses its row; friend_events keeps when it started before.
    sqlx::query(
        "INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (?, ?, ?)
         ON CONFLICT (user_lo, user_hi) DO UPDATE
           SET created_at = excluded.created_at, ended_at = NULL, ended_by = NULL
           WHERE friendships.ended_at IS NOT NULL",
    )
    .bind(lo)
    .bind(hi)
    .bind(at)
    .execute(&mut *tx)
    .await?;
    record_event(&mut *tx, accepter, other, "accepted").await?;
    tx.commit().await
}

pub async fn send_request(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<AddFriend>,
) -> AppResult<Json<Value>> {
    let target =
        sqlx::query_as::<_, UserPublic>("SELECT id, username FROM users WHERE username = ?")
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
    let reverse: Option<(i64,)> = sqlx::query_as(
        "SELECT 1 FROM friend_requests WHERE from_id = ? AND to_id = ? AND resolved_at IS NULL",
    )
    .bind(target.id)
    .bind(me.id)
    .fetch_optional(&state.db)
    .await?;

    let status = if reverse.is_some() {
        make_friends(&state.db, me.id, target.id).await?;
        "friends"
    } else {
        // Asking again after a decline or cancel reopens the same row; the
        // earlier outcome stays in friend_events.
        let opened = sqlx::query(
            "INSERT INTO friend_requests (from_id, to_id, created_at) VALUES (?, ?, ?)
             ON CONFLICT (from_id, to_id) DO UPDATE
               SET created_at = excluded.created_at, resolved_at = NULL, resolution = NULL
               WHERE friend_requests.resolved_at IS NOT NULL",
        )
        .bind(me.id)
        .bind(target.id)
        .bind(now())
        .execute(&state.db)
        .await?
        .rows_affected();
        if opened > 0 {
            record_event(&state.db, me.id, target.id, "requested").await?;
        }
        "requested"
    };

    tracing::info!(from = me.id, to = target.id, status, "friend request");
    state
        .hub
        .send_both(me.id, target.id, &Event::FriendsChanged);
    Ok(Json(json!({ "status": status, "user": target })))
}

pub async fn accept(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    let exists: Option<(i64,)> = sqlx::query_as(
        "SELECT 1 FROM friend_requests WHERE from_id = ? AND to_id = ? AND resolved_at IS NULL",
    )
    .bind(user_id)
    .bind(me.id)
    .fetch_optional(&state.db)
    .await?;
    if exists.is_none() {
        return Err(AppError::not_found("That friend request no longer exists."));
    }
    make_friends(&state.db, me.id, user_id).await?;
    tracing::info!(
        user_id = me.id,
        friend_id = user_id,
        "friend request accepted"
    );
    state.hub.send_both(me.id, user_id, &Event::FriendsChanged);
    Ok(Json(json!({ "status": "friends" })))
}

/// Declines an incoming request or cancels an outgoing one. The request is
/// marked resolved, not removed.
pub async fn delete_request(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    let at = now();
    for (from, to, resolution) in [(me.id, user_id, "canceled"), (user_id, me.id, "declined")] {
        let changed = sqlx::query(
            "UPDATE friend_requests SET resolved_at = ?, resolution = ?
             WHERE from_id = ? AND to_id = ? AND resolved_at IS NULL",
        )
        .bind(at)
        .bind(resolution)
        .bind(from)
        .bind(to)
        .execute(&state.db)
        .await?
        .rows_affected();
        if changed > 0 {
            record_event(&state.db, me.id, user_id, resolution).await?;
            tracing::info!(
                user_id = me.id,
                other_id = user_id,
                resolution,
                "friend request resolved"
            );
        }
    }
    state.hub.send_both(me.id, user_id, &Event::FriendsChanged);
    Ok(Json(json!({ "ok": true })))
}

pub async fn remove(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    // Ends the friendship but keeps the row (and every message). Chats and
    // profiles only see current friendships.
    let (lo, hi) = pair(me.id, user_id);
    let ended = sqlx::query(
        "UPDATE friendships SET ended_at = ?, ended_by = ?
         WHERE user_lo = ? AND user_hi = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(me.id)
    .bind(lo)
    .bind(hi)
    .execute(&state.db)
    .await?
    .rows_affected();
    if ended > 0 {
        record_event(&state.db, me.id, user_id, "unfriended").await?;
        tracing::info!(user_id = me.id, friend_id = user_id, "unfriended");
    }
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
