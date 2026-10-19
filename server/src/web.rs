//! The browser client (and the admin page) are static files compiled into the binary,
//! so a deploy is a single executable. No build step, no Node.

use axum::{extract::State, http::header, response::IntoResponse, routing::get, Json, Router};
use serde_json::{json, Value};

use crate::{version, SharedState};

const INDEX_HTML: &str = include_str!("../static/index.html");
const APP_JS: &str = include_str!("../static/app.js");
const STYLE_CSS: &str = include_str!("../static/style.css");
const CRYPTO_JS: &str = include_str!("../static/crypto.js");
const ADMIN_HTML: &str = include_str!("../static/admin.html");
const ADMIN_JS: &str = include_str!("../static/admin.js");

const CSP: &str = "default-src 'self'; \
    script-src 'self'; \
    style-src 'self'; \
    img-src 'self' blob: data:; \
    media-src 'self' blob:; \
    connect-src 'self'; \
    object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";

pub fn routes() -> Router<SharedState> {
    Router::new()
        .route("/", get(index))
        .route("/app.js", get(app_js))
        .route("/crypto.js", get(crypto_js))
        .route("/style.css", get(style_css))
        .route("/admin", get(admin))
        .route("/admin.js", get(|| async { script(ADMIN_JS) }))
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
        ADMIN_HTML,
    )
}

fn script(body: &'static str) -> impl IntoResponse {
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
        INDEX_HTML,
    )
}

async fn app_js() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/javascript; charset=utf-8"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        APP_JS,
    )
}

async fn crypto_js() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/javascript; charset=utf-8"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        CRYPTO_JS,
    )
}

async fn style_css() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/css; charset=utf-8"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        STYLE_CSS,
    )
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
    }))
}
