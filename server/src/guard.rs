//! Protection against abuse at our size: one small server (t4g.nano, 0.5 GB
//! RAM, a 1 GB data disk) for a few dozen friends. Everything here is far
//! above what people use, so it's invisible to them; it's there for scripts,
//! scanners, and anyone trying to knock napsack over. See docs/security.md.
//!
//! - Bots: `robots.txt` says no, every response says `noindex`, known
//!   scanning tools are refused outright, and an address that probes for
//!   things napsack doesn't have (`/.env`, `/wp-login.php`, ...) is banned for
//!   an hour.
//! - Floods: a request budget per address, writes per session, a ceiling on
//!   requests in flight at once, and on live sockets.
//! - Hard caps: accounts in total, sessions per person, friend requests and
//!   new groups per day.
//! - Disk: uploads stop well before the data disk fills, and every write stops
//!   before the database could run out of room.
//!
//! Local, un-proxied requests (development, tests) skip the per-address rules.

use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};

use axum::{
    extract::{Request, State},
    http::{header, HeaderValue, Method, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use tokio::sync::Semaphore;

use crate::{error::AppError, ratelimit::ClientInfo, SharedState};

/// Limits, from `FADE_*` settings (main.rs) with these defaults.
#[derive(Debug, Clone)]
pub struct Limits {
    /// Accounts that can exist in total. Sign-up stops at this many.
    pub max_accounts: i64,
    /// Signed-in devices per person; a new sign-in ends the oldest.
    pub max_sessions: i64,
    /// Requests per address per 10 minutes, anything at all.
    pub requests_per_address: u32,
    /// Live sockets on the whole server.
    pub max_sockets: usize,
    /// Requests being handled at once; past this, new ones get "busy".
    pub max_in_flight: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_accounts: 100,
            max_sessions: 4,
            requests_per_address: 3000,
            max_sockets: 500,
            max_in_flight: 200,
        }
    }
}

/// Uploads stop when the data disk has less than this free...
pub const UPLOAD_FLOOR_BYTES: u64 = 150 * 1024 * 1024;
/// ...and every write stops below this, so the database can't fill the disk.
pub const WRITE_FLOOR_BYTES: u64 = 40 * 1024 * 1024;

/// Strikes that get an address banned, within STRIKE_WINDOW.
const BAN_AT: u32 = 30;
const STRIKE_WINDOW: Duration = Duration::from_secs(10 * 60);
const BAN_FOR: Duration = Duration::from_secs(60 * 60);
/// A probe for something napsack never has counts this much (3 is a ban).
const PROBE_STRIKES: u32 = 10;

/// Tools that only ever scan for holes. A browser or the app never says these.
const SCANNERS: &[&str] = &[
    "sqlmap",
    "nikto",
    "nmap",
    "masscan",
    "zgrab",
    "nuclei",
    "wpscan",
    "dirbuster",
    "gobuster",
    "feroxbuster",
    "ffuf",
    "acunetix",
    "nessus",
    "openvas",
    "netsparker",
    "whatweb",
    "jaeles",
    "hydra",
    "censysinspect",
    "l9explore",
    "l9tcpid",
    "expanse",
    "internetmeasurement",
];

/// Paths napsack never serves that scanners always try.
fn is_probe(path: &str) -> bool {
    let p = path.to_ascii_lowercase();
    p.ends_with(".php")
        || p.ends_with(".asp")
        || p.ends_with(".aspx")
        || p.ends_with(".jsp")
        || p.ends_with(".cgi")
        || [
            "/.env",
            "/.git",
            "/.aws",
            "/.ssh",
            "/.svn",
            "/.ds_store",
            "/wp-",
            "/wordpress",
            "/phpmyadmin",
            "/pma",
            "/xmlrpc",
            "/cgi-bin",
            "/actuator",
            "/server-status",
            "/vendor/phpunit",
            "/boaform",
            "/hnap1",
            "/owa/",
            "/autodiscover",
            "/solr/",
            "/druid/",
            "/console",
            "/telescope",
            "/_ignition",
            "/config.json",
            "/backup",
        ]
        .iter()
        .any(|probe| {
            p.starts_with(probe) || p.contains(&format!("/{}", probe.trim_start_matches('/')))
        })
}

pub fn is_scanner(user_agent: &str) -> bool {
    let ua = user_agent.to_ascii_lowercase();
    SCANNERS.iter().any(|s| ua.contains(s))
}

/// Strikes and bans per address, in memory (they reset on restart).
#[derive(Default)]
pub struct Bans {
    strikes: Mutex<HashMap<String, (Instant, u32)>>,
    banned: Mutex<HashMap<String, Instant>>,
    /// Requests refused by any rule here, since start (admin panel).
    pub refused: AtomicU64,
}

impl Bans {
    pub fn is_banned(&self, ip: &str) -> bool {
        let mut banned = self.banned.lock().unwrap();
        match banned.get(ip) {
            Some(until) if *until > Instant::now() => true,
            Some(_) => {
                banned.remove(ip);
                false
            }
            None => false,
        }
    }

    /// Adds strikes; returns true if that got the address banned.
    pub fn strike(&self, ip: &str, n: u32) -> bool {
        let now = Instant::now();
        let mut strikes = self.strikes.lock().unwrap();
        if strikes.len() > 10_000 {
            strikes.retain(|_, (start, _)| now.duration_since(*start) < STRIKE_WINDOW);
        }
        let slot = strikes.entry(ip.to_string()).or_insert((now, 0));
        if now.duration_since(slot.0) >= STRIKE_WINDOW {
            *slot = (now, 0);
        }
        slot.1 += n;
        if slot.1 < BAN_AT {
            return false;
        }
        slot.1 = 0;
        drop(strikes);
        let mut banned = self.banned.lock().unwrap();
        if banned.len() > 10_000 {
            banned.retain(|_, until| *until > now);
        }
        banned.insert(ip.to_string(), now + BAN_FOR);
        true
    }

    /// Addresses banned right now.
    pub fn banned_count(&self) -> usize {
        let now = Instant::now();
        self.banned
            .lock()
            .unwrap()
            .values()
            .filter(|u| **u > now)
            .count()
    }
}

/// Requests being handled right now.
pub fn in_flight_gate(limits: &Limits) -> Semaphore {
    Semaphore::new(limits.max_in_flight)
}

/// A bare refusal: nothing for a bot to learn from.
fn refuse(status: StatusCode) -> Response {
    (
        status,
        [(header::CACHE_CONTROL, HeaderValue::from_static("no-store"))],
        "",
    )
        .into_response()
}

/// Runs on every request, before routing: bans, scanners, the per-address
/// budget, and the in-flight ceiling. After it: 404s and probes earn strikes.
pub async fn guard(State(state): State<SharedState>, req: Request, next: Next) -> Response {
    let who = req.extensions().get::<ClientInfo>().cloned();
    let path = req.uri().path().to_owned();
    if let Some(who) = &who {
        if is_scanner(&who.user_agent) {
            state.bans.refused.fetch_add(1, Ordering::Relaxed);
            tracing::debug!(ip = %who.ip, "scanner refused");
            if !who.local {
                state.bans.strike(&who.ip, PROBE_STRIKES);
            }
            return refuse(StatusCode::FORBIDDEN);
        }
        if !who.local {
            if state.bans.is_banned(&who.ip) {
                state.bans.refused.fetch_add(1, Ordering::Relaxed);
                return refuse(StatusCode::FORBIDDEN);
            }
            if is_probe(&path) {
                state.bans.refused.fetch_add(1, Ordering::Relaxed);
                if state.bans.strike(&who.ip, PROBE_STRIKES) {
                    tracing::warn!(ip = %who.ip, "address banned for an hour: probing for files");
                }
                return refuse(StatusCode::NOT_FOUND);
            }
            if !state.request_limit.allow(&who.ip) {
                state.bans.refused.fetch_add(1, Ordering::Relaxed);
                tracing::warn!(ip = %who.ip, "request budget used up");
                return AppError::TooManyRequests(
                    "Slow down a little and try again in a few minutes.".into(),
                )
                .into_response();
            }
        }
    }
    // Load shedding: a burst can't queue up more work than the box can hold.
    let Ok(_permit) = state.in_flight.try_acquire() else {
        state.bans.refused.fetch_add(1, Ordering::Relaxed);
        tracing::warn!("too many requests in flight; shedding");
        return AppError::Unavailable("napsack is busy. Try again in a moment.".into())
            .into_response();
    };
    let response = next.run(req).await;
    if let Some(who) = who.filter(|w| !w.local) {
        // Real use almost never 404s; scanners walk lists of paths.
        if response.status() == StatusCode::NOT_FOUND
            && !path.starts_with("/api/")
            && state.bans.strike(&who.ip, 1)
        {
            tracing::warn!(ip = %who.ip, "address banned for an hour: too many missing pages");
        }
    }
    response
}

/// Every response: no search engine indexing, ever.
pub async fn noindex(req: Request, next: Next) -> Response {
    let mut response = next.run(req).await;
    response.headers_mut().insert(
        "x-robots-tag",
        HeaderValue::from_static("noindex, nofollow, noarchive"),
    );
    response
}

/// Free space on the data disk (where the database and pics live).
pub fn disk_free(state: &SharedState) -> Option<u64> {
    crate::sysinfo::disk_free(&state.config.pic_dir)
}

/// For uploads (pics, pictures): refuse when the disk is getting full.
pub fn check_upload_room(state: &SharedState) -> Result<(), AppError> {
    match disk_free(state) {
        Some(free) if free < UPLOAD_FLOOR_BYTES => {
            tracing::error!(free, "upload refused: data disk nearly full");
            Err(AppError::Unavailable(
                "napsack is short on space right now. Try again later.".into(),
            ))
        }
        _ => Ok(()),
    }
}

/// For any write: the last line, so SQLite never hits a full disk.
pub fn check_write_room(state: &SharedState, method: &Method) -> Result<(), AppError> {
    if *method == Method::GET || *method == Method::HEAD {
        return Ok(());
    }
    match disk_free(state) {
        Some(free) if free < WRITE_FLOOR_BYTES => {
            tracing::error!(free, "write refused: data disk almost full");
            Err(AppError::Unavailable(
                "napsack is short on space right now. Try again later.".into(),
            ))
        }
        _ => Ok(()),
    }
}

/// Sign-up stops once there are this many accounts.
pub async fn accounts_full(db: &sqlx::SqlitePool, max: i64) -> sqlx::Result<bool> {
    // A turned-off account doesn't hold a place (admin_users.rs).
    let n: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM users u WHERE NOT EXISTS
           (SELECT 1 FROM deactivations d WHERE d.user_id = u.id AND d.reactivated_at IS NULL)
           AND NOT EXISTS (SELECT 1 FROM system_accounts s WHERE s.user_id = u.id)",
    )
    .fetch_one(db)
    .await?;
    Ok(n >= max)
}

/// After a new sign-in: if `user` now has more than `max` live sessions, the
/// oldest end (and their sockets close). Returns the token hashes ended.
pub async fn trim_sessions(state: &SharedState, user: i64, max: i64) -> sqlx::Result<Vec<String>> {
    let at = crate::db::now();
    let extra: Vec<String> = sqlx::query_scalar(
        "SELECT token_hash FROM sessions WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ?
         ORDER BY created_at DESC, rowid DESC LIMIT -1 OFFSET ?",
    )
    .bind(user)
    .bind(at)
    .bind(max)
    .fetch_all(&state.db)
    .await?;
    for hash in &extra {
        sqlx::query(
            "UPDATE sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL",
        )
        .bind(at)
        .bind(hash)
        .execute(&state.db)
        .await?;
        state.hub.end_session(user, hash);
    }
    if !extra.is_empty() {
        tracing::info!(
            user_id = user,
            ended = extra.len(),
            "oldest sessions ended: too many devices"
        );
    }
    Ok(extra)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scanners_and_probes_are_recognized() {
        for ua in [
            "sqlmap/1.7",
            "Mozilla/5.0 (compatible; Nuclei)",
            "masscan/1.3",
            "Fuzz Faster U Fool (ffuf)",
        ] {
            assert!(is_scanner(ua), "{ua}");
        }
        for ua in [
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36",
            "napsack/1.0 CFNetwork",
            "python-requests/2.32",
            "curl/8.5.0",
        ] {
            assert!(!is_scanner(ua), "{ua}");
        }
        for p in [
            "/.env",
            "/.git/config",
            "/wp-login.php",
            "/index.php",
            "/api/../.env",
            "/x/.aws/credentials",
            "/phpmyadmin/",
            "/cgi-bin/luci",
        ] {
            assert!(is_probe(p), "{p}");
        }
        for p in [
            "/",
            "/app.js",
            "/api/config",
            "/api/friends",
            "/admin",
            "/sw.js",
            "/favicon.ico",
            "/robots.txt",
        ] {
            assert!(!is_probe(p), "{p}");
        }
    }

    #[tokio::test]
    async fn sign_up_stops_at_the_account_cap() {
        let db = crate::db::tests::temp_db().await;
        assert!(!accounts_full(&db, 2).await.unwrap());
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
        assert!(accounts_full(&db, 2).await.unwrap());
        assert!(!accounts_full(&db, 100).await.unwrap());
    }

    #[test]
    fn strikes_lead_to_a_ban_per_address() {
        let bans = Bans::default();
        assert!(!bans.strike("1.2.3.4", PROBE_STRIKES));
        assert!(!bans.strike("1.2.3.4", PROBE_STRIKES));
        assert!(!bans.is_banned("1.2.3.4"));
        assert!(bans.strike("1.2.3.4", PROBE_STRIKES), "the third probe");
        assert!(bans.is_banned("1.2.3.4"));
        assert!(!bans.is_banned("5.6.7.8"), "only that address");
        for _ in 0..BAN_AT - 1 {
            assert!(!bans.strike("9.9.9.9", 1));
        }
        assert!(bans.strike("9.9.9.9", 1), "enough missing pages");
        assert_eq!(bans.banned_count(), 2);
    }
}
