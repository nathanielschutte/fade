use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::AuthUser,
    db::{self, is_base64, now, Message, MESSAGE_COLS},
    error::{AppError, AppResult},
    friends::{require_friend, require_reachable},
    version,
    ws::Event,
    SharedState,
};

/// The client caps texts at 2000 characters. Worst case that's 8000 UTF-8 bytes,
/// more once the format 2 JSON envelope escapes quotes and control characters,
/// plus a 12-byte IV and 16-byte tag, base64-encoded.
const MAX_CIPHERTEXT_CHARS: usize = 20_000;

#[derive(Deserialize)]
pub struct Page {
    /// Return messages older than this id (for scrolling back).
    before: Option<i64>,
    limit: Option<i64>,
}

/// Messages between the caller and a friend, oldest first.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend_id): Path<i64>,
    Query(page): Query<Page>,
) -> AppResult<Json<Vec<Message>>> {
    require_friend(&state, me.id, friend_id).await?;
    let limit = page.limit.unwrap_or(50).clamp(1, 200);
    let before = page.before.unwrap_or(i64::MAX);

    let mut messages = sqlx::query_as::<_, Message>(&format!(
        "SELECT {MESSAGE_COLS} FROM messages
         WHERE ((sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?))
           AND id < ?
         ORDER BY id DESC LIMIT ?"
    ))
    .bind(me.id)
    .bind(friend_id)
    .bind(friend_id)
    .bind(me.id)
    .bind(before)
    .bind(limit)
    .fetch_all(&state.db)
    .await?;
    messages.reverse();
    crate::reactions::attach(&state.db, &mut messages).await?;
    Ok(Json(messages))
}

#[derive(Deserialize)]
pub struct NewText {
    /// base64 of IV || AES-GCM ciphertext. The server can't read it.
    ciphertext: String,
    /// Clients from before formats existed don't send one; they wrote format 1.
    #[serde(default = "version::default_format")]
    format: i64,
    /// Picked by the app; sending again with the same one returns the stored
    /// message instead of a second copy (a retry after a dropped connection).
    client_id: Option<String>,
}

pub async fn send_text(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend_id): Path<i64>,
    Json(req): Json<NewText>,
) -> AppResult<Json<Message>> {
    require_reachable(&state, me.id, friend_id).await?;
    version::check_text_format(req.format)?;
    if req.ciphertext.len() > MAX_CIPHERTEXT_CHARS {
        return Err(AppError::bad("That message is too long."));
    }
    // 12-byte IV + 16-byte tag + at least one byte = 40 base64 characters minimum.
    if req.ciphertext.len() < 40 || !is_base64(&req.ciphertext, MAX_CIPHERTEXT_CHARS) {
        return Err(AppError::bad("That message wasn't encrypted correctly."));
    }
    if req
        .client_id
        .as_deref()
        .is_some_and(|c| !db::valid_client_id(c))
    {
        return Err(AppError::bad("That message id isn't valid."));
    }
    if let Some(stored) = db::sent_before(&state.db, me.id, req.client_id.as_deref()).await? {
        tracing::debug!(
            message_id = stored.id,
            from = me.id,
            "text resent; already stored"
        );
        return Ok(Json(stored));
    }

    let message = sqlx::query_as::<_, Message>(&format!(
        "INSERT INTO messages (sender_id, recipient_id, kind, ciphertext, format, created_at, client_id)
         VALUES (?, ?, 'text', ?, ?, ?, ?) RETURNING {MESSAGE_COLS}"
    ))
    .bind(me.id)
    .bind(friend_id)
    .bind(&req.ciphertext)
    .bind(req.format)
    .bind(now())
    .bind(req.client_id.as_deref())
    .fetch_one(&state.db)
    .await;
    let message = match message {
        Ok(m) => m,
        // Two copies of the same send raced in: the other one stored it.
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            match db::sent_before(&state.db, me.id, req.client_id.as_deref()).await? {
                Some(stored) => return Ok(Json(stored)),
                None => return Err(AppError::Conflict("That message was already sent.".into())),
            }
        }
        Err(e) => return Err(e.into()),
    };

    tracing::debug!(
        message_id = message.id,
        from = me.id,
        to = friend_id,
        bytes = req.ciphertext.len(),
        "text sent"
    );
    state.hub.send_both(
        me.id,
        friend_id,
        &Event::Message {
            message: message.clone(),
        },
    );
    crate::push::notify(
        &state,
        friend_id,
        crate::push::Note {
            title: crate::people::name_for(&state.db, friend_id, me.id).await?,
            body: "New message".into(),
            tag: format!("dm-{}", me.id),
            url: format!("/#chat={}", me.id),
        },
    );
    Ok(Json(message))
}

/// Marks the friend's texts to the caller as read. Snaps are marked when opened.
pub async fn mark_read(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend_id): Path<i64>,
) -> AppResult<Json<Value>> {
    require_friend(&state, me.id, friend_id).await?;
    let at = now();
    let result = sqlx::query(
        "UPDATE messages SET read_at = ?
         WHERE sender_id = ? AND recipient_id = ? AND kind = 'text' AND read_at IS NULL",
    )
    .bind(at)
    .bind(friend_id)
    .bind(me.id)
    .execute(&state.db)
    .await?;

    if result.rows_affected() > 0 {
        // The friend sees "Seen"; the caller's other devices clear their badge.
        state
            .hub
            .send_both(me.id, friend_id, &Event::Read { by: me.id, at });
    }
    Ok(Json(json!({ "updated": result.rows_affected() })))
}
