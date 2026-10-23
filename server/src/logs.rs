//! Recent log entries, kept in memory for the admin log viewer.
//!
//! Every `tracing` event that passes the buffer's filter is copied into a
//! fixed-size ring, newest last. A restart empties it; older history is in the
//! system journal (`journalctl -u fade`). Nothing logged anywhere may contain
//! message content, keys, tokens, or invite codes.

use std::{
    collections::VecDeque,
    fmt::Write as _,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
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

pub struct LogBuffer {
    entries: Mutex<VecDeque<LogEntry>>,
    capacity: usize,
    next_seq: AtomicU64,
    started_ms: i64,
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
        Self {
            entries: Mutex::new(VecDeque::with_capacity(capacity.min(4096))),
            capacity,
            next_seq: AtomicU64::new(1),
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
        let entry = LogEntry {
            seq: self.next_seq.fetch_add(1, Ordering::Relaxed),
            ts: now_ms(),
            level,
            target: target.to_string(),
            message,
            fields,
        };
        let mut entries = self.entries.lock().unwrap();
        if entries.len() == self.capacity {
            entries.pop_front();
        }
        entries.push_back(entry);
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
        let entries = self.entries.lock().unwrap();
        entries
            .iter()
            .rev()
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
        let entries = self.entries.lock().unwrap();
        (
            entries.len(),
            entries.front().map_or(0, |e| e.seq),
            entries.back().map_or(0, |e| e.seq),
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
const CLIENT_MAX_MESSAGE: usize = 500;
const CLIENT_MAX_VALUE: usize = 300;
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
    if s.chars().count() <= max {
        s.to_string()
    } else {
        format!("{}…", s.chars().take(max).collect::<String>())
    }
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
        Some(token) => auth::user_for_token(&state.db, token).await?,
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
    let granted = state
        .client_log_limit
        .take(&key, batch.entries.len() as u32) as usize;
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
                tracing::error!(target: "napsack_client", platform = %platform, message = ?message, detail = %detail, "client reported");
            } else {
                tracing::warn!(target: "napsack_client", platform = %platform, message = ?message, detail = %detail, "client reported");
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
        assert_eq!(message.chars().count(), CLIENT_MAX_MESSAGE + 1);
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
            get("long").map(|v| v.chars().count()),
            Some(CLIENT_MAX_VALUE + 1)
        );
        assert_eq!(
            sanitize(entry("shout", "m", serde_json::json!({}))).0,
            "DEBUG"
        );
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
