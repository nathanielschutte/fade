use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
    time::Duration,
};

use axum::{
    extract::{
        ws::{Message as WsMessage, WebSocket, WebSocketUpgrade},
        State,
    },
    response::Response,
};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::{
    auth,
    db::{Message, UserPublic},
    SharedState,
};

/// Everything the server pushes to clients. Serialized as `{"type": "...", ...}`.
#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// A new text or snap in a chat you're part of.
    Message { message: Message },
    /// A snap was opened or expired.
    MessageUpdated { message: Message },
    /// `by` read the texts in their chat with the receiver, up to `at`.
    Read { by: i64, at: i64 },
    /// Requests or friendships changed; refetch lists.
    FriendsChanged,
    /// A new message (or membership event) in a group you're in.
    GroupMessage {
        group_id: i64,
        message: crate::groups::GroupMessage,
    },
    /// A group's name, members, or your read position changed; refetch it.
    GroupsChanged { group_id: i64 },
}

type Conn = (u64, mpsc::UnboundedSender<String>);

/// Tracks open sockets per user. A user can have several (phone + laptop + tabs).
#[derive(Default)]
pub struct Hub {
    conns: Mutex<HashMap<i64, Vec<Conn>>>,
    next_id: AtomicU64,
}

impl Hub {
    fn register(&self, user_id: i64) -> (u64, mpsc::UnboundedReceiver<String>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.conns
            .lock()
            .unwrap()
            .entry(user_id)
            .or_default()
            .push((id, tx));
        (id, rx)
    }

    fn unregister(&self, user_id: i64, conn_id: u64) {
        let mut conns = self.conns.lock().unwrap();
        if let Some(list) = conns.get_mut(&user_id) {
            list.retain(|(id, _)| *id != conn_id);
            if list.is_empty() {
                conns.remove(&user_id);
            }
        }
    }

    pub fn send(&self, user_id: i64, event: &Event) {
        let Ok(text) = serde_json::to_string(event) else {
            return;
        };
        let mut conns = self.conns.lock().unwrap();
        if let Some(list) = conns.get_mut(&user_id) {
            list.retain(|(_, tx)| tx.send(text.clone()).is_ok());
        }
    }

    /// (users with at least one open socket, total open sockets)
    pub fn online(&self) -> (usize, usize) {
        let conns = self.conns.lock().unwrap();
        (conns.len(), conns.values().map(Vec::len).sum())
    }

    /// Sends to each user once, however many times they appear.
    pub fn send_many(&self, users: &[i64], event: &Event) {
        let mut seen = std::collections::HashSet::new();
        for &u in users {
            if seen.insert(u) {
                self.send(u, event);
            }
        }
    }

    pub fn send_both(&self, a: i64, b: i64, event: &Event) {
        self.send(a, event);
        if a != b {
            self.send(b, event);
        }
    }
}

#[derive(Deserialize)]
struct AuthFrame {
    #[serde(rename = "type")]
    kind: String,
    token: String,
}

/// Browsers can't set headers on a WebSocket, so the client sends
/// `{"type":"auth","token":"..."}` as its first frame instead.
/// This keeps tokens out of URLs (and therefore out of proxy logs).
pub async fn handler(
    State(state): State<SharedState>,
    axum::extract::Extension(who): axum::extract::Extension<crate::ratelimit::ClientInfo>,
    ws: WebSocketUpgrade,
) -> Response {
    ws.max_message_size(16 * 1024)
        .on_upgrade(move |socket| run(socket, state, who.ip))
}

async fn authenticate(socket: &mut WebSocket, state: &SharedState) -> Option<UserPublic> {
    while let Some(Ok(msg)) = socket.recv().await {
        match msg {
            WsMessage::Text(text) => {
                let frame: AuthFrame = serde_json::from_str(text.as_str()).ok()?;
                if frame.kind != "auth" {
                    return None;
                }
                return auth::user_for_token(&state.db, &frame.token).await.ok()?;
            }
            WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
            _ => return None,
        }
    }
    None
}

async fn run(mut socket: WebSocket, state: SharedState, ip: String) {
    let user = match tokio::time::timeout(
        Duration::from_secs(10),
        authenticate(&mut socket, &state),
    )
    .await
    {
        Ok(Some(user)) => user,
        outcome => {
            let reason = if outcome.is_err() {
                "timed out"
            } else {
                "bad or missing token"
            };
            tracing::info!(%ip, reason, "socket auth failed");
            let _ = socket
                .send(WsMessage::Text(r#"{"type":"auth_failed"}"#.into()))
                .await;
            let _ = socket.send(WsMessage::Close(None)).await;
            return;
        }
    };

    let ready = serde_json::json!({ "type": "ready", "user": user }).to_string();
    if socket.send(WsMessage::Text(ready.into())).await.is_err() {
        return;
    }

    let (conn_id, mut rx) = state.hub.register(user.id);
    let connected = std::time::Instant::now();
    tracing::debug!(
        user_id = user.id,
        %ip,
        conn_id,
        online = state.hub.online().0,
        "socket connected"
    );
    // Keeps idle connections alive through NATs and mobile networks.
    let mut ping = tokio::time::interval(Duration::from_secs(25));
    ping.tick().await;

    loop {
        tokio::select! {
            incoming = socket.recv() => match incoming {
                Some(Ok(WsMessage::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {} // clients don't send anything after auth yet
            },
            outgoing = rx.recv() => match outgoing {
                Some(text) => {
                    if socket.send(WsMessage::Text(text.into())).await.is_err() {
                        break;
                    }
                }
                None => break,
            },
            _ = ping.tick() => {
                if socket.send(WsMessage::Ping(Bytes::new())).await.is_err() {
                    break;
                }
            }
        }
    }

    state.hub.unregister(user.id, conn_id);
    tracing::debug!(
        user_id = user.id,
        conn_id,
        secs = connected.elapsed().as_secs(),
        "socket closed"
    );
}
