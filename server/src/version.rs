//! Client/server compatibility. The rules behind these constants are in
//! docs/RELEASING.md; read that before changing any of them.

use axum::{
    extract::{Request, State},
    middleware::Next,
    response::{IntoResponse, Response},
};

use crate::{error::AppError, SharedState};

/// Bumped only for a breaking API change, which also gets a new route prefix.
/// Additive changes (new endpoints, new optional fields) keep it the same.
pub const API_VERSION: u32 = 1;

/// Encryption formats the server will store. The server can't read messages,
/// so this just stops a client from writing a format no released client reads.
/// Both are described in docs/how-napsack-works.md: format 1 is the original
/// scheme; format 2 is a pic with a caption sealed inside (pics only).
pub const MESSAGE_FORMATS: &[i64] = &[1, 2];
const TEXT_FORMATS: &[i64] = &[1];
const SNAP_FORMATS: &[i64] = &[1, 2];

pub fn default_format() -> i64 {
    1
}

fn check(allowed: &[i64], format: i64) -> Result<(), AppError> {
    if allowed.contains(&format) {
        Ok(())
    } else {
        Err(AppError::bad(format!(
            "This server doesn't accept message format {format} here."
        )))
    }
}

pub fn check_text_format(format: i64) -> Result<(), AppError> {
    check(TEXT_FORMATS, format)
}

pub fn check_snap_format(format: i64) -> Result<(), AppError> {
    check(SNAP_FORMATS, format)
}

pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Set by the release build (git short sha, "-dirty" if built from uncommitted code).
pub const BUILD: &str = match option_env!("FADE_BUILD") {
    Some(b) => b,
    None => "dev",
};

/// Native clients send `X-Napsack-Client: <platform>/<version>`, e.g. `ios/1.2.0+37`.
/// The web client is served by this same binary, so it never needs to.
pub const CLIENT_HEADER: &str = "x-napsack-client";

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Semver(pub u64, pub u64, pub u64);

impl Semver {
    /// Accepts `1`, `1.2`, `1.2.3`, and ignores `-pre` / `+build` suffixes.
    pub fn parse(s: &str) -> Option<Self> {
        let core = s.trim().split(['+', '-']).next()?;
        let mut parts = core.split('.').map(|p| p.parse::<u64>().ok());
        let major = parts.next()??;
        let minor = parts.next().unwrap_or(Some(0))?;
        let patch = parts.next().unwrap_or(Some(0))?;
        if parts.next().is_some() {
            return None;
        }
        Some(Self(major, minor, patch))
    }
}

impl std::fmt::Display for Semver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.0, self.1, self.2)
    }
}

/// `FADE_MIN_CLIENT_VERSIONS=ios=1.2.0,android=1.0.0`
pub fn parse_min_versions(s: &str) -> anyhow::Result<Vec<(String, Semver)>> {
    s.split(',')
        .map(str::trim)
        .filter(|e| !e.is_empty())
        .map(|entry| {
            let (platform, version) = entry
                .split_once('=')
                .ok_or_else(|| anyhow::anyhow!("expected platform=version, got {entry:?}"))?;
            let version = Semver::parse(version)
                .ok_or_else(|| anyhow::anyhow!("bad version in {entry:?}"))?;
            Ok((platform.trim().to_lowercase(), version))
        })
        .collect()
}

/// `ios/1.2.0+37` -> ("ios", 1.2.0)
pub fn parse_client(header: &str) -> Option<(String, Semver)> {
    let (platform, version) = header.trim().split_once('/')?;
    Some((platform.to_lowercase(), Semver::parse(version)?))
}

/// Turns away clients older than the configured minimum for their platform.
/// Requests without the header (the web client, scripts) pass through.
pub async fn require_supported_client(
    State(state): State<SharedState>,
    req: Request,
    next: Next,
) -> Response {
    let client = req
        .headers()
        .get(CLIENT_HEADER)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_client);
    if let Some((platform, version)) = client {
        let min = state
            .config
            .min_client_versions
            .iter()
            .find(|(p, _)| *p == platform);
        if let Some((_, min)) = min {
            if version < *min {
                tracing::info!(%platform, %version, %min, "client too old");
                return AppError::UpgradeRequired(format!(
                    "This version of napsack is too old. Update to {min} or newer to keep using it."
                ))
                .into_response();
            }
        }
    }
    next.run(req).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semver_parsing_and_order() {
        assert_eq!(Semver::parse("1.2.3"), Some(Semver(1, 2, 3)));
        assert_eq!(Semver::parse("1.2"), Some(Semver(1, 2, 0)));
        assert_eq!(Semver::parse("2"), Some(Semver(2, 0, 0)));
        assert_eq!(Semver::parse("1.2.3+45"), Some(Semver(1, 2, 3)));
        assert_eq!(Semver::parse("1.2.3-beta.1"), Some(Semver(1, 2, 3)));
        assert_eq!(Semver::parse("1.2.3.4"), None);
        assert_eq!(Semver::parse("one"), None);
        assert!(Semver(1, 10, 0) > Semver(1, 9, 9));
    }

    #[test]
    fn client_header_and_min_versions() {
        assert_eq!(
            parse_client("iOS/1.4.0+12"),
            Some(("ios".into(), Semver(1, 4, 0)))
        );
        assert_eq!(parse_client("garbage"), None);
        let mins = parse_min_versions(" ios=1.2.0, android=1.0 ").unwrap();
        assert_eq!(
            mins,
            vec![
                ("ios".into(), Semver(1, 2, 0)),
                ("android".into(), Semver(1, 0, 0))
            ]
        );
        assert!(parse_min_versions("ios").is_err());
        assert!(parse_min_versions("").unwrap().is_empty());
    }
}
