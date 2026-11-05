//! Small in-memory rate limits (fixed windows per key) and the caller's
//! address. Enough for one server and a handful of users; limits reset on restart.

use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::Mutex,
    time::{Duration, Instant},
};

use axum::http::HeaderMap;

pub struct RateLimit {
    limit: u32,
    window: Duration,
    hits: Mutex<HashMap<String, (Instant, u32)>>,
}

/// The most keys one limit tracks. Past it, windows that have ended go first,
/// then the oldest ones still running, so memory stays bounded however many
/// names or addresses a flood makes up. (Evicting a running window forgets
/// its count; the per-address limits make a flood that large slow to build.)
pub const MAX_KEYS: usize = 10_000;
/// Keys longer than this are kept as their SHA-256 instead, so a long key
/// costs no more memory than a short one.
const MAX_KEY_BYTES: usize = 128;

/// One attempt taken ahead of time (`reserve`), to give back if it succeeds.
#[must_use]
pub struct Reserved {
    window: Instant,
}

fn stored_key(key: &str) -> String {
    if key.len() <= MAX_KEY_BYTES {
        key.to_string()
    } else {
        use sha2::{Digest, Sha256};
        let digest = Sha256::digest(key.as_bytes());
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        format!("sha256:{hex}")
    }
}

impl RateLimit {
    pub fn new(limit: u32, window: Duration) -> Self {
        Self {
            limit,
            window,
            hits: Mutex::new(HashMap::new()),
        }
    }

    /// How many of `wanted` units `key` may use right now (and records them).
    pub fn take(&self, key: &str, wanted: u32) -> u32 {
        self.take_at(key, wanted).0
    }

    /// `take`, and when the key's window started.
    fn take_at(&self, key: &str, wanted: u32) -> (u32, Instant) {
        let now = Instant::now();
        let key = stored_key(key);
        let mut hits = self.hits.lock().unwrap();
        if hits.len() >= MAX_KEYS && !hits.contains_key(&key) {
            self.make_room(&mut hits, now);
        }
        let slot = hits.entry(key).or_insert((now, 0));
        if now.duration_since(slot.0) >= self.window {
            *slot = (now, 0);
        }
        let granted = wanted.min(self.limit.saturating_sub(slot.1));
        slot.1 += granted;
        (granted, slot.0)
    }

    /// Drops ended windows; if that isn't enough, the oldest tenth of the
    /// rest, so a flood pays for this once per thousand new keys, not on each.
    fn make_room(&self, hits: &mut HashMap<String, (Instant, u32)>, now: Instant) {
        hits.retain(|_, (start, _)| now.duration_since(*start) < self.window);
        if hits.len() < MAX_KEYS {
            return;
        }
        let mut starts: Vec<Instant> = hits.values().map(|(start, _)| *start).collect();
        let cut = MAX_KEYS / 10;
        let (_, nth, _) = starts.select_nth_unstable(cut);
        let cutoff = *nth;
        hits.retain(|_, (start, _)| *start > cutoff);
    }

    /// Takes one attempt now, before the slow check it guards, so attempts
    /// running at the same time can't all slip under the limit. `None` when
    /// the limit is used up. Give it back with `refund` if the attempt succeeds.
    pub fn reserve(&self, key: &str) -> Option<Reserved> {
        match self.take_at(key, 1) {
            (1, window) => Some(Reserved { window }),
            _ => None,
        }
    }

    /// Gives back a reserved attempt (it succeeded, so it isn't a failure).
    /// Nothing happens if its window has since ended.
    pub fn refund(&self, key: &str, reserved: Reserved) {
        let mut hits = self.hits.lock().unwrap();
        if let Some(slot) = hits.get_mut(&stored_key(key)) {
            if slot.0 == reserved.window {
                slot.1 = slot.1.saturating_sub(1);
            }
        }
    }

    /// True if one more is allowed (and records it).
    pub fn allow(&self, key: &str) -> bool {
        self.take(key, 1) == 1
    }

    /// How many `key` has used in its current window, without recording anything.
    pub fn used(&self, key: &str) -> u32 {
        let hits = self.hits.lock().unwrap();
        hits.get(&stored_key(key))
            .filter(|(start, _)| start.elapsed() < self.window)
            .map_or(0, |(_, n)| *n)
    }

    /// Forgets `key`'s window (an Admin clearing a sign-in lock).
    pub fn clear(&self, key: &str) {
        self.hits.lock().unwrap().remove(&stored_key(key));
    }

    pub fn limit(&self) -> u32 {
        self.limit
    }

    /// True if `key` has used up its window, without recording anything.
    pub fn exhausted(&self, key: &str) -> bool {
        let hits = self.hits.lock().unwrap();
        hits.get(&stored_key(key))
            .is_some_and(|(start, n)| start.elapsed() < self.window && *n >= self.limit)
    }
}

/// Who's calling. Behind Caddy every connection comes from 127.0.0.1, so the
/// real address is the one Caddy puts in X-Forwarded-For. Caddy doesn't pass
/// on a client's own X-Forwarded-For, but take the last entry, the one Caddy
/// added, to be safe. That header is only trusted from a loopback peer: a
/// direct connection can't claim to be someone else.
#[derive(Clone, Debug)]
pub struct ClientInfo {
    pub ip: String,
    pub user_agent: String,
    /// Local, un-proxied connection (development and tests), or an address in
    /// FADE_EXEMPT_ADDRESSES (staging's test and load-test machines). Per-IP
    /// limits don't apply.
    pub local: bool,
}

/// FADE_EXEMPT_ADDRESSES: client addresses treated like local requests, so
/// tests and load tests against staging aren't throttled (docs/operations/staging.md).
/// Never set in production. Unparseable entries are ignored.
fn exempt_addresses() -> &'static [IpAddr] {
    static LIST: std::sync::OnceLock<Vec<IpAddr>> = std::sync::OnceLock::new();
    LIST.get_or_init(|| {
        parse_addresses(&std::env::var("FADE_EXEMPT_ADDRESSES").unwrap_or_default())
    })
}

fn parse_addresses(text: &str) -> Vec<IpAddr> {
    text.split(|c: char| c == ',' || c.is_whitespace())
        .filter_map(|s| s.trim().parse().ok())
        .collect()
}

impl ClientInfo {
    pub fn from_request(peer: Option<SocketAddr>, headers: &HeaderMap) -> Self {
        let peer_ip = peer.map(|p| p.ip());
        let forwarded = headers
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
            .and_then(|v| v.trim().parse::<IpAddr>().ok());
        let (ip, local) = match (peer_ip, forwarded) {
            (Some(p), Some(f)) if p.is_loopback() => (Some(f), false),
            (Some(p), None) => (Some(p), p.is_loopback()),
            (p, _) => (p, false),
        };
        let local = local || ip.is_some_and(|ip| exempt_addresses().contains(&ip));
        let user_agent: String = headers
            .get(axum::http::header::USER_AGENT)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .chars()
            .take(200)
            .collect();
        Self {
            ip: ip.map_or_else(|| "unknown".into(), |ip| ip.to_string()),
            user_agent,
            local,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exempt_address_lists() {
        let list = parse_addresses(" 203.0.113.7, 2001:db8::1 nonsense,,10.0.0.1");
        assert_eq!(list.len(), 3);
        assert!(list.contains(&"203.0.113.7".parse().unwrap()));
        assert!(parse_addresses("").is_empty());
        // Unset (as in production and these tests): nobody is exempt.
        assert!(exempt_addresses().is_empty());
    }

    #[test]
    fn windows_cap_each_key() {
        let rl = RateLimit::new(3, Duration::from_secs(60));
        assert!(rl.allow("a") && rl.allow("a") && rl.allow("a"));
        assert!(!rl.allow("a"));
        assert!(rl.exhausted("a"));
        assert!(rl.allow("b"));
        assert_eq!(rl.take("c", 5), 3);
        let short = RateLimit::new(1, Duration::ZERO);
        assert!(short.allow("x") && short.allow("x")); // zero window: always a fresh window
    }

    #[test]
    fn reserving_counts_attempts_before_they_finish() {
        let rl = RateLimit::new(3, Duration::from_secs(60));
        // Three attempts in flight at once: a fourth is refused before any finishes.
        let held: Vec<_> = (0..3).map(|_| rl.reserve("ana").unwrap()).collect();
        assert!(rl.reserve("ana").is_none() && rl.exhausted("ana"));
        // One succeeded: it gives its attempt back; the failures keep theirs.
        let mut held = held.into_iter();
        rl.refund("ana", held.next().unwrap());
        assert_eq!(rl.used("ana"), 2);
        assert!(rl.reserve("ana").is_some());
        assert!(rl.reserve("ana").is_none());
        // A refund from a window that has ended gives nothing back.
        let short = RateLimit::new(1, Duration::ZERO);
        let old = short.reserve("x").unwrap();
        let _new = short.reserve("x").unwrap();
        short.refund("x", old);
        assert_eq!(short.hits.lock().unwrap().get("x").unwrap().1, 1);
    }

    #[test]
    fn keys_are_bounded_in_number_and_size() {
        let rl = RateLimit::new(5, Duration::from_secs(60));
        let long = "x".repeat(1_000_000);
        assert!(rl.allow(&long) && rl.used(&long) == 1);
        assert!(rl
            .hits
            .lock()
            .unwrap()
            .keys()
            .all(|k| k.len() <= MAX_KEY_BYTES));
        for i in 0..MAX_KEYS * 2 {
            rl.allow(&format!("k{i}"));
        }
        let held = rl.hits.lock().unwrap().len();
        assert!(held <= MAX_KEYS, "{held}");
        // The newest keys are the ones kept.
        assert_eq!(rl.used(&format!("k{}", MAX_KEYS * 2 - 1)), 1);
    }

    fn headers(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.insert(*k, v.parse().unwrap());
        }
        h
    }

    #[test]
    fn client_address_comes_from_caddy_only() {
        let caddy: SocketAddr = "127.0.0.1:50000".parse().unwrap();
        let direct: SocketAddr = "203.0.113.9:443".parse().unwrap();
        let via_caddy = ClientInfo::from_request(
            Some(caddy),
            &headers(&[("x-forwarded-for", "198.51.100.7")]),
        );
        assert_eq!(
            (via_caddy.ip.as_str(), via_caddy.local),
            ("198.51.100.7", false)
        );
        // A client-supplied entry before Caddy's is ignored.
        let spoofed = ClientInfo::from_request(
            Some(caddy),
            &headers(&[("x-forwarded-for", "1.2.3.4, 198.51.100.7")]),
        );
        assert_eq!(spoofed.ip, "198.51.100.7");
        // A direct (non-loopback) connection can't claim another address.
        let liar =
            ClientInfo::from_request(Some(direct), &headers(&[("x-forwarded-for", "1.2.3.4")]));
        assert_eq!((liar.ip.as_str(), liar.local), ("203.0.113.9", false));
        // Local development: loopback without a proxy header.
        let local = ClientInfo::from_request(Some(caddy), &headers(&[("user-agent", "curl/8")]));
        assert_eq!(
            (local.ip.as_str(), local.local, local.user_agent.as_str()),
            ("127.0.0.1", true, "curl/8")
        );
        let junk =
            ClientInfo::from_request(Some(caddy), &headers(&[("x-forwarded-for", "not-an-ip")]));
        assert_eq!(junk.ip, "127.0.0.1");
    }
}
