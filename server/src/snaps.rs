//! Snaps are view-once photos, encrypted in the sender's browser. The server
//! only ever holds ciphertext, and only in this process's memory: never
//! written to the database, disk, or object storage. A snap is
//! removed the moment its recipient fetches it, when it expires, or when the
//! server restarts. The database keeps a metadata row so the chat can show
//! "Opened" or "Expired".

use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

use axum::{
    body::Bytes,
    extract::{Path, State},
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};

use crate::{
    auth::AuthUser,
    db::{self, now, Message, MESSAGE_COLS},
    error::{AppError, AppResult},
    friends::require_friend,
    ws::Event,
    SharedState,
};

struct Snap {
    sender_id: i64,
    recipient_id: i64,
    data: Bytes,
    expires_at: Instant,
}

#[derive(Default)]
struct Inner {
    snaps: HashMap<i64, Snap>,
    total_bytes: usize,
}

pub struct SnapStore {
    inner: Mutex<Inner>,
    pool_bytes: usize,
    ttl: Duration,
}

pub enum Take {
    Found {
        data: Bytes,
        sender_id: i64,
    },
    /// Not held (already opened, expired, or lost in a restart).
    Missing,
}

impl SnapStore {
    pub fn new(pool_bytes: usize, ttl: Duration) -> Self {
        Self {
            inner: Mutex::new(Inner::default()),
            pool_bytes,
            ttl,
        }
    }

    fn has_room(&self, len: usize) -> bool {
        self.inner.lock().unwrap().total_bytes + len <= self.pool_bytes
    }

    fn put(&self, id: i64, snap: Snap) -> bool {
        let mut inner = self.inner.lock().unwrap();
        let len = snap.data.len();
        if inner.total_bytes + len > self.pool_bytes {
            return false;
        }
        inner.total_bytes += len;
        inner.snaps.insert(id, snap);
        true
    }

    /// Removes and returns the snap, but only for its recipient.
    /// Anyone else gets `Missing` and the snap stays put.
    fn take(&self, id: i64, recipient_id: i64) -> Take {
        let mut inner = self.inner.lock().unwrap();
        let is_recipient = inner
            .snaps
            .get(&id)
            .is_some_and(|s| s.recipient_id == recipient_id);
        if !is_recipient {
            return Take::Missing;
        }
        let snap = inner.snaps.remove(&id).expect("checked above");
        inner.total_bytes -= snap.data.len();
        Take::Found {
            data: snap.data,
            sender_id: snap.sender_id,
        }
    }

    /// Drops expired snaps. Returns (message_id, sender_id, recipient_id) for each.
    fn sweep(&self) -> Vec<(i64, i64, i64)> {
        let now = Instant::now();
        let mut inner = self.inner.lock().unwrap();
        let expired: Vec<i64> = inner
            .snaps
            .iter()
            .filter(|(_, s)| s.expires_at <= now)
            .map(|(id, _)| *id)
            .collect();
        let mut out = Vec::with_capacity(expired.len());
        for id in expired {
            if let Some(s) = inner.snaps.remove(&id) {
                inner.total_bytes -= s.data.len();
                out.push((id, s.sender_id, s.recipient_id));
            }
        }
        out
    }
}

/// 12-byte IV + 16-byte AES-GCM tag. Anything shorter can't be a real snap.
const MIN_SNAP_BYTES: usize = 29;

/// Body is the encrypted image: IV || AES-GCM ciphertext. No multipart needed.
/// The server can't see or check the image, only its size.
pub async fn upload(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend_id): Path<i64>,
    body: Bytes,
) -> AppResult<Json<Message>> {
    require_friend(&state, me.id, friend_id).await?;

    if body.len() < MIN_SNAP_BYTES {
        return Err(AppError::bad("That snap wasn't encrypted correctly."));
    }
    if body.len() > state.config.snap_max_bytes {
        return Err(AppError::PayloadTooLarge("That photo is too large.".into()));
    }
    if !state.snaps.has_room(body.len()) {
        return Err(AppError::Unavailable(
            "The server is holding too many unopened snaps. Try again later.".into(),
        ));
    }

    let message = sqlx::query_as::<_, Message>(&format!(
        "INSERT INTO messages (sender_id, recipient_id, kind, snap_state, created_at)
         VALUES (?, ?, 'snap', 'pending', ?) RETURNING {MESSAGE_COLS}"
    ))
    .bind(me.id)
    .bind(friend_id)
    .bind(now())
    .fetch_one(&state.db)
    .await?;

    let stored = state.snaps.put(
        message.id,
        Snap {
            sender_id: me.id,
            recipient_id: friend_id,
            data: body,
            expires_at: Instant::now() + state.snaps.ttl,
        },
    );
    if !stored {
        sqlx::query("DELETE FROM messages WHERE id = ?")
            .bind(message.id)
            .execute(&state.db)
            .await?;
        return Err(AppError::Unavailable(
            "The server is holding too many unopened snaps. Try again later.".into(),
        ));
    }

    state.hub.send_both(
        me.id,
        friend_id,
        &Event::Message {
            message: message.clone(),
        },
    );
    Ok(Json(message))
}

async fn set_snap_state(
    state: &SharedState,
    id: i64,
    snap_state: &str,
) -> AppResult<Option<Message>> {
    sqlx::query(
        "UPDATE messages SET snap_state = ?, read_at = COALESCE(read_at, ?)
         WHERE id = ? AND kind = 'snap'",
    )
    .bind(snap_state)
    .bind(now())
    .bind(id)
    .execute(&state.db)
    .await?;
    Ok(db::get_message(&state.db, id).await?)
}

/// View-once: the first successful fetch by the recipient removes the snap.
pub async fn view(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Response> {
    match state.snaps.take(id, me.id) {
        Take::Found { data, sender_id } => {
            if let Some(message) = set_snap_state(&state, id, "opened").await? {
                state
                    .hub
                    .send_both(sender_id, me.id, &Event::MessageUpdated { message });
            }
            let mut headers = HeaderMap::new();
            headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/octet-stream"));
            headers.insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("no-store, private, max-age=0"),
            );
            headers.insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
            Ok((headers, data).into_response())
        }
        Take::Missing => {
            // Only reveal anything to the actual recipient.
            let msg = db::get_message(&state.db, id).await?;
            match msg {
                Some(m) if m.recipient_id == me.id && m.kind == "snap" => {
                    if m.snap_state.as_deref() == Some("pending") {
                        if let Some(message) = set_snap_state(&state, id, "expired").await? {
                            state.hub.send_both(
                                message.sender_id,
                                me.id,
                                &Event::MessageUpdated { message },
                            );
                        }
                    }
                    Err(AppError::Gone(
                        "This snap was already opened or has expired.".into(),
                    ))
                }
                _ => Err(AppError::not_found("Snap not found.")),
            }
        }
    }
}

/// Every minute: drop expired snaps, tell both people, and clear old sessions.
pub fn spawn_sweeper(state: SharedState) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            for (id, sender, recipient) in state.snaps.sweep() {
                match set_snap_state(&state, id, "expired").await {
                    Ok(Some(message)) => {
                        state
                            .hub
                            .send_both(sender, recipient, &Event::MessageUpdated { message })
                    }
                    Ok(None) => {}
                    Err(e) => tracing::warn!(?e, id, "failed to mark snap expired"),
                }
            }
            if let Err(e) = sqlx::query("DELETE FROM sessions WHERE expires_at <= ?")
                .bind(now())
                .execute(&state.db)
                .await
            {
                tracing::warn!(?e, "session cleanup failed");
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(sender: i64, recipient: i64, len: usize, ttl: Duration) -> Snap {
        Snap {
            sender_id: sender,
            recipient_id: recipient,
            data: Bytes::from(vec![0u8; len]),
            expires_at: Instant::now() + ttl,
        }
    }

    #[test]
    fn view_once_and_recipient_only() {
        let store = SnapStore::new(1000, Duration::from_secs(60));
        assert!(store.put(1, snap(10, 20, 100, Duration::from_secs(60))));
        // Sender can't open it, and trying doesn't consume it.
        assert!(matches!(store.take(1, 10), Take::Missing));
        assert!(matches!(store.take(1, 20), Take::Found { .. }));
        assert!(matches!(store.take(1, 20), Take::Missing));
        assert_eq!(store.inner.lock().unwrap().total_bytes, 0);
    }

    #[test]
    fn pool_limit_and_expiry() {
        let store = SnapStore::new(150, Duration::from_secs(60));
        assert!(store.put(1, snap(1, 2, 100, Duration::ZERO)));
        assert!(!store.has_room(100));
        assert!(!store.put(2, snap(1, 2, 100, Duration::from_secs(60))));
        let swept = store.sweep();
        assert_eq!(swept, vec![(1, 1, 2)]);
        assert!(store.has_room(100));
    }

}
