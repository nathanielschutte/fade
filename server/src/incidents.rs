//! Health monitor incidents on the Metrics tab (plan X18, Admins only;
//! docs/health-monitor.md).
//!
//! The monitor (infra/health) writes one JSON record per incident to the
//! artifacts bucket. Those records are the source of truth and are only read
//! here. "Mark resolved" writes a separate record (`resolutions/<id>.json`)
//! next to them, so the monitor's own record is never changed and nothing is
//! ever deleted.
//!
//! Only S3 keys built here are read or written: an incident id from a request
//! must look like the monitor's ("20261023T171000Z") before it names a key.

use std::collections::BTreeMap;
use std::sync::Mutex;

use axum::{
    extract::{Path, State},
    Json,
};
use serde_json::{json, Value};

use crate::{
    auth::AuthUser,
    aws::Aws,
    db::now,
    error::{AppError, AppResult},
    roles::Role,
    SharedState,
};

/// Incidents shown: opened, updated, or resolved in the last 7 days.
const WINDOW_SECS: i64 = 7 * 86_400;
/// S3 is read at most once a minute; marking one resolved reads afresh.
const CACHE_SECS: i64 = 60;
/// At most this many records are read per load.
const MAX_INCIDENTS: usize = 50;
/// The newest steps of a long incident.
const MAX_TIMELINE: usize = 100;

static CACHE: Mutex<Option<(i64, Value)>> = Mutex::new(None);

/// Where the records live: `health/` in production (the monitor's prefix).
/// Staging sets its own, so it never reads production's.
fn prefix() -> String {
    std::env::var("FADE_HEALTH_PREFIX").unwrap_or_else(|_| "health/".into())
}

fn bucket(aws: &Aws) -> Option<String> {
    aws.instance
        .s3_buckets()
        .into_iter()
        .find(|b| b.contains("-artifacts-"))
}

/// "20261023T171000Z": the monitor's ids, and the only ones that name a key.
fn valid_id(id: &str) -> bool {
    let b = id.as_bytes();
    b.len() == 16
        && b[8] == b'T'
        && b[15] == b'Z'
        && b[..8].iter().chain(&b[9..15]).all(u8::is_ascii_digit)
}

/// The id in a key like "health/incidents/20261023T171000Z.json".
fn id_of(key: &str) -> Option<&str> {
    let id = key.rsplit('/').next()?.strip_suffix(".json")?;
    valid_id(id).then_some(id)
}

/// Text from a record, shortened: it came from outside this server.
fn short(v: &Value, max: usize) -> Value {
    match v.as_str() {
        Some(s) => Value::String(s.chars().take(max).collect()),
        None => Value::Null,
    }
}

/// What the page shows for one incident: the monitor's record, without the
/// serial console, plus any resolution.
fn summarize(id: &str, record: &Value, resolution: Option<&Value>) -> Value {
    let status = record["status"].as_str().unwrap_or("open");
    let resolved =
        resolution.map(|r| json!({ "at": short(&r["at"], 40), "by": short(&r["by"], 40) }));
    let state = match (status, &resolved) {
        ("recovered", _) => "recovered",
        (_, Some(_)) => "resolved",
        ("needs_human", None) => "needs_human",
        _ => "open",
    };
    let entries = record["timeline"].as_array().cloned().unwrap_or_default();
    let skip = entries.len().saturating_sub(MAX_TIMELINE);
    let timeline: Vec<Value> = entries
        .iter()
        .skip(skip)
        .map(|e| {
            let action = &e["action"];
            json!({
                "at": short(&e["at"], 40),
                "note": short(&e["note"], 200),
                "healthy": e["probe"]["healthy"].as_bool(),
                "error": short(&e["probe"]["error"], 300),
                "instance": e["instance"].is_object().then(|| json!({
                    "state": short(&e["instance"]["state"], 20),
                    "system_status": short(&e["instance"]["system_status"], 20),
                    "instance_status": short(&e["instance"]["instance_status"], 20),
                    "ssm": short(&e["instance"]["ssm"], 20),
                })),
                "action": action.is_object().then(|| json!({
                    "step": action["step"].as_i64(),
                    "name": short(&action["name"], 60),
                    "result": short(&action["result"], 300),
                })),
            })
        })
        .collect();
    let steps = timeline.iter().filter(|e| !e["action"].is_null()).count();
    json!({
        "id": id,
        "opened_at": short(&record["opened_at"], 40),
        "closed_at": short(&record["closed_at"], 40),
        "status": status,
        "state": state,
        "resolved": resolved,
        "steps": steps,
        "timeline": timeline,
    })
}

/// Which records to read: (id, key) for those written in the window, or
/// whose resolution was, newest first.
fn in_window(
    records: &[(String, i64)],
    resolutions: &BTreeMap<String, i64>,
    since: i64,
) -> Vec<(String, String)> {
    let mut chosen: Vec<(String, String)> = records
        .iter()
        .filter_map(|(key, modified)| {
            let id = id_of(key)?;
            let recent = *modified >= since || resolutions.get(id).is_some_and(|t| *t >= since);
            recent.then(|| (id.to_owned(), key.clone()))
        })
        .collect();
    chosen.sort_by(|a, b| b.0.cmp(&a.0));
    chosen.truncate(MAX_INCIDENTS);
    chosen
}

async fn load(aws: &Aws, bucket: &str) -> anyhow::Result<Vec<Value>> {
    let p = prefix();
    let records = aws.s3_list(bucket, &format!("{p}incidents/")).await?;
    let resolutions: BTreeMap<String, i64> = aws
        .s3_list(bucket, &format!("{p}resolutions/"))
        .await?
        .into_iter()
        .filter_map(|(key, t)| Some((id_of(&key)?.to_owned(), t)))
        .collect();
    let mut out = Vec::new();
    for (id, key) in in_window(&records, &resolutions, now() - WINDOW_SECS) {
        let Some(text) = aws.s3_get(bucket, &key).await? else {
            continue;
        };
        let record: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let resolution = if resolutions.contains_key(&id) {
            aws.s3_get(bucket, &format!("{p}resolutions/{id}.json"))
                .await?
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        } else {
            None
        };
        out.push(summarize(&id, &record, resolution.as_ref()));
    }
    Ok(out)
}

/// `GET /api/admin/incidents`: the last 7 days of incidents. Admins only.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let Some((aws, bucket)) = state.metrics.aws().and_then(|a| Some((a, bucket(a)?))) else {
        // Development, or not on AWS: there's no monitor to read.
        return Ok(Json(json!({ "available": false, "incidents": [] })));
    };
    if let Some((at, cached)) = CACHE.lock().unwrap().clone() {
        if now() - at < CACHE_SECS {
            return Ok(Json(cached));
        }
    }
    let body = match load(aws, &bucket).await {
        Ok(incidents) => {
            json!({ "available": true, "window_days": WINDOW_SECS / 86_400, "incidents": incidents })
        }
        Err(e) => {
            tracing::warn!(error = %e, "reading incident records failed");
            json!({ "available": true, "incidents": [], "error": "Couldn't read the health monitor's records. Try again in a minute; the server log has the reason." })
        }
    };
    *CACHE.lock().unwrap() = Some((now(), body.clone()));
    Ok(Json(body))
}

/// `POST /api/admin/incidents/{id}/resolve`: an Admin marks an incident
/// resolved. Writes a resolution beside the monitor's record; marking one
/// that's already resolved changes nothing.
pub async fn resolve(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    if !valid_id(&id) {
        return Err(AppError::bad("That isn't an incident."));
    }
    let Some((aws, bucket)) = state.metrics.aws().and_then(|a| Some((a, bucket(a)?))) else {
        return Err(AppError::bad("There's no health monitor here."));
    };
    let p = prefix();
    let failed = |e: anyhow::Error| {
        tracing::warn!(error = %e, incident = %id, "marking an incident resolved failed");
        AppError::Unavailable("Couldn't save that. Try again in a minute.".into())
    };
    if aws
        .s3_get(&bucket, &format!("{p}incidents/{id}.json"))
        .await
        .map_err(failed)?
        .is_none()
    {
        return Err(AppError::not_found("There's no such incident."));
    }
    let key = format!("{p}resolutions/{id}.json");
    if let Some(existing) = aws.s3_get(&bucket, &key).await.map_err(failed)? {
        return Ok(Json(serde_json::from_str(&existing).unwrap_or(Value::Null)));
    }
    let resolution =
        json!({ "id": id, "at": crate::aws::iso(now()), "by": me.username, "by_id": me.id });
    aws.s3_put_json(&bucket, &key, &resolution)
        .await
        .map_err(failed)?;
    *CACHE.lock().unwrap() = None;
    tracing::info!(user_id = me.id, incident = %id, "incident marked resolved");
    Ok(Json(resolution))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_monitor_ids_name_keys() {
        assert!(valid_id("20261023T171000Z"));
        for bad in [
            "",
            "20261023T171000",
            "2026102xT171000Z",
            "../../secret.json",
            "20261023T171000Z/../x",
            "20261023t171000Z",
        ] {
            assert!(!valid_id(bad), "{bad}");
        }
        assert_eq!(
            id_of("health/incidents/20261023T171000Z.json"),
            Some("20261023T171000Z")
        );
        assert_eq!(id_of("health/incidents/notes.json"), None);
        assert_eq!(id_of("health/incidents/20261023T171000Z.txt"), None);
    }

    #[test]
    fn the_last_seven_days() {
        let since = 1_000_000;
        let records = vec![
            (
                "health/incidents/20261001T000000Z.json".to_owned(),
                since - 10,
            ), // old
            (
                "health/incidents/20261002T000000Z.json".to_owned(),
                since - 10,
            ), // old, resolved lately
            (
                "health/incidents/20261020T000000Z.json".to_owned(),
                since + 10,
            ),
            (
                "health/incidents/20261022T000000Z.json".to_owned(),
                since + 99,
            ),
            ("health/incidents/junk.json".to_owned(), since + 99),
        ];
        let resolutions = BTreeMap::from([("20261002T000000Z".to_owned(), since + 5)]);
        let ids: Vec<String> = in_window(&records, &resolutions, since)
            .into_iter()
            .map(|(id, _)| id)
            .collect();
        assert_eq!(
            ids,
            ["20261022T000000Z", "20261020T000000Z", "20261002T000000Z"]
        );
    }

    #[test]
    fn summaries_leave_out_the_console() {
        let record = json!({
            "id": "20261023T171000Z", "opened_at": "2026-10-23T17:10:00Z", "status": "open",
            "timeline": [
                { "at": "2026-10-23T17:05:00Z", "probe": { "healthy": false, "error": "timeout after 10s" }, "note": "failure 1 of 2 before acting" },
                { "at": "2026-10-23T17:10:00Z", "probe": { "healthy": false, "error": "timeout after 10s" },
                  "instance": { "state": "running", "system_status": "ok", "instance_status": "impaired", "ssm": "ConnectionLost" },
                  "console_tail": "kernel: something private-ish",
                  "action": { "step": 2, "name": "reboot", "result": "requested" } },
            ],
        });
        let s = summarize("20261023T171000Z", &record, None);
        assert_eq!(
            (s["state"].as_str(), s["steps"].as_u64()),
            (Some("open"), Some(1))
        );
        assert_eq!(s["timeline"][1]["action"]["name"], "reboot");
        assert_eq!(s["timeline"][1]["instance"]["instance_status"], "impaired");
        assert!(!s.to_string().contains("kernel"), "no console output");

        let marked = json!({ "at": "2026-10-23T18:00:00Z", "by": "nate" });
        let s = summarize("20261023T171000Z", &record, Some(&marked));
        assert_eq!(
            (s["state"].as_str(), s["resolved"]["by"].as_str()),
            (Some("resolved"), Some("nate"))
        );
        let recovered =
            json!({ "status": "recovered", "closed_at": "2026-10-23T17:20:00Z", "timeline": [] });
        assert_eq!(
            summarize("20261023T171000Z", &recovered, Some(&marked))["state"],
            "recovered"
        );
        let human = json!({ "status": "needs_human", "timeline": [] });
        assert_eq!(
            summarize("20261023T171000Z", &human, None)["state"],
            "needs_human"
        );
    }
}
