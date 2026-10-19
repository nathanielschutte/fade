mod admin;
mod auth;
mod chats;
mod db;
mod error;
mod friends;
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
use tower_http::{set_header::SetResponseHeaderLayer, trace::TraceLayer};
use tracing_subscriber::EnvFilter;

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
}

pub type SharedState = Arc<AppState>;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "fade_server=info,tower_http=info".into()),
        )
        .init();

    let config = Config::from_env()?;
    let db = db::connect(&config.database_url).await?;

    // Snap bytes don't survive a restart (by design), so any snap still marked
    // pending from a previous run is gone. Make the DB agree.
    let orphaned = db::expire_orphaned_snaps(&db).await?;
    if orphaned > 0 {
        tracing::info!(orphaned, "marked snaps from previous run as expired");
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
        .layer(TraceLayer::new_for_http())
        .with_state(state)
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
