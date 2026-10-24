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
        let now = Instant::now();
        let mut hits = self.hits.lock().unwrap();
        if hits.len() > 10_000 {
            hits.retain(|_, (start, _)| now.duration_since(*start) < self.window);
        }
        let slot = hits.entry(key.to_string()).or_insert((now, 0));
        if now.duration_since(slot.0) >= self.window {
            *slot = (now, 0);
        }
        let granted = wanted.min(self.limit.saturating_sub(slot.1));
        slot.1 += granted;
        granted
    }

    /// True if one more is allowed (and records it).
    pub fn allow(&self, key: &str) -> bool {
        self.take(key, 1) == 1
    }

    /// How many `key` has used in its current window, without recording anything.
    pub fn used(&self, key: &str) -> u32 {
        let hits = self.hits.lock().unwrap();
        hits.get(key)
            .filter(|(start, _)| start.elapsed() < self.window)
            .map_or(0, |(_, n)| *n)
    }

    /// Forgets `key`'s window (an Admin clearing a sign-in lock).
    pub fn clear(&self, key: &str) {
        self.hits.lock().unwrap().remove(key);
    }

    pub fn limit(&self) -> u32 {
        self.limit
    }

    /// True if `key` has used up its window, without recording anything.
    pub fn exhausted(&self, key: &str) -> bool {
        let hits = self.hits.lock().unwrap();
        hits.get(key)
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
