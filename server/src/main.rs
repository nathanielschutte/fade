mod admin;
mod auth;
mod chats;
mod db;
mod error;
mod friends;
mod group_pics;
mod groups;
mod images;
mod logs;
mod people;
mod profiles;
mod ratelimit;
mod snaps;
mod sysinfo;
mod text;
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
    /// Ceiling on disk used by all unopened direct pics combined.
    pub snap_disk_bytes: usize,
    pub session_days: i64,
    /// Lowercased usernames allowed into the admin panel.
    pub admins: Vec<String>,
    /// Where group pic files live until they're opened or expire. Defaults to
    /// a `pics` folder next to the database, on the same (backed-up) volume.
    pub pic_dir: std::path::PathBuf,
    pub group_pic_ttl: Duration,
    /// Cap on group pic bytes held on disk.
    pub group_pic_disk_bytes: usize,
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
            snap_ttl: Duration::from_secs(env_or::<u64>("FADE_SNAP_TTL_HOURS", 24 * 30)? * 3600),
            // Clients compress to ~200 KB; this is the hard ceiling on what the server accepts.
            snap_max_bytes: env_or::<usize>("FADE_SNAP_MAX_KB", 512)? * 1024,
            snap_disk_bytes: env_or::<usize>("FADE_SNAP_DISK_MB", 256)? * 1024 * 1024,
            session_days: env_or("FADE_SESSION_DAYS", 90)?,
            admins: std::env::var("FADE_ADMINS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_lowercase())
                .filter(|s| !s.is_empty())
                .collect(),
            pic_dir: match std::env::var("FADE_PIC_DIR") {
                Ok(dir) if !dir.trim().is_empty() => dir.trim().into(),
                _ => db::default_pic_dir(&env_or(
                    "FADE_DATABASE_URL",
                    "sqlite://fade.db".to_string(),
                )?),
            },
            group_pic_ttl: Duration::from_secs(
                env_or::<u64>("FADE_GROUP_PIC_TTL_HOURS", 24 * 30)? * 3600,
            ),
            group_pic_disk_bytes: env_or::<usize>("FADE_GROUP_PIC_DISK_MB", 200)? * 1024 * 1024,
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
    pub config: Config,
    pub started_at: std::time::Instant,
    /// Recent log entries for the admin log viewer.
    pub logs: Arc<logs::LogBuffer>,
    /// Client log entries per user (or per address when signed out) per minute.
    pub client_log_limit: ratelimit::RateLimit,
    /// Sign-in and sign-up attempts per address.
    pub auth_ip_limit: ratelimit::RateLimit,
    /// Failed sign-ins per username.
    pub login_fail_limit: ratelimit::RateLimit,
    /// Image uploads (group pics and pictures) per user.
    pub image_upload_limit: ratelimit::RateLimit,
    /// Any write to the API, per address.
    pub write_limit: ratelimit::RateLimit,
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
        .with(
            tracing_subscriber::fmt::layer()
                // Plain text in the journal, so `journalctl | grep ip=...` works.
                .with_ansi(std::io::IsTerminal::is_terminal(&std::io::stdout()))
                .with_filter(journal_filter),
        )
        .with(logs::BufferLayer(log_buffer.clone()).with_filter(buffer_filter))
        .init();

    let config = Config::from_env()?;
    let db = db::connect(&config.database_url).await?;
    std::fs::create_dir_all(&config.pic_dir)
        .map_err(|e| anyhow::anyhow!("creating {}: {e}", config.pic_dir.display()))?;

    // Unopened pics wait on disk; make the database and the files agree.
    let (lost, strays) = snaps::reconcile(&db, &config.pic_dir).await?;
    if lost > 0 || strays > 0 {
        tracing::info!(lost, strays, "reconciled unopened pics with their files");
    }

    if config.admins.is_empty() {
        tracing::info!("no FADE_ADMINS set; the admin panel is off");
    }
    let bind = config.bind;
    let state = Arc::new(AppState {
        db,
        hub: ws::Hub::default(),
        config,
        started_at: std::time::Instant::now(),
        logs: log_buffer,
        client_log_limit: ratelimit::RateLimit::new(300, Duration::from_secs(60)),
        auth_ip_limit: ratelimit::RateLimit::new(30, Duration::from_secs(10 * 60)),
        login_fail_limit: ratelimit::RateLimit::new(10, Duration::from_secs(15 * 60)),
        image_upload_limit: ratelimit::RateLimit::new(60, Duration::from_secs(10 * 60)),
        write_limit: ratelimit::RateLimit::new(600, Duration::from_secs(10 * 60)),
    });

    snaps::spawn_sweeper(state.clone());
    group_pics::spawn_sweeper(state.clone());

    let listener = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!(
        %bind,
        version = version::SERVER_VERSION,
        build = version::BUILD,
        "fade server listening"
    );
    // Connection info gives the peer address; see ratelimit::ClientInfo.
    axum::serve(
        listener,
        router(state).into_make_service_with_connect_info::<SocketAddr>(),
    )
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
            "/users/{user_id}/avatar/{avatar_id}",
            get(people::get_avatar),
        )
        .route("/me/name", axum::routing::put(people::set_display_name))
        .route(
            "/me/avatar",
            post(people::set_avatar)
                .delete(people::clear_avatar)
                .layer(DefaultBodyLimit::max(people::AVATAR_MAX_BYTES)),
        )
        .route(
            "/friends/{user_id}/nickname",
            axum::routing::put(people::set_nickname),
        )
        .route("/groups", get(groups::list).post(groups::create))
        .route("/groups/{group_id}", get(groups::get).patch(groups::rename))
        .route("/groups/{group_id}/members", post(groups::add_member))
        .route(
            "/groups/{group_id}/members/{user_id}",
            delete(groups::remove_member),
        )
        .route(
            "/groups/{group_id}/messages",
            get(groups::messages).post(groups::send),
        )
        .route("/groups/{group_id}/read", post(groups::mark_read))
        .route(
            "/groups/{group_id}/pics",
            post(group_pics::upload).layer(DefaultBodyLimit::max(snap_limit)),
        )
        .route("/groups/{group_id}/pics/{pic_id}", get(group_pics::view))
        .route(
            "/groups/{group_id}/avatar",
            post(group_pics::set_avatar).layer(DefaultBodyLimit::max(group_pics::AVATAR_MAX_BYTES)),
        )
        .route(
            "/groups/{group_id}/avatar/{avatar_id}",
            get(group_pics::get_avatar),
        )
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
        .route_layer(middleware::from_fn_with_state(state.clone(), limit_writes))
        .route("/config", get(web::config))
        // Nothing from the API belongs in a cache: it's private, or it changes.
        .layer(SetResponseHeaderLayer::overriding(
            header::CACHE_CONTROL,
            HeaderValue::from_static("no-store"),
        ));

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
        // Defense in depth for every response, on top of each page's CSP.
        .layer(SetResponseHeaderLayer::overriding(
            header::X_FRAME_OPTIONS,
            HeaderValue::from_static("DENY"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::HeaderName::from_static("cross-origin-opener-policy"),
            HeaderValue::from_static("same-origin"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::HeaderName::from_static("cross-origin-resource-policy"),
            HeaderValue::from_static("same-origin"),
        ))
        .layer(SetResponseHeaderLayer::if_not_present(
            header::HeaderName::from_static("permissions-policy"),
            HeaderValue::from_static(
                "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
            ),
        ))
        .layer(middleware::from_fn(log_request))
        .with_state(state)
}

/// Caps API writes per address, so no one can flood the database. Sign-in
/// and client logs have their own, tighter limits.
async fn limit_writes(
    axum::extract::State(state): axum::extract::State<SharedState>,
    req: axum::extract::Request,
    next: middleware::Next,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let path = req.uri().path();
    let exempt = path.contains("/auth/") || path.ends_with("/logs");
    if req.method() != axum::http::Method::GET && !exempt {
        if let Some(who) = req.extensions().get::<ratelimit::ClientInfo>() {
            if !who.local && !state.write_limit.allow(&who.ip) {
                tracing::warn!(ip = %who.ip, "write rate limited");
                return error::AppError::TooManyRequests(
                    "Slow down a little and try again in a few minutes.".into(),
                )
                .into_response();
            }
        }
    }
    next.run(req).await
}

/// One line per request: who (address, user agent), what (method, route
/// template, real path), and the outcome. Never the query string, other
/// headers, or the body. Also hands the caller's address to handlers.
async fn log_request(
    mut req: axum::extract::Request,
    next: middleware::Next,
) -> axum::response::Response {
    let started = std::time::Instant::now();
    let peer = req
        .extensions()
        .get::<axum::extract::ConnectInfo<SocketAddr>>()
        .map(|c| c.0);
    let who = ratelimit::ClientInfo::from_request(peer, req.headers());
    req.extensions_mut().insert(who.clone());
    let host: String = req
        .headers()
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .chars()
        .take(100)
        .collect();
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
            tracing::$lvl!(
                target: "fade_server::http",
                ip = %who.ip, %method, %route, %path, status, ms, %client,
                ua = %who.user_agent, %host, "request"
            )
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
