//! `GET /api/health` (docs/health-monitor.md): whether this server can do its
//! job, for the outside monitor. Public, and says nothing private: whether
//! the database answers and the data disk has room, plus what's running and
//! the server's clock (the monitor checks it's current, so a stale cache or
//! the wrong server can't pass).

use std::time::Duration;

use axum::{extract::State, http::StatusCode, Json};
use serde_json::{json, Value};

use crate::{db::now, version, SharedState};

/// The database has this long to answer.
const DB_TIMEOUT: Duration = Duration::from_secs(2);

pub async fn get(State(state): State<SharedState>) -> (StatusCode, Json<Value>) {
    let database = match tokio::time::timeout(
        DB_TIMEOUT,
        sqlx::query_scalar::<_, i64>("SELECT 1").fetch_one(&state.db),
    )
    .await
    {
        Ok(Ok(1)) => "ok",
        Ok(_) => "error",
        Err(_) => "slow",
    };
    let disk = match crate::guard::disk_free(&state) {
        Some(free) if free < crate::guard::WRITE_FLOOR_BYTES => "full",
        _ => "ok",
    };
    let ok = database == "ok" && disk == "ok";
    if !ok {
        tracing::warn!(database, disk, "health check failing");
    }
    let body = json!({
        "ok": ok,
        "checks": { "database": database, "disk": disk },
        "version": version::SERVER_VERSION,
        "build": version::BUILD,
        "time": now(),
        "uptime_secs": state.started_at.elapsed().as_secs(),
    });
    let status = if ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (status, Json(body))
}
