//! Editing sent texts (plan X29). The sender can change a text for 15
//! minutes after sending it; the other side sees the newest version, marked
//! "Edited", and can look back through the earlier ones.
//!
//! An edit is a new row (`message_edits`, `group_message_edits`): the text
//! it changes is never overwritten, so every version is kept (Rule 1). Each
//! is end-to-end encrypted like the text itself, with its associated data
//! bound to the message it edits (docs/how-napsack-works.md), so the server
//! can't move an edit onto another message. A direct edit goes to both
//! friends as `message_updated`; a group edit is sealed for exactly the
//! members the text went to, each getting only their own key.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;

use crate::{
    auth::AuthUser,
    db::{self, is_base64, now, Message},
    error::{AppError, AppResult},
    friends::require_reachable,
    groups::{self, E2eKeys, GroupMessage},
    ws::Event,
    SharedState,
};

/// How long after sending a text can still be changed.
pub const EDIT_WINDOW_SECS: i64 = 15 * 60;
/// Edits per text, so one message can't grow without end.
pub const MAX_EDITS: i64 = 20;
/// The text envelope an edit is sealed in (format 2, its own associated data).
const EDIT_FORMAT: i64 = 2;
const MAX_CIPHERTEXT_CHARS: usize = 20_000;
const MAX_CONTENT_BYTES: usize = 16 * 1024;

#[derive(Deserialize)]
pub struct NewEdit {
    ciphertext: String,
    format: i64,
    client_id: Option<String>,
}

#[derive(Serialize, FromRow)]
pub struct Edit {
    ciphertext: String,
    format: i64,
    created_at: i64,
}

/// Is this text still the sender's to change? `count`: edits so far.
fn check_editable(kind: &str, created_at: i64, count: i64, at: i64) -> AppResult<()> {
    if kind != "text" {
        return Err(AppError::bad("Only texts can be edited."));
    }
    if at - created_at > EDIT_WINDOW_SECS {
        return Err(AppError::bad(
            "Texts can be edited for 15 minutes after they're sent.",
        ));
    }
    if count >= MAX_EDITS {
        return Err(AppError::bad(
            "That text has been edited as many times as it can be.",
        ));
    }
    Ok(())
}

/// `PUT /api/chats/{friend}/messages/{id}/edit`: a new version of my text.
pub async fn edit_text(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((friend, message_id)): Path<(i64, i64)>,
    Json(req): Json<NewEdit>,
) -> AppResult<Json<Message>> {
    require_reachable(&state, me.id, friend).await?;
    let message = db::get_message(&state.db, message_id)
        .await?
        .filter(|m| m.sender_id == me.id && m.recipient_id == friend)
        .ok_or_else(|| AppError::not_found("There's no text of yours to edit there."))?;
    if req.format != EDIT_FORMAT {
        return Err(AppError::bad(
            "This server doesn't accept that edit format.",
        ));
    }
    if req.ciphertext.len() < 40 || !is_base64(&req.ciphertext, MAX_CIPHERTEXT_CHARS) {
        return Err(AppError::bad("That edit wasn't encrypted correctly."));
    }
    if req
        .client_id
        .as_deref()
        .is_some_and(|c| !db::valid_client_id(c))
    {
        return Err(AppError::bad("That edit id isn't valid."));
    }
    let already: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM message_edits WHERE message_id = ? AND client_id = ?)",
    )
    .bind(message_id)
    .bind(req.client_id.as_deref())
    .fetch_one(&state.db)
    .await?;
    if !already {
        let count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM message_edits WHERE message_id = ?")
                .bind(message_id)
                .fetch_one(&state.db)
                .await?;
        check_editable(&message.kind, message.created_at, count, now())?;
        sqlx::query(
            "INSERT INTO message_edits (message_id, ciphertext, format, created_at, client_id)
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(message_id)
        .bind(&req.ciphertext)
        .bind(req.format)
        .bind(now())
        .bind(req.client_id.as_deref())
        .execute(&state.db)
        .await?;
        tracing::info!(message_id, from = me.id, to = friend, "text edited");
    }
    let mut updated = vec![db::get_message(&state.db, message_id)
        .await?
        .ok_or_else(|| AppError::not_found("That text is gone."))?];
    crate::reactions::attach(&state.db, &mut updated).await?;
    let updated = updated.pop().expect("one message");
    if !already {
        state.hub.send_both(
            me.id,
            friend,
            &Event::MessageUpdated {
                message: updated.clone(),
            },
        );
    }
    Ok(Json(updated))
}

/// `GET /api/chats/{friend}/messages/{id}/edits`: every version after the
/// first, oldest first. Either friend can look.
pub async fn text_history(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((friend, message_id)): Path<(i64, i64)>,
) -> AppResult<Json<Vec<Edit>>> {
    db::get_message(&state.db, message_id)
        .await?
        .filter(|m| {
            (m.sender_id == me.id && m.recipient_id == friend)
                || (m.sender_id == friend && m.recipient_id == me.id)
        })
        .ok_or_else(|| AppError::not_found("Message not found."))?;
    let edits = sqlx::query_as::<_, Edit>(
        "SELECT ciphertext, format, created_at FROM message_edits WHERE message_id = ? ORDER BY id",
    )
    .bind(message_id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(edits))
}

#[derive(Deserialize)]
pub struct NewGroupEdit {
    format: i64,
    content: String,
    #[serde(flatten)]
    keys: E2eKeys,
}

#[derive(Serialize, FromRow)]
pub struct GroupEdit {
    content: String,
    client_id: String,
    created_at: i64,
    /// The viewer's own wrap of this version's key.
    key: Option<String>,
}

/// `PUT /api/groups/{id}/messages/{message_id}/edit`: a new version of my
/// encrypted group text, sealed for the members it went to.
pub async fn edit_group_text(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((group, message_id)): Path<(i64, i64)>,
    Json(req): Json<NewGroupEdit>,
) -> AppResult<Json<GroupMessage>> {
    use base64::{engine::general_purpose::STANDARD, Engine};
    groups::require_member(&state.db, group, me.id).await?;
    let message = groups::get_message(&state.db, message_id)
        .await
        .ok()
        .filter(|m| m.group_id == group && m.sender_id == me.id)
        .ok_or_else(|| AppError::not_found("There's no text of yours to edit there."))?;
    // Encrypted texts only: an edit is sealed for the members the text went to.
    if message.format != groups::FORMAT_E2E
        || message.pic_id.is_some()
        || req.format != groups::FORMAT_E2E
    {
        return Err(AppError::bad("Only encrypted texts can be edited."));
    }
    let size = STANDARD.decode(&req.content).map(|b| b.len()).unwrap_or(0);
    if !(12 + 16 + 1..=MAX_CONTENT_BYTES).contains(&size) {
        return Err(AppError::bad("That edit is empty or too long."));
    }
    let already: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM group_message_edits WHERE message_id = ? AND client_id = ?)",
    )
    .bind(message_id)
    .bind(&req.keys.client_id)
    .fetch_one(&state.db)
    .await?;
    if !already {
        let count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM group_message_edits WHERE message_id = ?")
                .bind(message_id)
                .fetch_one(&state.db)
                .await?;
        check_editable(&message.kind, message.created_at, count, now())?;
        let mut recipients: Vec<i64> = message
            .recipients_json
            .as_deref()
            .and_then(|j| serde_json::from_str(j).ok())
            .unwrap_or_default();
        recipients.sort_unstable();
        let wraps = groups::check_e2e(&recipients, &req.keys)?;
        let mut tx = crate::db::write_tx(&state.db).await?;
        let edit: i64 = sqlx::query_scalar(
            "INSERT INTO group_message_edits (message_id, content, client_id, created_at)
             VALUES (?, ?, ?, ?) RETURNING id",
        )
        .bind(message_id)
        .bind(&req.content)
        .bind(&req.keys.client_id)
        .bind(now())
        .fetch_one(&mut *tx)
        .await
        .map_err(groups::replay)?;
        for (user, wrapped) in &wraps {
            sqlx::query("INSERT INTO group_edit_keys (edit_id, user_id, wrapped) VALUES (?, ?, ?)")
                .bind(edit)
                .bind(user)
                .bind(wrapped)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        tracing::info!(
            group_id = group,
            message_id,
            from = me.id,
            "group text edited"
        );
        groups::broadcast(&state, groups::get_message(&state.db, message_id).await?).await?;
    }
    let mut mine = groups::get_message(&state.db, message_id).await?;
    groups::prepare_for(&state.db, me.id, std::slice::from_mut(&mut mine)).await?;
    Ok(Json(mine))
}

/// `GET /api/groups/{id}/messages/{message_id}/edits`: every version after
/// the first, oldest first, each with the viewer's own key. Only for members
/// whose history includes the text.
pub async fn group_text_history(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((group, message_id)): Path<(i64, i64)>,
) -> AppResult<Json<Vec<GroupEdit>>> {
    groups::require_member(&state.db, group, me.id).await?;
    let in_group = groups::get_message(&state.db, message_id)
        .await
        .is_ok_and(|m| m.group_id == group);
    if !in_group
        || !groups::audience(&state.db, group, message_id)
            .await?
            .contains(&me.id)
    {
        return Err(AppError::not_found("Message not found."));
    }
    let edits = sqlx::query_as::<_, GroupEdit>(
        "SELECT e.content, e.client_id, e.created_at,
                (SELECT k.wrapped FROM group_edit_keys k WHERE k.edit_id = e.id AND k.user_id = ?) AS key
         FROM group_message_edits e WHERE e.message_id = ? ORDER BY e.id",
    )
    .bind(me.id)
    .bind(message_id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(edits))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[test]
    fn only_recent_texts_with_edits_left() {
        assert!(check_editable("text", 1000, 0, 1000 + EDIT_WINDOW_SECS).is_ok());
        assert!(check_editable("text", 1000, 0, 1001 + EDIT_WINDOW_SECS).is_err());
        assert!(check_editable("snap", 1000, 0, 1000).is_err());
        assert!(check_editable("text", 1000, MAX_EDITS - 1, 1000).is_ok());
        assert!(check_editable("text", 1000, MAX_EDITS, 1000).is_err());
    }

    #[tokio::test]
    async fn the_newest_edit_shows_and_the_original_stays() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        sqlx::query("INSERT INTO messages (id, sender_id, recipient_id, kind, ciphertext, format, created_at) VALUES (9, 1, 2, 'text', 'first', 2, 5)")
            .execute(&db).await.unwrap();
        let m = db::get_message(&db, 9).await.unwrap().unwrap();
        assert_eq!((m.edit_ciphertext, m.edited_at), (None, None));
        for (ct, at) in [("second", 6), ("third", 7)] {
            sqlx::query("INSERT INTO message_edits (message_id, ciphertext, format, created_at) VALUES (9, ?, 2, ?)")
                .bind(ct).bind(at).execute(&db).await.unwrap();
        }
        let m = db::get_message(&db, 9).await.unwrap().unwrap();
        assert_eq!(
            m.ciphertext.as_deref(),
            Some("first"),
            "the text itself never changes"
        );
        assert_eq!(
            (m.edit_ciphertext.as_deref(), m.edit_format, m.edited_at),
            (Some("third"), Some(2), Some(7))
        );
    }
}
