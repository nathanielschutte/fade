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
    response::{IntoResponse, Response},
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
    /// A friend (or, with `group_id`, a group member) is typing. Never stored.
    Typing { from: i64, group_id: Option<i64> },
    /// A friend opened napsack (`active`) or closed it, at `last_seen_at`.
    Presence {
        user_id: i64,
        active: bool,
        last_seen_at: i64,
    },
}

struct Conn {
    id: u64,
    /// Hash of the session token that opened it, so ending a session closes it.
    session: String,
    /// The client says napsack is on screen. While any of a person's sockets
    /// is visible, they see new things in the app, so no push notification.
    visible: bool,
    tx: mpsc::UnboundedSender<String>,
}

/// Tracks open sockets per user. A user can have several (phone + laptop + tabs).
#[derive(Default)]
pub struct Hub {
    conns: Mutex<HashMap<i64, Vec<Conn>>>,
    next_id: AtomicU64,
}

/// Live connections one account may hold. Past this, the oldest is closed
/// (dropping its sender ends its loop), so a stolen or buggy client can't pile
/// up sockets, while a person opening one more tab still just works.
pub const MAX_CONNS_PER_USER: usize = 10;

impl Hub {
    /// Returns the connection id, its receiver, and whether this is the
    /// person's first open socket (they just came online).
    fn register(
        &self,
        user_id: i64,
        session: String,
    ) -> (u64, mpsc::UnboundedReceiver<String>, bool) {
        let (tx, rx) = mpsc::unbounded_channel();
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut conns = self.conns.lock().unwrap();
        let list = conns.entry(user_id).or_default();
        let first = list.is_empty();
        while list.len() >= MAX_CONNS_PER_USER {
            list.remove(0);
        }
        list.push(Conn {
            id,
            session,
            visible: false,
            tx,
        });
        (id, rx, first)
    }

    fn set_visible(&self, user_id: i64, conn_id: u64, visible: bool) {
        let mut conns = self.conns.lock().unwrap();
        if let Some(c) = conns
            .get_mut(&user_id)
            .and_then(|list| list.iter_mut().find(|c| c.id == conn_id))
        {
            c.visible = visible;
        }
    }

    /// napsack is on screen somewhere for this person.
    pub fn is_visible(&self, user_id: i64) -> bool {
        let conns = self.conns.lock().unwrap();
        conns
            .get(&user_id)
            .is_some_and(|list| list.iter().any(|c| c.visible && !c.tx.is_closed()))
    }

    pub fn is_online(&self, user_id: i64) -> bool {
        self.conns.lock().unwrap().contains_key(&user_id)
    }

    /// Closes the sockets opened by one session (`session` is the token hash).
    pub fn end_session(&self, user_id: i64, session: &str) {
        let mut conns = self.conns.lock().unwrap();
        if let Some(list) = conns.get_mut(&user_id) {
            list.retain(|c| c.session != session);
            if list.is_empty() {
                conns.remove(&user_id);
            }
        }
    }

    /// Closes the user's sockets, except those opened by session `keep`
    /// (a token hash). Their loops end, and the clients find themselves signed out.
    pub fn end_sessions(&self, user_id: i64, keep: Option<&str>) {
        let mut conns = self.conns.lock().unwrap();
        if let Some(list) = conns.get_mut(&user_id) {
            list.retain(|c| Some(c.session.as_str()) == keep);
            if list.is_empty() {
                conns.remove(&user_id);
            }
        }
    }

    /// Returns whether that was the person's last socket (they went offline).
    fn unregister(&self, user_id: i64, conn_id: u64) -> bool {
        let mut conns = self.conns.lock().unwrap();
        if let Some(list) = conns.get_mut(&user_id) {
            list.retain(|c| c.id != conn_id);
            if list.is_empty() {
                conns.remove(&user_id);
                return true;
            }
        }
        false
    }

    pub fn send(&self, user_id: i64, event: &Event) {
        let Ok(text) = serde_json::to_string(event) else {
            return;
        };
        let mut conns = self.conns.lock().unwrap();
        if let Some(list) = conns.get_mut(&user_id) {
            list.retain(|c| c.tx.send(text.clone()).is_ok());
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

/// What clients send after signing in.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientFrame {
    /// The page is on screen, or not (`document.visibilityState`).
    Visibility { visible: bool },
    /// "I'm typing" to a friend (`to`) or a group (`group`).
    Typing { to: Option<i64>, group: Option<i64> },
}

/// Typing is a hint; one relay per socket every so often is plenty.
const TYPING_EVERY: Duration = Duration::from_millis(1500);

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
    // A ceiling on live sockets for the whole server (guard.rs).
    if state.hub.online().1 >= state.config.limits.max_sockets {
        tracing::warn!(ip = %who.ip, "socket refused: server at its connection ceiling");
        return crate::error::AppError::Unavailable(
            "napsack is busy. Try again in a moment.".into(),
        )
        .into_response();
    }
    ws.max_message_size(16 * 1024)
        .on_upgrade(move |socket| run(socket, state, who.ip))
}

async fn authenticate(socket: &mut WebSocket, state: &SharedState) -> Option<(UserPublic, String)> {
    while let Some(Ok(msg)) = socket.recv().await {
        match msg {
            WsMessage::Text(text) => {
                let frame: AuthFrame = serde_json::from_str(text.as_str()).ok()?;
                if frame.kind != "auth" {
                    return None;
                }
                let user = auth::user_for_token(&state.db, &frame.token).await.ok()??;
                return Some((user, auth::hash_token(&frame.token)));
            }
            WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
            _ => return None,
        }
    }
    None
}

async fn run(mut socket: WebSocket, state: SharedState, ip: String) {
    let (user, session) = match tokio::time::timeout(
        Duration::from_secs(10),
        authenticate(&mut socket, &state),
    )
    .await
    {
        Ok(Some(found)) => found,
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

    let (conn_id, mut rx, first) = state.hub.register(user.id, session);
    if first {
        crate::presence::announce(&state, user.id, true).await;
    }
    let mut last_typing: Option<std::time::Instant> = None;
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
                Some(Ok(WsMessage::Text(text))) => match serde_json::from_str::<ClientFrame>(text.as_str()) {
                    Ok(ClientFrame::Visibility { visible }) => state.hub.set_visible(user.id, conn_id, visible),
                    Ok(ClientFrame::Typing { to, group }) => {
                        if last_typing.is_none_or(|t| t.elapsed() >= TYPING_EVERY) {
                            last_typing = Some(std::time::Instant::now());
                            crate::presence::typing(&state, user.id, to, group).await;
                        }
                    }
                    Err(_) => tracing::debug!(user_id = user.id, conn_id, "unknown socket frame ignored"),
                },
                Some(Ok(_)) => {}
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

    if state.hub.unregister(user.id, conn_id) {
        crate::presence::announce(&state, user.id, false).await;
    }
    tracing::debug!(
        user_id = user.id,
        conn_id,
        secs = connected.elapsed().as_secs(),
        "socket closed"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connections_per_user_are_capped_oldest_first() {
        let hub = Hub::default();
        let mut receivers: Vec<_> = (0..MAX_CONNS_PER_USER + 2)
            .map(|_| hub.register(7, "s".into()).1)
            .collect();
        assert_eq!(hub.online(), (1, MAX_CONNS_PER_USER));
        // The two oldest were closed; the newest are live.
        assert!(receivers[0].try_recv().is_err() && receivers[0].is_closed());
        assert!(receivers[1].is_closed());
        assert!(!receivers.last().unwrap().is_closed());
        hub.register(8, "s".into());
        assert_eq!(hub.online(), (2, MAX_CONNS_PER_USER + 1));
    }

    #[test]
    fn ending_sessions_closes_their_sockets_only() {
        let hub = Hub::default();
        let (_, kept, _) = hub.register(7, "mine".into());
        let (_, other, _) = hub.register(7, "stolen".into());
        let (_, someone, _) = hub.register(8, "theirs".into());
        hub.end_sessions(7, Some("mine"));
        assert!(!kept.is_closed() && other.is_closed() && !someone.is_closed());
        hub.end_sessions(7, None);
        assert!(kept.is_closed());
        assert_eq!(hub.online(), (1, 1));
    }

    #[test]
    fn online_and_visible_follow_the_sockets() {
        let hub = Hub::default();
        let (a, _ra, first) = hub.register(7, "s".into());
        assert!(
            first && hub.is_online(7) && !hub.is_visible(7),
            "a new socket isn't on screen yet"
        );
        let (b, _rb, first) = hub.register(7, "s".into());
        assert!(!first);
        hub.set_visible(7, b, true);
        assert!(hub.is_visible(7));
        hub.set_visible(7, b, false);
        assert!(!hub.is_visible(7));
        assert!(!hub.unregister(7, a), "one socket still open");
        assert!(hub.unregister(7, b), "that was the last");
        assert!(!hub.is_online(7));
    }
}
