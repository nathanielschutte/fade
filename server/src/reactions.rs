//! Reactions (F11). One per person per message, from a small fixed set; the
//! newest row wins and a taken-back reaction is a row with no value (Rule 1).
//!
//! In direct chats the emoji is end-to-end encrypted (format 2, associated
//! data bound to the message it reacts to), so the server sees that a
//! reaction happened, not which. In groups it's plain, like group texts.
//!
//! A change is delivered by sending the message again with its current
//! reactions (`message_updated` / `group_message`), the same way an opened
//! pic updates.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    db::{self, is_base64, now, Message},
    error::{AppError, AppResult},
    friends::require_reachable,
    groups::{self, GroupMessage},
    push::{self, Note},
    ws::Event,
    SharedState,
};

/// The reactions clients offer. Groups are checked against it; direct-chat
/// reactions are encrypted, so clients check them when they decrypt.
pub const EMOJI: &[&str] = &["❤️", "😂", "😮", "😢", "👍", "👎"];
/// Encryption format of direct-chat reactions (shared/crypto/crypto.js).
const REACTION_FORMAT: i64 = 2;
/// An emoji is a few bytes; with IV and tag, base64'd, well under this.
const MAX_REACTION_CHARS: usize = 200;

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct Reaction {
    pub message_id: i64,
    pub sender_id: i64,
    /// base64 of IV || AES-GCM(emoji). Only the two friends can read it.
    pub ciphertext: String,
    pub format: i64,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct GroupReaction {
    pub message_id: i64,
    pub user_id: i64,
    pub emoji: String,
    pub created_at: i64,
}

/// Current reactions on these direct messages, oldest first.
pub async fn attach(db: &SqlitePool, messages: &mut [Message]) -> sqlx::Result<()> {
    if messages.is_empty() {
        return Ok(());
    }
    let ids = serde_json::to_string(&messages.iter().map(|m| m.id).collect::<Vec<_>>())
        .unwrap_or_default();
    let all: Vec<Reaction> = sqlx::query_as(
        "SELECT r.message_id, r.sender_id, r.ciphertext, r.format, r.created_at FROM reactions r
         WHERE r.message_id IN (SELECT value FROM json_each(?))
           AND r.ciphertext IS NOT NULL
           AND r.id = (SELECT MAX(x.id) FROM reactions x
                       WHERE x.message_id = r.message_id AND x.sender_id = r.sender_id)
         ORDER BY r.id",
    )
    .bind(ids)
    .fetch_all(db)
    .await?;
    for m in messages.iter_mut() {
        m.reactions = all
            .iter()
            .filter(|r| r.message_id == m.id)
            .cloned()
            .collect();
    }
    Ok(())
}

/// The same for group messages.
pub async fn attach_group(db: &SqlitePool, messages: &mut [GroupMessage]) -> sqlx::Result<()> {
    if messages.is_empty() {
        return Ok(());
    }
    let ids = serde_json::to_string(&messages.iter().map(|m| m.id).collect::<Vec<_>>())
        .unwrap_or_default();
    let all: Vec<GroupReaction> = sqlx::query_as(
        "SELECT r.message_id, r.user_id, r.emoji, r.created_at FROM group_reactions r
         WHERE r.message_id IN (SELECT value FROM json_each(?))
           AND r.emoji IS NOT NULL
           AND r.id = (SELECT MAX(x.id) FROM group_reactions x
                       WHERE x.message_id = r.message_id AND x.user_id = r.user_id)
         ORDER BY r.id",
    )
    .bind(ids)
    .fetch_all(db)
    .await?;
    for m in messages.iter_mut() {
        m.reactions = all
            .iter()
            .filter(|r| r.message_id == m.id)
            .cloned()
            .collect();
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct SetReaction {
    /// Absent or null takes the reaction back.
    ciphertext: Option<String>,
    #[serde(default = "default_format")]
    format: i64,
}

fn default_format() -> i64 {
    REACTION_FORMAT
}

/// `PUT /api/chats/{friend}/messages/{id}/reaction`
pub async fn react(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((friend, message_id)): Path<(i64, i64)>,
    Json(req): Json<SetReaction>,
) -> AppResult<Json<Message>> {
    require_reachable(&state, me.id, friend).await?;
    let message = db::get_message(&state.db, message_id)
        .await?
        .filter(|m| {
            (m.sender_id == me.id && m.recipient_id == friend)
                || (m.sender_id == friend && m.recipient_id == me.id)
        })
        .ok_or_else(|| AppError::not_found("Message not found."))?;
    if req.format != REACTION_FORMAT {
        return Err(AppError::bad(format!(
            "This server doesn't accept reaction format {} yet.",
            req.format
        )));
    }
    if let Some(ct) = &req.ciphertext {
        if !is_base64(ct, MAX_REACTION_CHARS) || ct.len() < 40 {
            return Err(AppError::bad("That reaction wasn't encrypted correctly."));
        }
    }
    sqlx::query(
        "INSERT INTO reactions (message_id, sender_id, ciphertext, format, created_at) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(message.id)
    .bind(me.id)
    .bind(&req.ciphertext)
    .bind(req.format)
    .bind(now())
    .execute(&state.db)
    .await?;
    let mut updated = vec![message];
    attach(&state.db, &mut updated).await?;
    let updated = updated.pop().expect("one message");
    tracing::debug!(
        message_id,
        from = me.id,
        to = friend,
        removed = req.ciphertext.is_none(),
        "reaction"
    );
    state.hub.send_both(
        me.id,
        friend,
        &Event::MessageUpdated {
            message: updated.clone(),
        },
    );
    if req.ciphertext.is_some() {
        let name = crate::people::name_for(&state.db, friend, me.id).await?;
        push::notify(
            &state,
            friend,
            Note {
                title: name,
                body: if updated.sender_id == friend {
                    "Reacted to your message".into()
                } else {
                    "Reacted to a message".into()
                },
                tag: format!("dm-{}", me.id),
                url: format!("/#chat={}", me.id),
            },
        );
    }
    Ok(Json(updated))
}

#[derive(Deserialize)]
pub struct SetGroupReaction {
    /// One of EMOJI, or absent/null to take it back.
    emoji: Option<String>,
}

/// `PUT /api/groups/{id}/messages/{message_id}/reaction`
pub async fn react_group(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((group, message_id)): Path<(i64, i64)>,
    Json(req): Json<SetGroupReaction>,
) -> AppResult<Json<GroupMessage>> {
    let (_, visible_after) = groups::require_member(&state.db, group, me.id).await?;
    if let Some(e) = &req.emoji {
        if !EMOJI.contains(&e.as_str()) {
            return Err(AppError::bad("That reaction isn't one of the choices."));
        }
    }
    let target: Option<(i64, String)> = sqlx::query_as(
        "SELECT sender_id, kind FROM group_messages WHERE id = ? AND group_id = ? AND id > ?",
    )
    .bind(message_id)
    .bind(group)
    .bind(visible_after)
    .fetch_optional(&state.db)
    .await?;
    let Some((author, kind)) = target else {
        return Err(AppError::not_found("Message not found."));
    };
    if kind != "text" {
        return Err(AppError::bad("You can't react to that."));
    }
    sqlx::query(
        "INSERT INTO group_reactions (message_id, user_id, emoji, created_at) VALUES (?, ?, ?, ?)",
    )
    .bind(message_id)
    .bind(me.id)
    .bind(&req.emoji)
    .bind(now())
    .execute(&state.db)
    .await?;
    let mut message = groups::get_message(&state.db, message_id).await?;
    groups::broadcast(&state, message.clone()).await?;
    groups::prepare_for(&state.db, me.id, std::slice::from_mut(&mut message)).await?;
    if req.emoji.is_some() && author != me.id {
        let group_name: String = sqlx::query_scalar("SELECT name FROM groups WHERE id = ?")
            .bind(group)
            .fetch_one(&state.db)
            .await?;
        let name = crate::people::name_for(&state.db, author, me.id).await?;
        push::notify(
            &state,
            author,
            Note {
                title: group_name,
                body: format!("{name} reacted to your message"),
                tag: format!("group-{group}"),
                url: format!("/#group={group}"),
            },
        );
    }
    Ok(Json(message))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::{tests::temp_db, MESSAGE_COLS};

    #[tokio::test]
    async fn newest_reaction_wins_and_taking_back_keeps_the_rows() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben")] {
            sqlx::query(
                "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at)
                 VALUES (?, ?, 'h', 'k', 'w', 0)",
            )
            .bind(id)
            .bind(name)
            .execute(&db)
            .await
            .unwrap();
        }
        for id in [10, 11] {
            sqlx::query(
                "INSERT INTO messages (id, sender_id, recipient_id, kind, ciphertext, created_at) VALUES (?, 1, 2, 'text', 'x', 0)",
            )
            .bind(id)
            .execute(&db)
            .await
            .unwrap();
        }
        let add = |msg: i64, who: i64, ct: Option<&'static str>| {
            let db = db.clone();
            async move {
                sqlx::query("INSERT INTO reactions (message_id, sender_id, ciphertext, format, created_at) VALUES (?, ?, ?, 2, 0)")
                    .bind(msg)
                    .bind(who)
                    .bind(ct)
                    .execute(&db)
                    .await
                    .unwrap();
            }
        };
        add(10, 2, Some("first")).await;
        add(10, 2, Some("second")).await; // changed their mind
        add(10, 1, Some("mine")).await;
        add(11, 2, Some("gone")).await;
        add(11, 2, None).await; // taken back
        let mut msgs: Vec<Message> =
            sqlx::query_as(&format!("SELECT {MESSAGE_COLS} FROM messages ORDER BY id"))
                .fetch_all(&db)
                .await
                .unwrap();
        attach(&db, &mut msgs).await.unwrap();
        let got: Vec<Vec<&str>> = msgs
            .iter()
            .map(|m| m.reactions.iter().map(|r| r.ciphertext.as_str()).collect())
            .collect();
        assert_eq!(got, vec![vec!["second", "mine"], vec![]]);
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM reactions")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rows, 5, "nothing deleted");
    }
}
