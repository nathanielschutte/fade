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
        message: Box<crate::groups::GroupMessage>,
    },
    /// A group's name, members, or your read position changed; refetch it.
    GroupsChanged { group_id: i64 },
    /// Another member read the group up to `last_read_id` ("Seen by").
    GroupRead {
        group_id: i64,
        user_id: i64,
        last_read_id: i64,
    },
    /// A friend (or, with `group_id`, a group member) is typing. Never stored.
    Typing { from: i64, group_id: Option<i64> },
    /// A friend opened napsack (`active`) or closed it, at `last_seen_at`.
    Presence {
        user_id: i64,
        active: bool,
        last_seen_at: i64,
    },
    /// The Admins' announcement changed: the current one, or none (announcements.rs).
    Announcement {
        announcement: Option<crate::announcements::Announcement>,
    },
}

struct Conn {
    id: u64,
    /// Hash of the session token that opened it, so ending a session closes it.
    session: String,
    /// The client says napsack is on screen. While any of a person's sockets
    /// is visible, they see new things in the app, so no push notification.
    visible: bool,
    tx: mpsc::Sender<String>,
}

/// Events waiting to go out on one socket. A client that reads normally keeps
/// this near empty (events come a few at a time: a message, its read, some
/// typing); one that stops reading while the server keeps sending would
/// otherwise grow it without end. Full means it isn't keeping up: the socket
/// is dropped, and the client's reconnect fetches what it missed, as after
/// any dropped connection. 256 covers a burst far bigger than real use (an
/// announcement to everyone, a group of 32 all sending) at a few hundred KB
/// at most per socket.
pub const QUEUE: usize = 256;

/// Frames a client may send per `FRAMES_EVERY`, pings included. Real clients
/// send a ping every 25 seconds, visibility changes, and typing at most
/// every 1.5 seconds: a few per window. Past this the socket is closed, so a
/// client can't keep the server answering pings or parsing frames flat out.
pub const MAX_FRAMES: u32 = 60;
pub const FRAMES_EVERY: Duration = Duration::from_secs(10);

/// A send that can't finish in this long (the client stopped reading, and
/// the network buffers are full) ends the socket.
const SEND_WITHIN: Duration = Duration::from_secs(20);

/// Counts one socket's incoming frames in fixed windows.
struct FrameBudget {
    window: std::time::Instant,
    used: u32,
}

impl FrameBudget {
    fn new(now: std::time::Instant) -> Self {
        Self {
            window: now,
            used: 0,
        }
    }

    /// Whether one more frame, at `now`, is within the budget.
    fn allow(&mut self, now: std::time::Instant) -> bool {
        if now.duration_since(self.window) >= FRAMES_EVERY {
            *self = Self::new(now);
        }
        self.used += 1;
        self.used <= MAX_FRAMES
    }
}

/// Queues `text` for each socket in `list`, dropping any whose queue is full
/// (or whose loop has ended).
fn queue_for(user_id: i64, list: &mut Vec<Conn>, text: &str) {
    list.retain(|c| match c.tx.try_send(text.to_owned()) {
        Ok(()) => true,
        Err(mpsc::error::TrySendError::Full(_)) => {
            tracing::warn!(
                user_id,
                conn_id = c.id,
                "socket dropped: not keeping up with its events"
            );
            false
        }
        Err(mpsc::error::TrySendError::Closed(_)) => false,
    });
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
    fn register(&self, user_id: i64, session: String) -> (u64, mpsc::Receiver<String>, bool) {
        let (tx, rx) = mpsc::channel(QUEUE);
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
            queue_for(user_id, list, &text);
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

    /// Sends to everyone connected (announcements).
    pub fn send_all(&self, event: &Event) {
        let Ok(text) = serde_json::to_string(event) else {
            return;
        };
        let mut conns = self.conns.lock().unwrap();
        for (user_id, list) in conns.iter_mut() {
            queue_for(*user_id, list, &text);
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
    /// The app checking the connection is really alive (browsers can't see
    /// protocol pings); answered at once with `{"type":"pong"}`.
    Ping,
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
                let user = auth::user_for_token(&state.db, &frame.token, state.config.session_days)
                    .await
                    .ok()??;
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

    let mut client_closed = false;
    let mut budget = FrameBudget::new(std::time::Instant::now());
    loop {
        tokio::select! {
            incoming = socket.recv() => match incoming {
                Some(Ok(WsMessage::Close(_))) => {
                    client_closed = true;
                    break;
                }
                Some(Err(_)) | None => break,
                Some(Ok(_)) if !budget.allow(std::time::Instant::now()) => {
                    tracing::warn!(user_id = user.id, conn_id, "socket closed: too many frames");
                    break;
                }
                Some(Ok(WsMessage::Text(text))) => match serde_json::from_str::<ClientFrame>(text.as_str()) {
                    Ok(ClientFrame::Visibility { visible }) => state.hub.set_visible(user.id, conn_id, visible),
                    Ok(ClientFrame::Typing { to, group }) => {
                        if last_typing.is_none_or(|t| t.elapsed() >= TYPING_EVERY) {
                            last_typing = Some(std::time::Instant::now());
                            crate::presence::typing(&state, user.id, to, group).await;
                        }
                    }
                    Ok(ClientFrame::Ping) => {
                        if !send_within(&mut socket, WsMessage::Text(r#"{"type":"pong"}"#.into())).await {
                            break;
                        }
                    }
                    Err(_) => tracing::debug!(user_id = user.id, conn_id, "unknown socket frame ignored"),
                },
                Some(Ok(_)) => {}
            },
            outgoing = rx.recv() => match outgoing {
                Some(text) => {
                    if !send_within(&mut socket, WsMessage::Text(text.into())).await {
                        break;
                    }
                }
                None => break,
            },
            _ = ping.tick() => {
                if !send_within(&mut socket, WsMessage::Ping(Bytes::new())).await {
                    break;
                }
            }
        }
    }
    // Answer the client's close: reading the close frame only queues the reply,
    // and one more read sends it (then ends at once). Without it the client sees
    // an abnormal closure (1006) instead of a clean one.
    if client_closed {
        let _ = tokio::time::timeout(Duration::from_secs(1), socket.recv()).await;
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

/// Sends, or gives up after `SEND_WITHIN`. False means the socket is done.
async fn send_within(socket: &mut WebSocket, msg: WsMessage) -> bool {
    matches!(
        tokio::time::timeout(SEND_WITHIN, socket.send(msg)).await,
        Ok(Ok(()))
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A socket whose client stops reading is dropped once its queue fills,
    /// rather than holding events without end; the others carry on.
    #[test]
    fn a_socket_that_stops_reading_is_dropped() {
        let hub = Hub::default();
        let (_, mut reading, _) = hub.register(7, "a".into());
        let (_, stuck, _) = hub.register(7, "b".into());
        for _ in 0..QUEUE {
            hub.send(7, &Event::FriendsChanged);
            assert!(reading.try_recv().is_ok());
        }
        assert!(!stuck.is_closed(), "full, but not past it");
        hub.send(7, &Event::FriendsChanged);
        assert!(stuck.is_closed(), "one past full: dropped");
        assert!(!reading.is_closed() && reading.try_recv().is_ok());
        assert_eq!(hub.online(), (1, 1));
    }

    #[test]
    fn incoming_frames_are_capped_per_window() {
        let start = std::time::Instant::now();
        let mut budget = FrameBudget::new(start);
        assert!((0..MAX_FRAMES).all(|_| budget.allow(start)));
        assert!(!budget.allow(start), "one past the cap");
        assert!(
            budget.allow(start + FRAMES_EVERY),
            "a new window starts fresh"
        );
    }

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
