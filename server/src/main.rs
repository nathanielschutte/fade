mod admin;
mod auth;
mod chats;
mod db;
mod error;
mod friends;
mod logs;
mod profiles;
mod snaps;
mod version;
mod web;
mod ws;

use std::{net::SocketAddr, sync::Arc, time::Duration};

use axum::{
    extract::DefaultBodyLimit,
    http::{header, HeaderValue},
    middleware,
    routing::{delete, get, post},
    Router,
};
use sqlx::SqlitePool;
use tower_http::set_header::SetResponseHeaderLayer;
use tracing_subscriber::{prelude::*, EnvFilter};

/// Runtime configuration, all from environment variables so systemd/Terraform can own it.
pub struct Config {
    pub bind: SocketAddr,
    pub database_url: String,
    /// If set, new accounts must supply this code. Keeps randoms off a public URL.
    pub invite_code: Option<String>,
    /// How long an unopened snap is held in RAM before it's dropped.
    pub snap_ttl: Duration,
    pub snap_max_bytes: usize,
    /// Ceiling on RAM used by all pending snaps combined.
    pub snap_pool_bytes: usize,
    pub session_days: i64,
    /// Lowercased usernames allowed into the admin panel.
    pub admins: Vec<String>,
    /// Status file the backup job writes (infra/user_data.sh.tftpl, docs/BACKUPS.md).
    pub backup_status_path: String,
    /// Oldest native client version still allowed, per platform. See version.rs.
    pub min_client_versions: Vec<(String, version::Semver)>,
}

fn env_or<T: std::str::FromStr>(key: &str, default: T) -> anyhow::Result<T> {
    match std::env::var(key) {
        Ok(v) if !v.trim().is_empty() => v
            .trim()
            .parse()
            .map_err(|_| anyhow::anyhow!("invalid value for {key}: {v}")),
        _ => Ok(default),
    }
}

impl Config {
    fn from_env() -> anyhow::Result<Self> {
        Ok(Self {
            bind: env_or("FADE_BIND", "127.0.0.1:8080".parse()?)?,
            database_url: env_or("FADE_DATABASE_URL", "sqlite://fade.db".to_string())?,
            invite_code: std::env::var("FADE_INVITE_CODE")
                .ok()
                .filter(|s| !s.trim().is_empty()),
            snap_ttl: Duration::from_secs(env_or::<u64>("FADE_SNAP_TTL_HOURS", 24)? * 3600),
            // Clients compress to ~200 KB; this is the hard ceiling on what the server accepts.
            snap_max_bytes: env_or::<usize>("FADE_SNAP_MAX_KB", 512)? * 1024,
            snap_pool_bytes: env_or::<usize>("FADE_SNAP_POOL_MB", 128)? * 1024 * 1024,
            session_days: env_or("FADE_SESSION_DAYS", 90)?,
            admins: std::env::var("FADE_ADMINS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_lowercase())
                .filter(|s| !s.is_empty())
                .collect(),
            backup_status_path: env_or(
                "FADE_BACKUP_STATUS",
                "/var/lib/fade/backups/last.json".to_string(),
            )?,
            min_client_versions: version::parse_min_versions(
                &std::env::var("FADE_MIN_CLIENT_VERSIONS").unwrap_or_default(),
            )
            .map_err(|e| anyhow::anyhow!("FADE_MIN_CLIENT_VERSIONS: {e}"))?,
        })
    }

    /// Usernames are case-insensitive everywhere else, so here too.
    pub fn is_admin(&self, username: &str) -> bool {
        self.admins.contains(&username.to_lowercase())
    }
}

pub struct AppState {
    pub db: SqlitePool,
    pub hub: ws::Hub,
    pub snaps: snaps::SnapStore,
    pub config: Config,
    pub started_at: std::time::Instant,
    /// Recent log entries for the admin log viewer.
    pub logs: Arc<logs::LogBuffer>,
    pub client_log_limit: logs::ClientRateLimit,
}

pub type SharedState = Arc<AppState>;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Two destinations with separate filters: stdout (the system journal) at
    // RUST_LOG, info by default; the admin viewer's buffer at FADE_LOG_BUFFER,
    // debug by default, so the viewer is verbose without flooding the journal.
    let log_buffer = Arc::new(logs::LogBuffer::new(logs::DEFAULT_CAPACITY));
    let journal_filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| "fade_server=info".into());
    let buffer_filter =
        EnvFilter::try_from_env("FADE_LOG_BUFFER").unwrap_or_else(|_| "fade_server=debug".into());
    tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer().with_filter(journal_filter))
        .with(logs::BufferLayer(log_buffer.clone()).with_filter(buffer_filter))
        .init();

    let config = Config::from_env()?;
    let db = db::connect(&config.database_url).await?;

    // Snap bytes don't survive a restart (by design), so any snap still marked
    // pending from a previous run is gone. Make the DB agree.
    let orphaned = db::expire_orphaned_snaps(&db).await?;
    if orphaned > 0 {
        tracing::info!(orphaned, "marked pics from previous run as expired");
    }

    if config.admins.is_empty() {
        tracing::info!("no FADE_ADMINS set; the admin panel is off");
    }
    let bind = config.bind;
    let state = Arc::new(AppState {
        db,
        hub: ws::Hub::default(),
        snaps: snaps::SnapStore::new(config.snap_pool_bytes, config.snap_ttl),
        config,
        started_at: std::time::Instant::now(),
        logs: log_buffer,
        client_log_limit: logs::ClientRateLimit::default(),
    });

    snaps::spawn_sweeper(state.clone());

    let listener = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!(
        %bind,
        version = version::SERVER_VERSION,
        build = version::BUILD,
        "fade server listening"
    );
    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

fn router(state: SharedState) -> Router {
    let snap_limit = state.config.snap_max_bytes;

    // Everything except /config goes through the client version check, so an
    // outdated app can still read /config and learn that it needs updating.
    let api = Router::new()
        .route("/auth/register", post(auth::register))
        .route("/auth/login", post(auth::login))
        .route("/auth/logout", post(auth::logout))
        .route("/me", get(auth::me))
        .route("/friends", get(friends::list_chats))
        .route("/friends/{user_id}", delete(friends::remove))
        .route("/users/{user_id}/profile", get(profiles::get))
        .route(
            "/friends/requests",
            get(friends::list_requests).post(friends::send_request),
        )
        .route(
            "/friends/requests/{user_id}",
            delete(friends::delete_request),
        )
        .route("/friends/requests/{user_id}/accept", post(friends::accept))
        .route(
            "/chats/{friend_id}/messages",
            get(chats::list).post(chats::send_text),
        )
        .route("/chats/{friend_id}/read", post(chats::mark_read))
        .route(
            "/chats/{friend_id}/snaps",
            post(snaps::upload).layer(DefaultBodyLimit::max(snap_limit)),
        )
        .route("/snaps/{id}", get(snaps::view))
        .route("/admin/stats", get(admin::stats))
        .route("/admin/logs", get(logs::list))
        .route(
            "/logs",
            post(logs::ingest).layer(DefaultBodyLimit::max(64 * 1024)),
        )
        .route("/ws", get(ws::handler))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            version::require_supported_client,
        ))
        .route("/config", get(web::config));

    Router::new()
        .nest("/api", api)
        .merge(web::routes())
        .layer(SetResponseHeaderLayer::overriding(
            header::X_CONTENT_TYPE_OPTIONS,
            HeaderValue::from_static("nosniff"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::REFERRER_POLICY,
            HeaderValue::from_static("no-referrer"),
        ))
        .layer(middleware::from_fn(log_request))
        .with_state(state)
}

/// One line per request. Logs the route template (`/api/chats/{friend_id}/messages`)
/// and the real path, never the query string, headers, or body.
async fn log_request(
    req: axum::extract::Request,
    next: middleware::Next,
) -> axum::response::Response {
    let started = std::time::Instant::now();
    let method = req.method().clone();
    let path = req.uri().path().to_owned();
    let route = req
        .extensions()
        .get::<axum::extract::MatchedPath>()
        .map(|p| p.as_str().to_owned())
        .unwrap_or_else(|| "(unmatched)".to_owned());
    let client = req
        .headers()
        .get(version::CLIENT_HEADER)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("web")
        .to_owned();
    let response = next.run(req).await;
    let status = response.status().as_u16();
    // The log viewer polls every few seconds; logging its own polls would bury everything else.
    if route == "/api/admin/logs" && status < 500 {
        return response;
    }
    let ms = started.elapsed().as_millis() as u64;
    macro_rules! log {
        ($lvl:ident) => {
            tracing::$lvl!(target: "fade_server::http", %method, %route, %path, status, ms, %client, "request")
        };
    }
    match status {
        500.. => log!(error),
        400..=499 => log!(info),
        _ => log!(debug),
    }
    response
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = term => {} }
    tracing::info!("shutting down");
}
