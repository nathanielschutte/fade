use std::sync::LazyLock;

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
    friends::{require_friend_or_team, require_reachable},
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

/// A page of the chat between `?1` and `?2`: the `?4` newest messages older
/// than `?3`, newest first. The newest that many each way (two short runs
/// of messages_pair, newest first), then the newest of those, so a page
/// reads the same however long the chat's history is.
static PAGE: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT {MESSAGE_COLS} FROM messages
         WHERE id IN (SELECT id FROM (SELECT id FROM messages
                                      WHERE sender_id = ?1 AND recipient_id = ?2 AND id < ?3
                                      ORDER BY id DESC LIMIT ?4)
                      UNION ALL
                      SELECT id FROM (SELECT id FROM messages
                                      WHERE sender_id = ?2 AND recipient_id = ?1 AND id < ?3
                                      ORDER BY id DESC LIMIT ?4))
         ORDER BY id DESC LIMIT ?4"
    )
});

/// Messages between the caller and a friend, oldest first.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend_id): Path<i64>,
    Query(page): Query<Page>,
) -> AppResult<Json<Vec<Message>>> {
    require_friend_or_team(&state, me.id, friend_id).await?;
    let limit = page.limit.unwrap_or(50).clamp(1, 200);
    let before = page.before.unwrap_or(i64::MAX);
    Ok(Json(
        page_of(&state.db, me.id, friend_id, before, limit).await?,
    ))
}

/// Up to `limit` messages between `me` and `friend` older than `before`,
/// oldest first, with their reactions.
pub(crate) async fn page_of(
    db: &sqlx::SqlitePool,
    me: i64,
    friend: i64,
    before: i64,
    limit: i64,
) -> sqlx::Result<Vec<Message>> {
    let mut messages = sqlx::query_as::<_, Message>(&PAGE)
        .bind(me)
        .bind(friend)
        .bind(before)
        .bind(limit)
        .fetch_all(db)
        .await?;
    messages.reverse();
    crate::reactions::attach(db, &mut messages).await?;
    Ok(messages)
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
    require_friend_or_team(&state, me.id, friend_id).await?;
    let at = now();
    let result = sqlx::query(MARK_READ)
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
        crate::apns::badge_changed(&state, me.id);
    }
    Ok(Json(json!({ "updated": result.rows_affected() })))
}

/// Marks the texts `?2` sent `?3` read at `?1`. The last line is true of
/// every row the rest picks: it's messages_waiting's condition, so SQLite
/// reads just what's unread rather than the whole chat.
const MARK_READ: &str = "UPDATE messages SET read_at = ?
     WHERE sender_id = ? AND recipient_id = ? AND kind = 'text' AND read_at IS NULL
       AND ((kind = 'text' AND read_at IS NULL) OR (kind = 'snap' AND snap_state = 'pending'))";

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::db::tests::{assert_searches, plan, temp_db};
    use crate::testdata::{self, *};

    /// Marking read as it was before migration 0028.
    pub(crate) const OLD_MARK_READ: &str = "UPDATE messages SET read_at = ?
         WHERE sender_id = ? AND recipient_id = ? AND kind = 'text' AND read_at IS NULL";

    pub(crate) const NEW_MARK_READ: &str = MARK_READ;

    /// A page as the old query read it (both ways at once, sorted).
    pub(crate) async fn old_page_of(
        db: &sqlx::SqlitePool,
        me: i64,
        friend: i64,
        before: i64,
        limit: i64,
    ) -> Vec<Message> {
        let mut messages = sqlx::query_as::<_, Message>(&format!(
            "SELECT {MESSAGE_COLS} FROM messages
             WHERE ((sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?))
               AND id < ?
             ORDER BY id DESC LIMIT ?"
        ))
        .bind(me)
        .bind(friend)
        .bind(friend)
        .bind(me)
        .bind(before)
        .bind(limit)
        .fetch_all(db)
        .await
        .unwrap();
        messages.reverse();
        crate::reactions::attach(db, &mut messages).await.unwrap();
        messages
    }

    /// Every chat in the mix, paged through from the newest in pages of
    /// several sizes: the same messages, edits, and reactions, in order.
    #[tokio::test]
    async fn pages_are_what_they_were() {
        let db = temp_db().await;
        testdata::mix(&db).await;
        let mut seen = 0;
        for (me, friend) in [
            (ANA, BEN),
            (BEN, ANA),
            (ANA, CAL),
            (ANA, TEAM),
            (ANA, EVE),
            (BEN, GUS),
            (ANA, ANA),
        ] {
            for limit in [1, 7, 50, 200] {
                let mut before = i64::MAX;
                loop {
                    let old = old_page_of(&db, me, friend, before, limit).await;
                    let new = page_of(&db, me, friend, before, limit).await.unwrap();
                    assert_eq!(
                        serde_json::to_value(&new).unwrap(),
                        serde_json::to_value(&old).unwrap(),
                        "{me} and {friend}, {limit} before {before}"
                    );
                    seen += new.len();
                    match new.first() {
                        Some(oldest) if new.len() as i64 == limit => before = oldest.id,
                        _ => break,
                    }
                }
            }
        }
        assert!(seen > 500, "{seen}");
        let newest = page_of(&db, ANA, BEN, i64::MAX, 3).await.unwrap();
        assert!(newest.windows(2).all(|w| w[0].id < w[1].id), "oldest first");
    }

    /// Marking a chat read changes the rows the old statement did: each
    /// unread text from that friend, nothing else.
    #[tokio::test]
    async fn marking_read_marks_what_it_did() {
        let db = temp_db().await;
        testdata::mix(&db).await;
        for (me, friend) in [
            (ANA, BEN),
            (BEN, ANA),
            (ANA, JO),
            (ANA, TEAM),
            (CAL, ANA),
            (ANA, EVE),
        ] {
            let state = |db: sqlx::SqlitePool| async move {
                sqlx::query_as::<_, (i64, Option<i64>)>(
                    "SELECT id, read_at FROM messages ORDER BY id",
                )
                .fetch_all(&db)
                .await
                .unwrap()
            };
            let before = state(db.clone()).await;
            let unread: Vec<i64> = sqlx::query_scalar(
                "SELECT id FROM messages
                 WHERE sender_id = ? AND recipient_id = ? AND kind = 'text' AND read_at IS NULL",
            )
            .bind(friend)
            .bind(me)
            .fetch_all(&db)
            .await
            .unwrap();
            let changed = sqlx::query(MARK_READ)
                .bind(-7)
                .bind(friend)
                .bind(me)
                .execute(&db)
                .await
                .unwrap()
                .rows_affected();
            assert_eq!(changed, unread.len() as u64, "{me} reading {friend}");
            for ((id, was), (_, now)) in before.iter().zip(state(db.clone()).await) {
                let want = if unread.contains(id) { Some(-7) } else { *was };
                assert_eq!(now, want, "message {id}, {me} reading {friend}");
            }
        }
    }

    /// A page reads a few rows of messages_pair each way, never the chat's
    /// whole history; marking read reads only what's unread.
    #[tokio::test]
    async fn pages_and_reads_search_indexes() {
        let db = temp_db().await;
        assert_searches(&db, &PAGE, &[], &["messages"]).await;
        assert_searches(&db, MARK_READ, &[], &[]).await;
        let steps = plan(&db, MARK_READ).await;
        assert!(
            steps.iter().any(|s| s.contains("INDEX messages_waiting")),
            "{steps:#?}"
        );
    }
}
