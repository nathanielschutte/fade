//! The browser client (and the admin page) are static files compiled into the binary,
//! so a deploy is a single executable. No build step, no Node.
//!
//! In development (debug builds, i.e. `cargo run`) the same files are read
//! from disk on every request instead, and the page polls for changes and
//! reloads itself (`static/dev-reload.js`): edit, save, and see it, without
//! rebuilding. None of that exists in release builds: it's compiled out, so
//! production only ever serves what's in the binary. Even in development, only
//! these fixed files can be read, never a path from a request.

use std::borrow::Cow;

use axum::{extract::State, http::header, response::IntoResponse, routing::get, Json, Router};
use serde_json::{json, Value};

use crate::{version, SharedState};

/// One of the web app's text files: compiled in, and in debug builds also
/// read fresh from its source file.
struct Asset {
    embedded: &'static str,
    #[cfg_attr(not(debug_assertions), allow(dead_code))]
    path: &'static str,
}

impl Asset {
    fn text(&self) -> Cow<'static, str> {
        #[cfg(debug_assertions)]
        if let Ok(fresh) = std::fs::read_to_string(self.path) {
            return Cow::Owned(fresh);
        }
        Cow::Borrowed(self.embedded)
    }
}

/// `asset!("../static/app.js")`: the file compiled in, and where it lives on disk.
macro_rules! asset {
    ($file:literal) => {
        Asset {
            embedded: include_str!($file),
            path: concat!(env!("CARGO_MANIFEST_DIR"), "/src/", $file),
        }
    };
}

const INDEX_HTML: Asset = asset!("../static/index.html");
const APP_JS: Asset = asset!("../static/app.js");
const STYLE_CSS: Asset = asset!("../static/style.css");
// Shared with the iOS app; see shared/crypto/crypto.js.
const CRYPTO_JS: Asset = asset!("../../shared/crypto/crypto.js");
const KEYSTORE_JS: Asset = asset!("../static/keystore.js");
const FAVICON_SVG: Asset = asset!("../static/favicon.svg");
const ADMIN_HTML: Asset = asset!("../static/admin.html");
const ADMIN_JS: Asset = asset!("../static/admin.js");
// Installing napsack as an app, and notifications (push.rs).
const SW_JS: Asset = asset!("../static/sw.js");
const QR_JS: Asset = asset!("../static/qr.js");
const DRAW_JS: Asset = asset!("../static/draw.js");
// The friend map: the math is shared with the iOS app (shared/graph/graph.js); the drawing is the web app's.
const GRAPH_JS: Asset = asset!("../../shared/graph/graph.js");
const GRAPH_VIEW_JS: Asset = asset!("../static/graph-view.js");
// Marks non-production copies (staging) on every page.
const ENV_JS: Asset = asset!("../static/env.js");
const MANIFEST: Asset = asset!("../static/manifest.webmanifest");
const ICON_192: &[u8] = include_bytes!("../static/icon-192.png");
const ICON_512: &[u8] = include_bytes!("../static/icon-512.png");
const APPLE_TOUCH_ICON: &[u8] = include_bytes!("../static/apple-touch-icon.png");

const CSP: &str = "default-src 'self'; \
    script-src 'self'; \
    style-src 'self'; \
    img-src 'self' blob: data:; \
    media-src 'self' blob:; \
    connect-src 'self'; \
    object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";

pub fn routes() -> Router<SharedState> {
    let router = Router::new()
        .route("/", get(index))
        // Invite links open the app, which reads the token from the address.
        .route("/i/{token}", get(index))
        .route("/app.js", get(|| async { script(APP_JS.text()) }))
        .route("/crypto.js", get(|| async { script(CRYPTO_JS.text()) }))
        .route("/keystore.js", get(|| async { script(KEYSTORE_JS.text()) }))
        .route("/style.css", get(style_css))
        .route("/admin", get(admin))
        .route("/favicon.svg", get(favicon))
        // Browsers ask for /favicon.ico on their own; point them at the SVG.
        .route(
            "/favicon.ico",
            get(|| async { axum::response::Redirect::permanent("/favicon.svg") }),
        )
        .route("/admin.js", get(|| async { script(ADMIN_JS.text()) }))
        // A private messenger: nothing here for search engines.
        .route(
            "/robots.txt",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
                    "User-agent: *\nDisallow: /\n",
                )
            }),
        )
        // At the root, so it can show notifications for the whole site.
        .route("/sw.js", get(|| async { script(SW_JS.text()) }))
        .route("/qr.js", get(|| async { script(QR_JS.text()) }))
        .route("/env.js", get(|| async { script(ENV_JS.text()) }))
        .route("/draw.js", get(|| async { script(DRAW_JS.text()) }))
        .route("/graph.js", get(|| async { script(GRAPH_JS.text()) }))
        .route(
            "/graph-view.js",
            get(|| async { script(GRAPH_VIEW_JS.text()) }),
        )
        .route(
            "/manifest.webmanifest",
            get(|| async {
                (
                    [
                        (header::CONTENT_TYPE, "application/manifest+json"),
                        (header::CACHE_CONTROL, "no-cache"),
                    ],
                    MANIFEST.text(),
                )
            }),
        )
        .route("/icon-192.png", get(|| async { png(ICON_192) }))
        .route("/icon-512.png", get(|| async { png(ICON_512) }))
        .route(
            "/apple-touch-icon.png",
            get(|| async { png(APPLE_TOUCH_ICON) }),
        );
    #[cfg(debug_assertions)]
    let router = dev::routes(router);
    router
}

/// A page, with the development reload script added in debug builds.
fn page(asset: &Asset) -> Cow<'static, str> {
    let html = asset.text();
    #[cfg(debug_assertions)]
    let html = Cow::Owned(html.replacen("</body>", dev::SCRIPT_TAG, 1));
    html
}

/// The page is public; the data behind it (`/api/admin/stats`) is admin-only.
async fn admin() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CONTENT_SECURITY_POLICY, CSP),
            (header::CACHE_CONTROL, "no-cache"),
            (header::HeaderName::from_static("x-robots-tag"), "noindex"),
        ],
        page(&ADMIN_HTML),
    )
}

async fn favicon() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "image/svg+xml"),
            (header::CACHE_CONTROL, "public, max-age=86400"),
        ],
        FAVICON_SVG.text(),
    )
}

fn png(body: &'static [u8]) -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "image/png"),
            (header::CACHE_CONTROL, "public, max-age=86400"),
        ],
        body,
    )
}

fn script(body: Cow<'static, str>) -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/javascript; charset=utf-8"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        body,
    )
}

async fn index() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CONTENT_SECURITY_POLICY, CSP),
            (header::CACHE_CONTROL, "no-cache"),
            (
                header::HeaderName::from_static("permissions-policy"),
                "camera=(self), microphone=(), geolocation=()",
            ),
        ],
        page(&INDEX_HTML),
    )
}

async fn style_css() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/css; charset=utf-8"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        STYLE_CSS.text(),
    )
}

/// Development only: live reload. Compiled out of release builds.
#[cfg(debug_assertions)]
mod dev {
    use super::*;

    pub const SCRIPT_TAG: &str =
        "<script type=\"module\" src=\"/dev/reload.js\"></script>\n</body>";
    const RELOAD_JS: Asset = asset!("../static/dev-reload.js");

    pub fn routes(router: Router<SharedState>) -> Router<SharedState> {
        router
            .route("/dev/reload.js", get(|| async { script(RELOAD_JS.text()) }))
            .route("/dev/changes", get(changes))
    }

    fn modified_ms(asset: &Asset) -> u128 {
        std::fs::metadata(asset.path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_millis())
    }

    /// When this server started: a restart (after a Rust change) reloads the page too.
    fn started_ms() -> u128 {
        static STARTED: std::sync::OnceLock<u128> = std::sync::OnceLock::new();
        *STARTED.get_or_init(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_millis())
        })
    }

    /// When the stylesheet last changed, and when anything else did. The
    /// page swaps in new styles in place, and reloads for anything else.
    async fn changes() -> Json<Value> {
        let others = [
            &INDEX_HTML,
            &APP_JS,
            &CRYPTO_JS,
            &KEYSTORE_JS,
            &ADMIN_HTML,
            &ADMIN_JS,
            &QR_JS,
            &DRAW_JS,
            &GRAPH_JS,
            &GRAPH_VIEW_JS,
            &ENV_JS,
        ];
        Json(json!({
            "css": modified_ms(&STYLE_CSS),
            "other": others.iter().map(|a| modified_ms(a)).max(),
            "server": started_ms(),
        }))
    }
}

/// Unauthenticated settings the client needs before sign-in. Also how a native
/// app learns whether it's still supported, so this route skips the version check.
pub async fn config(State(state): State<SharedState>) -> Json<Value> {
    let min_versions: serde_json::Map<String, Value> = state
        .config
        .min_client_versions
        .iter()
        .map(|(platform, v)| (platform.clone(), Value::String(v.to_string())))
        .collect();
    Json(json!({
        "invite_required": state.config.invite_code.is_some(),
        "snap_max_bytes": state.config.snap_max_bytes,
        "snap_ttl_hours": state.config.snap_ttl.as_secs() / 3600,
        "api_version": version::API_VERSION,
        "server_version": version::SERVER_VERSION,
        "build": version::BUILD,
        "message_formats": version::MESSAGE_FORMATS,
        "min_client_versions": min_versions,
        // Non-production copies only ("staging"); null in production.
        "environment": state.config.environment,
        // When this server started (unix seconds), for the build line on non-production copies.
        "started_at": crate::db::now() - state.started_at.elapsed().as_secs() as i64,
        // The browser's applicationServerKey for push subscriptions (push.rs).
        "vapid_public_key": state.vapid.public,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Debug builds read the real files; what's compiled in is the same file.
    #[test]
    fn assets_point_at_their_source_files() {
        for asset in [
            &INDEX_HTML,
            &APP_JS,
            &STYLE_CSS,
            &CRYPTO_JS,
            &ADMIN_HTML,
            &GRAPH_JS,
            &GRAPH_VIEW_JS,
            &ENV_JS,
        ] {
            assert!(std::path::Path::new(asset.path).is_file(), "{}", asset.path);
            assert_eq!(asset.text(), std::fs::read_to_string(asset.path).unwrap());
        }
        assert!(
            page(&INDEX_HTML).contains("/dev/reload.js"),
            "debug pages get the reload script"
        );
    }
}
