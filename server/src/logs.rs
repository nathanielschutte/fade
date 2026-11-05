//! Recent log entries, kept in memory for the admin log viewer.
//!
//! Every `tracing` event that passes the buffer's filter is copied into a
//! fixed-size ring, newest last. A restart empties it; older history is in the
//! system journal (`journalctl -u fade`). Nothing logged anywhere may contain
//! message content, keys, tokens, or invite codes.

use std::{
    collections::VecDeque,
    fmt::Write as _,
    sync::{Arc, Mutex},
};

use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::{Deserialize, Serialize};
use tracing::{field::Field, Event, Level, Subscriber};
use tracing_subscriber::{layer::Context, Layer};

use crate::{
    auth::{self, AuthUser},
    error::{AppError, AppResult},
    version, SharedState,
};

pub const DEFAULT_CAPACITY: usize = 20_000;
const MAX_PAGE: usize = 500;
/// Memory the server's own entries may take, whatever they hold.
pub const SERVER_BYTES: usize = 32 * 1024 * 1024;
/// Memory the apps' entries may take. They have a ring of their own, so a
/// flood of them (`POST /api/logs` takes them signed out too) can never push
/// the server's entries out, and stays small.
pub const CLIENT_BYTES: usize = 4 * 1024 * 1024;
/// A logged message or field value longer than this is cut (at a character
/// boundary) before it's kept, so no one event can hold much memory.
pub const MAX_VALUE_BYTES: usize = 1024;

#[derive(Debug, Clone, Serialize)]
pub struct LogEntry {
    /// Increases by one per entry, so clients can page and tail.
    pub seq: u64,
    /// Unix milliseconds.
    pub ts: i64,
    pub level: &'static str,
    pub target: String,
    pub message: String,
    /// Structured fields, in the order they were logged.
    pub fields: Vec<(String, String)>,
}

impl LogEntry {
    /// About how much memory it holds.
    fn bytes(&self) -> usize {
        std::mem::size_of::<Self>()
            + self.target.len()
            + self.message.len()
            + self
                .fields
                .iter()
                .map(|(k, v)| std::mem::size_of::<(String, String)>() + k.len() + v.len())
                .sum::<usize>()
    }
}

/// Entries newest last, within a count and a memory budget: the oldest go first.
struct Ring {
    entries: VecDeque<LogEntry>,
    bytes: usize,
    max_entries: usize,
    max_bytes: usize,
}

impl Ring {
    fn new(max_entries: usize, max_bytes: usize) -> Self {
        Self {
            entries: VecDeque::with_capacity(max_entries.min(4096)),
            bytes: 0,
            max_entries,
            max_bytes,
        }
    }

    fn push(&mut self, entry: LogEntry) {
        let size = entry.bytes();
        while self.entries.len() >= self.max_entries
            || (!self.entries.is_empty() && self.bytes + size > self.max_bytes)
        {
            let Some(old) = self.entries.pop_front() else {
                break;
            };
            self.bytes -= old.bytes();
        }
        self.bytes += size;
        self.entries.push_back(entry);
    }
}

/// The server's entries and the apps' (`client::...`), kept apart.
struct Rings {
    server: Ring,
    client: Ring,
    next_seq: u64,
}

pub struct LogBuffer {
    rings: Mutex<Rings>,
    capacity: usize,
    started_ms: i64,
}

/// `s`, cut to at most `max` bytes at a character boundary, with "…" when cut.
pub fn truncate_bytes(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &s[..end])
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn level_rank(level: &str) -> u8 {
    match level {
        "ERROR" => 5,
        "WARN" => 4,
        "INFO" => 3,
        "DEBUG" => 2,
        _ => 1,
    }
}

#[derive(Debug, Default, Deserialize)]
pub struct LogQuery {
    /// Minimum level: error, warn, info, debug, trace.
    pub level: Option<String>,
    /// Case-insensitive text to find in the message, target, or fields.
    pub q: Option<String>,
    /// Older than this seq (paging back).
    pub before: Option<u64>,
    /// Newer than this seq (live tail).
    pub after: Option<u64>,
    pub limit: Option<usize>,
    /// "server" or "client"; anything else means both.
    pub source: Option<String>,
}

impl LogBuffer {
    pub fn new(capacity: usize) -> Self {
        Self::with_budgets(capacity, SERVER_BYTES, CLIENT_BYTES)
    }

    fn with_budgets(capacity: usize, server_bytes: usize, client_bytes: usize) -> Self {
        Self {
            rings: Mutex::new(Rings {
                server: Ring::new(capacity, server_bytes),
                client: Ring::new(capacity, client_bytes),
                next_seq: 1,
            }),
            capacity,
            started_ms: now_ms(),
        }
    }

    pub fn push(
        &self,
        level: &'static str,
        target: &str,
        message: String,
        fields: Vec<(String, String)>,
    ) {
        let mut entry = LogEntry {
            seq: 0,
            ts: now_ms(),
            level,
            target: truncate_bytes(target, 200),
            message: truncate_bytes(&message, MAX_VALUE_BYTES),
            fields: fields
                .into_iter()
                .map(|(k, v)| (truncate_bytes(&k, 100), truncate_bytes(&v, MAX_VALUE_BYTES)))
                .collect(),
        };
        let mut rings = self.rings.lock().unwrap();
        // Numbered under the lock, so each ring stays in order.
        entry.seq = rings.next_seq;
        rings.next_seq += 1;
        if entry.target.starts_with(CLIENT_TARGET) {
            rings.client.push(entry);
        } else {
            rings.server.push(entry);
        }
    }

    /// Matching entries, newest first.
    pub fn query(&self, q: &LogQuery) -> Vec<LogEntry> {
        let min = q
            .level
            .as_deref()
            .map(|l| level_rank(&l.to_uppercase()))
            .unwrap_or(0);
        let needle =
            q.q.as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_lowercase);
        let limit = q.limit.unwrap_or(200).clamp(1, MAX_PAGE);
        let rings = self.rings.lock().unwrap();
        // Both rings, newest first, merged by seq.
        let mut server = rings.server.entries.iter().rev().peekable();
        let mut client = rings.client.entries.iter().rev().peekable();
        std::iter::from_fn(|| match (server.peek(), client.peek()) {
            (Some(s), Some(c)) if s.seq > c.seq => server.next(),
            (_, Some(_)) => client.next(),
            (Some(_), None) => server.next(),
            (None, None) => None,
        })
        .filter(|e| q.before.is_none_or(|b| e.seq < b))
        .filter(|e| q.after.is_none_or(|a| e.seq > a))
        .filter(|e| level_rank(e.level) >= min)
        .filter(|e| match q.source.as_deref() {
            Some("server") => !e.target.starts_with(CLIENT_TARGET),
            Some("client") => e.target.starts_with(CLIENT_TARGET),
            _ => true,
        })
        .filter(|e| match &needle {
            None => true,
            Some(n) => {
                e.message.to_lowercase().contains(n)
                    || e.target.to_lowercase().contains(n)
                    || e.fields.iter().any(|(k, v)| {
                        // Matches "user_id", "7", or "user_id=7".
                        format!("{k}={v}").to_lowercase().contains(n)
                    })
            }
        })
        .take(limit)
        .cloned()
        .collect()
    }

    /// (entries held, oldest seq held, newest seq held)
    pub fn span(&self) -> (usize, u64, u64) {
        let rings = self.rings.lock().unwrap();
        let (s, c) = (&rings.server.entries, &rings.client.entries);
        let fronts = [s.front(), c.front()].into_iter().flatten().map(|e| e.seq);
        let backs = [s.back(), c.back()].into_iter().flatten().map(|e| e.seq);
        (
            s.len() + c.len(),
            fronts.min().unwrap_or(0),
            backs.max().unwrap_or(0),
        )
    }
}

/// Copies events into a LogBuffer. Add it to the subscriber with its own filter.
pub struct BufferLayer(pub Arc<LogBuffer>);

#[derive(Default)]
struct Collect {
    message: String,
    fields: Vec<(String, String)>,
}

impl tracing::field::Visit for Collect {
    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = value.to_string();
        } else {
            self.fields
                .push((field.name().to_string(), value.to_string()));
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let mut s = String::new();
        let _ = write!(s, "{value:?}");
        if field.name() == "message" {
            self.message = s;
        } else {
            self.fields.push((field.name().to_string(), s));
        }
    }
}

impl<S: Subscriber> Layer<S> for BufferLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let mut c = Collect::default();
        event.record(&mut c);
        let meta = event.metadata();
        let level = match *meta.level() {
            Level::ERROR => "ERROR",
            Level::WARN => "WARN",
            Level::INFO => "INFO",
            Level::DEBUG => "DEBUG",
            Level::TRACE => "TRACE",
        };
        self.0.push(level, meta.target(), c.message, c.fields);
    }
}

// ---------- client logs ----------
// Apps send their own diagnostics here so the admin viewer shows both sides.
// Clients must never send content (they hold the only plaintext); as a
// backstop, fields whose names look like content or secrets are redacted.

/// Client entries are stored with targets like `client::web` or `client::ios`.
pub const CLIENT_TARGET: &str = "client::";
const CLIENT_MAX_ENTRIES: usize = 50;
const CLIENT_MAX_FIELDS: usize = 20;
/// Bytes, not characters: a 4-byte character counts four times.
const CLIENT_MAX_MESSAGE: usize = 500;
const CLIENT_MAX_VALUE: usize = 300;
/// Fields the server adds itself, which a client can't send for it.
const SERVER_FIELDS: &[&str] = &["user_id", "client", "ip"];
/// Entries a signed-out app may send per address per minute (signed in, it's
/// per person: `client_log_limit`). Signed out, an app has little to say: a
/// failed sign-in, a page that broke.
pub const ANONYMOUS_PER_MINUTE: u32 = 60;
/// Field names containing any of these are redacted.
const REDACT: &[&str] = &[
    "text",
    "body",
    "plain",
    "caption",
    "password",
    "passphrase",
    "secret",
    "token",
    "key",
    "cipher",
    "invite",
];
/// Field names that are redacted only as a whole word (so `message_id` survives).
const REDACT_EXACT: &[&str] = &["message", "msg", "content"];

#[derive(Deserialize)]
pub struct ClientEntry {
    level: String,
    message: String,
    #[serde(default)]
    fields: serde_json::Map<String, serde_json::Value>,
}

#[derive(Deserialize)]
pub struct ClientBatch {
    entries: Vec<ClientEntry>,
}

fn truncate(s: &str, max: usize) -> String {
    truncate_bytes(s, max)
}

/// Bounded, redacted copies of whatever the client sent.
fn sanitize(entry: ClientEntry) -> (&'static str, String, Vec<(String, String)>) {
    let level = match entry.level.to_ascii_lowercase().as_str() {
        "error" => "ERROR",
        "warn" | "warning" => "WARN",
        "info" => "INFO",
        _ => "DEBUG",
    };
    let fields = entry
        .fields
        .into_iter()
        .filter(|(k, _)| {
            !k.is_empty()
                && k.len() <= 40
                && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                && !SERVER_FIELDS.contains(&k.to_ascii_lowercase().as_str())
        })
        .take(CLIENT_MAX_FIELDS)
        .map(|(k, v)| {
            let lower = k.to_ascii_lowercase();
            let value = if REDACT.iter().any(|r| lower.contains(r))
                || REDACT_EXACT.contains(&lower.as_str())
            {
                "[redacted]".to_string()
            } else {
                match v {
                    serde_json::Value::String(s) => truncate(&s, CLIENT_MAX_VALUE),
                    other => truncate(&other.to_string(), CLIENT_MAX_VALUE),
                }
            };
            (k, value)
        })
        .collect();
    (
        level,
        truncate(entry.message.trim(), CLIENT_MAX_MESSAGE),
        fields,
    )
}

/// `POST /api/logs`: diagnostics from apps. Signed-in or not (sign-in itself
/// can fail); signed-in entries carry the user id.
pub async fn ingest(
    State(state): State<SharedState>,
    axum::extract::Extension(who): axum::extract::Extension<crate::ratelimit::ClientInfo>,
    headers: HeaderMap,
    Json(batch): Json<ClientBatch>,
) -> AppResult<StatusCode> {
    if batch.entries.len() > CLIENT_MAX_ENTRIES {
        return Err(AppError::bad(format!(
            "Send at most {CLIENT_MAX_ENTRIES} log entries at a time."
        )));
    }
    let user = match auth::bearer_token(&headers) {
        Some(token) => auth::user_for_token(&state.db, token, state.config.session_days).await?,
        None => None,
    };
    let client = headers
        .get(version::CLIENT_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|s| truncate(s, 40))
        .unwrap_or_else(|| format!("web/{}", version::SERVER_VERSION));
    let platform: String = client
        .split('/')
        .next()
        .unwrap_or("web")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(12)
        .collect();
    let key = user
        .as_ref()
        .map_or_else(|| format!("ip:{}", who.ip), |u| u.id.to_string());
    let wanted = batch.entries.len() as u32;
    let granted = match &user {
        Some(_) => state.client_log_limit.take(&key, wanted),
        // Local, un-proxied requests (development, tests) aren't limited by address.
        None if who.local => wanted,
        None => state.client_log_anon_limit.take(&key, wanted),
    } as usize;
    let dropped = batch.entries.len() - granted;
    for entry in batch.entries.into_iter().take(granted) {
        let (level, message, mut fields) = sanitize(entry);
        if let Some(u) = &user {
            fields.insert(0, ("user_id".into(), u.id.to_string()));
        }
        fields.push(("client".into(), client.clone()));
        fields.push(("ip".into(), who.ip.clone()));
        // Problems also go to the journal (target `napsack_client`, outside the
        // viewer's filter): they outlive restarts, and can be read over SSH.
        if matches!(level, "WARN" | "ERROR") {
            let detail = fields
                .iter()
                .map(|(k, v)| format!("{k}={v:?}"))
                .collect::<Vec<_>>()
                .join(" ");
            if level == "ERROR" {
                tracing::error!(target: "napsack_client", platform = %platform, message = ?message, detail = ?detail, "client reported");
            } else {
                tracing::warn!(target: "napsack_client", platform = %platform, message = ?message, detail = ?detail, "client reported");
            }
        }
        state.logs.push(
            level,
            &format!("{CLIENT_TARGET}{platform}"),
            message,
            fields,
        );
    }
    if dropped > 0 {
        tracing::warn!(key, dropped, "client logs rate limited");
    }
    Ok(StatusCode::NO_CONTENT)
}

/// `GET /api/admin/logs`: admin-only, newest first.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Query(q): Query<LogQuery>,
) -> AppResult<Json<serde_json::Value>> {
    // Admins only (roles.md); anyone else gets 404.
    crate::roles::require(&state, &me, crate::roles::Role::Admin).await?;
    let entries = state.logs.query(&q);
    let (held, oldest, newest) = state.logs.span();
    Ok(Json(serde_json::json!({
        "entries": entries,
        "held": held,
        "capacity": state.logs.capacity,
        "oldest_seq": oldest,
        "newest_seq": newest,
        "since_ms": state.logs.started_ms,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::prelude::*;

    fn filled(n: usize, cap: usize) -> LogBuffer {
        let b = LogBuffer::new(cap);
        for i in 0..n {
            let level = ["DEBUG", "INFO", "WARN", "ERROR"][i % 4];
            b.push(
                level,
                "fade_server::test",
                format!("event {i}"),
                vec![("user_id".into(), (i % 3).to_string())],
            );
        }
        b
    }

    #[test]
    fn keeps_the_newest_up_to_capacity() {
        let b = filled(10, 4);
        let all = b.query(&LogQuery::default());
        assert_eq!(
            all.iter().map(|e| e.seq).collect::<Vec<_>>(),
            vec![10, 9, 8, 7]
        );
        assert_eq!(b.span(), (4, 7, 10));
    }

    #[test]
    fn filters_by_level_text_and_seq() {
        let b = filled(20, 100);
        let warn_up = b.query(&LogQuery {
            level: Some("warn".into()),
            ..Default::default()
        });
        assert!(warn_up
            .iter()
            .all(|e| e.level == "WARN" || e.level == "ERROR"));
        assert_eq!(warn_up.len(), 10);

        let text = b.query(&LogQuery {
            q: Some("EVENT 1".into()),
            ..Default::default()
        });
        assert_eq!(text.len(), 11); // event 1, 10..19
        let pair = b.query(&LogQuery {
            q: Some("user_id=2".into()),
            ..Default::default()
        });
        assert!(!pair.is_empty() && pair.iter().all(|e| e.fields[0].1 == "2"));
        let field = b.query(&LogQuery {
            q: Some("user_id".into()),
            limit: Some(3),
            ..Default::default()
        });
        assert_eq!(field.len(), 3);

        let page = b.query(&LogQuery {
            before: Some(5),
            ..Default::default()
        });
        assert_eq!(page.first().map(|e| e.seq), Some(4));
        let tail = b.query(&LogQuery {
            after: Some(18),
            ..Default::default()
        });
        assert_eq!(tail.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![20, 19]);
    }

    fn entry(level: &str, message: &str, fields: serde_json::Value) -> ClientEntry {
        ClientEntry {
            level: level.into(),
            message: message.into(),
            fields: fields.as_object().unwrap().clone(),
        }
    }

    #[test]
    fn client_entries_are_bounded_and_redacted() {
        let (level, message, fields) = sanitize(entry(
            "Warning",
            &"x".repeat(900),
            serde_json::json!({
                "message_id": 5, "message": "hi there", "status": 404, "text": "hello there", "auth_key": "abc",
                "Plaintext": "x", "invite_code": "letmein", "error": "Request failed (500).",
                "bad key!": "dropped", "long": "y".repeat(400)
            }),
        ));
        assert_eq!(level, "WARN");
        assert_eq!(message.len(), CLIENT_MAX_MESSAGE + "…".len());
        let get = |k: &str| fields.iter().find(|(f, _)| f == k).map(|(_, v)| v.as_str());
        assert_eq!(get("message_id"), Some("5"));
        assert_eq!(get("message"), Some("[redacted]"));
        assert_eq!(get("status"), Some("404"));
        assert_eq!(get("text"), Some("[redacted]"));
        assert_eq!(get("auth_key"), Some("[redacted]"));
        assert_eq!(get("Plaintext"), Some("[redacted]"));
        assert_eq!(get("invite_code"), Some("[redacted]"));
        assert_eq!(get("error"), Some("Request failed (500)."));
        assert_eq!(get("bad key!"), None);
        assert_eq!(
            get("long").map(str::len),
            Some(CLIENT_MAX_VALUE + "…".len())
        );
        assert_eq!(
            sanitize(entry("shout", "m", serde_json::json!({}))).0,
            "DEBUG"
        );
    }

    /// Limits are bytes, so 4-byte characters keep a quarter as many, and a
    /// cut never splits one. The server's own fields can't be sent.
    #[test]
    fn client_entries_are_bounded_in_bytes() {
        let emoji = "\u{1F600}";
        let fields: serde_json::Map<String, serde_json::Value> = (0..20)
            .map(|i| {
                (
                    format!("f{i}"),
                    serde_json::Value::String(emoji.repeat(300)),
                )
            })
            .chain([
                ("ip".to_string(), "1.2.3.4".into()),
                ("User_Id".to_string(), "1".into()),
            ])
            .collect();
        let (_, message, fields) = sanitize(ClientEntry {
            level: "debug".into(),
            message: emoji.repeat(500),
            fields,
        });
        assert!(message.len() <= CLIENT_MAX_MESSAGE + 3 && message.ends_with('…'));
        assert!(message
            .trim_end_matches('…')
            .chars()
            .all(|c| c == '\u{1F600}'));
        assert_eq!(fields.len(), 20, "ip and user_id are the server's to add");
        assert!(fields.iter().all(|(_, v)| v.len() <= CLIENT_MAX_VALUE + 3));
        let held: usize =
            message.len() + fields.iter().map(|(k, v)| k.len() + v.len()).sum::<usize>();
        assert!(held < 7 * 1024, "{held} bytes, from about 38 KB sent");
        assert_eq!(truncate_bytes("héllo", 2), "h…", "never half a character");
    }

    /// Apps' entries have a budget of their own: however many arrive, they
    /// never push the server's out, and the memory they hold stays bounded.
    #[test]
    fn client_entries_cant_push_server_entries_out() {
        let b = LogBuffer::with_budgets(1000, 1 << 20, 64 * 1024);
        b.push("INFO", "fade_server::auth", "signed in".into(), vec![]);
        for i in 0..5000 {
            b.push(
                "DEBUG",
                "client::web",
                format!("noise {i}"),
                vec![("f".into(), "x".repeat(300))],
            );
        }
        let rings = b.rings.lock().unwrap();
        assert_eq!(rings.server.entries.len(), 1, "the server's entry stays");
        assert!(rings.client.bytes <= 64 * 1024 && rings.client.entries.len() < 200);
        assert_eq!(rings.client.entries.back().unwrap().message, "noise 4999");
        drop(rings);
        let all = b.query(&LogQuery {
            limit: Some(500),
            ..Default::default()
        });
        assert_eq!(
            all.last().unwrap().message,
            "signed in",
            "merged in order, oldest last"
        );
        assert!(all.windows(2).all(|w| w[0].seq > w[1].seq));
        let (held, oldest, newest) = b.span();
        assert_eq!((oldest, newest), (1, 5001));
        assert!(held < 200);
    }

    #[test]
    fn long_server_values_are_cut() {
        let b = LogBuffer::new(10);
        b.push(
            "INFO",
            "fade_server::x",
            "m".repeat(5000),
            vec![("username".into(), "y".repeat(2_000_000))],
        );
        let e = &b.query(&LogQuery::default())[0];
        assert!(e.message.len() <= MAX_VALUE_BYTES + 3);
        assert!(e.fields[0].1.len() <= MAX_VALUE_BYTES + 3);
    }

    #[test]
    fn source_filter_splits_server_and_client() {
        let b = LogBuffer::new(10);
        b.push("INFO", "fade_server::auth", "signed in".into(), vec![]);
        b.push("WARN", "client::web", "send failed".into(), vec![]);
        let only = |s: &str| {
            b.query(&LogQuery {
                source: Some(s.into()),
                ..Default::default()
            })
            .into_iter()
            .map(|e| e.message)
            .collect::<Vec<_>>()
        };
        assert_eq!(only("client"), vec!["send failed"]);
        assert_eq!(only("server"), vec!["signed in"]);
        assert_eq!(only("all").len(), 2);
    }

    #[test]
    fn layer_captures_message_and_fields() {
        let buffer = Arc::new(LogBuffer::new(10));
        let subscriber = tracing_subscriber::registry().with(BufferLayer(buffer.clone()));
        tracing::subscriber::with_default(subscriber, || {
            tracing::info!(user_id = 7, kind = "text", "message sent");
            tracing::warn!(path = %"/api/me", "slow request");
        });
        let e = buffer.query(&LogQuery::default());
        assert_eq!(e.len(), 2);
        assert_eq!(
            (e[1].level, e[1].message.as_str()),
            ("INFO", "message sent")
        );
        assert_eq!(
            e[1].fields,
            vec![
                ("user_id".into(), "7".into()),
                ("kind".into(), "text".into())
            ]
        );
        assert_eq!(e[0].fields, vec![("path".into(), "/api/me".into())]);
    }
}
