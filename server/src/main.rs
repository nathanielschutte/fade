mod account;
mod admin;
mod auth;
mod aws;
mod birthdays;
mod chats;
mod db;
mod error;
mod friends;
mod graph;
mod group_pics;
mod groups;
mod guard;
mod health;
mod images;
mod invites;
mod logs;
mod marks;
mod metrics;
mod people;
mod presence;
mod profiles;
mod push;
mod ratelimit;
mod reactions;
mod roles;
mod snaps;
mod streaks;
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
    /// Admins from FADE_ADMINS (development, tests). Production names an SSM
    /// parameter instead (`admins_param`); see roles.rs.
    pub admins: Vec<String>,
    pub admins_param: Option<String>,
    /// Where group pic files live until they're opened or expire. Defaults to
    /// a `pics` folder next to the database, on the same (backed-up) volume.
    pub pic_dir: std::path::PathBuf,
    pub group_pic_ttl: Duration,
    /// Cap on group pic bytes held on disk.
    pub group_pic_disk_bytes: usize,
    /// The site's address, e.g. https://napsack.getattr.com: the contact in
    /// push requests (VAPID `sub`). Set by Terraform; never hardcoded.
    pub public_url: String,
    /// Lets push go to http://127.0.0.1 receivers. Only the test suite sets it.
    pub push_allow_local: bool,
    /// Hard caps and budgets against abuse (guard.rs).
    pub limits: guard::Limits,
    /// Status file the backup job writes (infra/user_data.sh.tftpl, docs/BACKUPS.md).
    pub backup_status_path: String,
    /// Oldest native client version still allowed, per platform. See version.rs.
    pub min_client_versions: Vec<(String, version::Semver)>,
    /// The metrics store (metrics.rs), next to the database by default.
    pub metrics_db: std::path::PathBuf,
    pub metrics_retention_hours: i64,
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
            admins: roles::parse_list(&std::env::var("FADE_ADMINS").unwrap_or_default()),
            admins_param: std::env::var("FADE_ADMINS_PARAM")
                .ok()
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty()),
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
            public_url: env_or("FADE_PUBLIC_URL", "https://localhost".to_string())?,
            push_allow_local: env_or("FADE_PUSH_ALLOW_LOCAL", false)?,
            limits: {
                let d = guard::Limits::default();
                guard::Limits {
                    max_accounts: env_or("FADE_MAX_ACCOUNTS", d.max_accounts)?,
                    max_sessions: env_or("FADE_MAX_SESSIONS", d.max_sessions)?,
                    requests_per_address: env_or(
                        "FADE_REQUESTS_PER_ADDRESS",
                        d.requests_per_address,
                    )?,
                    max_sockets: env_or("FADE_MAX_SOCKETS", d.max_sockets)?,
                    max_in_flight: env_or("FADE_MAX_IN_FLIGHT", d.max_in_flight)?,
                }
            },
            backup_status_path: env_or(
                "FADE_BACKUP_STATUS",
                "/var/lib/fade/backups/last.json".to_string(),
            )?,
            min_client_versions: version::parse_min_versions(
                &std::env::var("FADE_MIN_CLIENT_VERSIONS").unwrap_or_default(),
            )
            .map_err(|e| anyhow::anyhow!("FADE_MIN_CLIENT_VERSIONS: {e}"))?,
            metrics_db: match std::env::var("FADE_METRICS_DB") {
                Ok(path) if !path.trim().is_empty() => path.trim().into(),
                _ => db::default_pic_dir(&env_or(
                    "FADE_DATABASE_URL",
                    "sqlite://fade.db".to_string(),
                )?)
                .with_file_name("metrics.db"),
            },
            metrics_retention_hours: env_or("FADE_METRICS_RETENTION_HOURS", 72)?,
        })
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
    /// Signs Web Push requests (push.rs).
    pub vapid: push::Vapid,
    /// Strikes and bans per address (guard.rs).
    pub bans: guard::Bans,
    /// Requests being handled right now (guard.rs).
    pub in_flight: tokio::sync::Semaphore,
    /// Every request, per address.
    pub request_limit: ratelimit::RateLimit,
    /// Writes per signed-in session.
    pub session_write_limit: ratelimit::RateLimit,
    /// Friend requests per person per day.
    pub friend_request_limit: ratelimit::RateLimit,
    /// New groups per person per day.
    pub group_create_limit: ratelimit::RateLimit,
    /// New invite links per person per day.
    pub invite_create_limit: ratelimit::RateLimit,
    /// Talks to browsers' push services.
    pub http: reqwest::Client,
    /// Machine and server readings for the admin Metrics tab.
    pub metrics: metrics::Metrics,
    /// Who's an Admin (roles.rs): settings, reloadable.
    pub admins: roles::Admins,
}

pub type SharedState = Arc<AppState>;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Two destinations with separate filters: stdout (the system journal) at
    // RUST_LOG, info by default; the admin viewer's buffer at FADE_LOG_BUFFER,
    // debug by default, so the viewer is verbose without flooding the journal.
    let log_buffer = Arc::new(logs::LogBuffer::new(logs::DEFAULT_CAPACITY));
    let journal_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "fade_server=info,napsack_client=warn".into());
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

    let vapid = push::load_vapid(&db).await?;
    let limits = config.limits.clone();

    let admins = roles::Admins::new(config.admins.clone(), config.admins_param.clone());
    let bind = config.bind;
    let metrics = metrics::Metrics::open(&config.metrics_db, config.metrics_retention_hours).await;
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
        vapid,
        bans: guard::Bans::default(),
        in_flight: guard::in_flight_gate(&limits),
        request_limit: ratelimit::RateLimit::new(
            limits.requests_per_address,
            Duration::from_secs(10 * 60),
        ),
        session_write_limit: ratelimit::RateLimit::new(600, Duration::from_secs(10 * 60)),
        friend_request_limit: ratelimit::RateLimit::new(50, Duration::from_secs(24 * 3600)),
        group_create_limit: ratelimit::RateLimit::new(20, Duration::from_secs(24 * 3600)),
        invite_create_limit: ratelimit::RateLimit::new(20, Duration::from_secs(24 * 3600)),
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()?,
        metrics,
        admins,
    });
    metrics::spawn(state.clone());
    load_admins(state.clone()).await;

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
        .route("/auth/recover/start", post(account::recover_start))
        .route("/auth/recover/finish", post(account::recover_finish))
        .route("/auth/reset", post(account::reset_with_code))
        .route("/auth/unlock", post(account::unlock))
        .route("/me/password", post(account::change_password))
        .route("/me/recovery", axum::routing::put(account::set_recovery))
        .route("/me/security", get(account::security))
        .route("/me/sessions/end-others", post(account::end_other_sessions))
        .route(
            "/admin/users/{user_id}/reset-code",
            post(account::issue_reset_code),
        )
        .route("/me", get(auth::me))
        .route("/friends", get(friends::list_chats))
        .route(
            "/chats/{friend_id}/favorite",
            axum::routing::put(marks::favorite_chat),
        )
        .route(
            "/chats/{friend_id}/hidden",
            axum::routing::put(marks::hide_chat),
        )
        .route(
            "/chats/{friend_id}/mute",
            axum::routing::put(marks::mute_chat),
        )
        .route(
            "/groups/{group_id}/mute",
            axum::routing::put(marks::mute_group),
        )
        .route(
            "/groups/{group_id}/favorite",
            axum::routing::put(marks::favorite_group),
        )
        .route("/friends/{user_id}", delete(friends::remove))
        .route("/users/{user_id}/profile", get(profiles::get))
        .route(
            "/users/{user_id}/avatar/{avatar_id}",
            get(people::get_avatar),
        )
        .route("/me/name", axum::routing::put(people::set_display_name))
        .route("/me/birthday", axum::routing::put(birthdays::set))
        .route("/me/settings", axum::routing::put(presence::set_settings))
        .route("/invites", get(invites::list).post(invites::create))
        .route("/invites/{invite_id}/revoke", post(invites::revoke))
        .route("/invites/lookup/{token}", get(invites::lookup))
        .route("/invites/accept", post(invites::accept))
        .route("/push/subscriptions", post(push::subscribe))
        .route("/push/subscriptions/remove", post(push::unsubscribe))
        .route(
            "/chats/{friend_id}/messages/{message_id}/reaction",
            axum::routing::put(reactions::react),
        )
        .route(
            "/groups/{group_id}/messages/{message_id}/reaction",
            axum::routing::put(reactions::react_group),
        )
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
        .route("/groups/{group_id}/reads", get(groups::reads))
        .route(
            "/groups/{group_id}/pics",
            post(group_pics::upload).layer(DefaultBodyLimit::max(snap_limit)),
        )
        .route("/groups/{group_id}/pics/{pic_id}", get(group_pics::view))
        .route(
            "/groups/{group_id}/pics/{pic_id}/opened",
            post(group_pics::opened),
        )
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
        .route("/snaps/{id}/opened", post(snaps::opened))
        .route("/admin/stats", get(admin::stats))
        .route("/admin/metrics", get(metrics::get))
        .route("/admin/graph", get(graph::admin))
        .route("/admin/roles", get(roles::list))
        .route("/admin/roles/reload", post(roles::reload))
        .route(
            "/admin/roles/{user_id}",
            post(roles::grant).delete(roles::revoke),
        )
        .route("/graph", get(graph::mine))
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
        .route("/health", get(health::get))
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
        .layer(middleware::from_fn(guard::noindex))
        .layer(middleware::from_fn_with_state(state.clone(), guard::guard))
        .layer(middleware::from_fn_with_state(state.clone(), log_request))
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
    if let Err(e) = guard::check_write_room(&state, req.method()) {
        return e.into_response();
    }
    if req.method() != axum::http::Method::GET && !exempt {
        let slow_down = || {
            error::AppError::TooManyRequests(
                "Slow down a little and try again in a few minutes.".into(),
            )
            .into_response()
        };
        if let Some(who) = req.extensions().get::<ratelimit::ClientInfo>() {
            if !who.local && !state.write_limit.allow(&who.ip) {
                tracing::warn!(ip = %who.ip, "write rate limited");
                return slow_down();
            }
        }
        // Per session too, so many addresses can't multiply one account's budget.
        if let Some(token) = auth::bearer_token(req.headers()) {
            if !state.session_write_limit.allow(&auth::hash_token(token)) {
                tracing::warn!("write rate limited for a session");
                return slow_down();
            }
        }
    }
    next.run(req).await
}

/// One line per request: who (address, user agent), what (method, route
/// template, real path), and the outcome. Never the query string, other
/// headers, or the body. Also hands the caller's address to handlers.
async fn log_request(
    axum::extract::State(state): axum::extract::State<SharedState>,
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
    if !path.starts_with("/dev/") {
        state.metrics.record(status, started.elapsed());
    }
    // The log viewer polls every few seconds, and in development the page polls
    // /dev/changes; logging those would bury everything else.
    if (route == "/api/admin/logs" || path.starts_with("/dev/")) && status < 500 {
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

/// Reads the admin list from its SSM parameter at start, and again on SIGHUP
/// (`scripts/reload-admins.sh`). Without a parameter, FADE_ADMINS is the list.
async fn load_admins(state: SharedState) {
    if state.admins.has_param() {
        match state.admins.reload().await {
            Ok(count) => tracing::info!(admins = count, "admin list loaded"),
            Err(e) => {
                tracing::error!(error = %e, admins = state.admins.count(), "loading the admin list failed; using FADE_ADMINS only")
            }
        }
    }
    if state.admins.count() == 0 {
        tracing::info!("no admins set; the System pages are off for everyone but PowerUsers");
    }
    #[cfg(unix)]
    tokio::spawn(async move {
        let Ok(mut hup) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())
        else {
            return;
        };
        while hup.recv().await.is_some() {
            match state.admins.reload().await {
                Ok(count) => tracing::info!(admins = count, "admin list reloaded (SIGHUP)"),
                Err(e) => tracing::warn!(error = %e, "admin list reload failed (SIGHUP)"),
            }
        }
    });
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
