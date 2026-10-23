//! The System page's overview (docs/implementation/roles.md): PowerUsers and
//! Admins; the users table for Admins only. Counts and timestamps only: nothing here reads message ciphertext, keys, or anything a user wrote.

use axum::{extract::State, Json};
use serde::Serialize;
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{auth::AuthUser, db::now, error::AppResult, version, SharedState};

const DAY: i64 = 86_400;
const CHART_DAYS: i64 = 14;

#[derive(Serialize, FromRow)]
struct UserRow {
    id: i64,
    username: String,
    created_at: i64,
    last_seen_at: Option<i64>,
    friends: i64,
    texts_sent: i64,
    snaps_sent: i64,
}

#[derive(Serialize)]
struct Day {
    /// Start of the day, UTC, in Unix seconds.
    day: i64,
    texts: i64,
    snaps: i64,
    signups: i64,
}

async fn count(db: &SqlitePool, sql: &str, binds: &[i64]) -> sqlx::Result<i64> {
    let mut q = sqlx::query_scalar::<_, i64>(sql);
    for b in binds {
        q = q.bind(*b);
    }
    q.fetch_one(db).await
}

/// Per-day counts for the last CHART_DAYS days, zero-filled.
async fn daily(db: &SqlitePool, at: i64) -> sqlx::Result<Vec<Day>> {
    let first = (at / DAY - (CHART_DAYS - 1)) * DAY;
    let msgs: Vec<(i64, i64, i64)> = sqlx::query_as(
        "SELECT created_at / 86400, SUM(kind = 'text'), SUM(kind = 'snap')
         FROM messages WHERE created_at >= ? GROUP BY 1",
    )
    .bind(first)
    .fetch_all(db)
    .await?;
    let signups: Vec<(i64, i64)> = sqlx::query_as(
        "SELECT created_at / 86400, COUNT(*) FROM users WHERE created_at >= ? GROUP BY 1",
    )
    .bind(first)
    .fetch_all(db)
    .await?;

    Ok((0..CHART_DAYS)
        .map(|i| {
            let d = first / DAY + i;
            let (texts, snaps) = msgs
                .iter()
                .find(|m| m.0 == d)
                .map(|m| (m.1, m.2))
                .unwrap_or((0, 0));
            let signups = signups.iter().find(|s| s.0 == d).map(|s| s.1).unwrap_or(0);
            Day {
                day: d * DAY,
                texts,
                snaps,
                signups,
            }
        })
        .collect())
}

/// The backup job's last result, or null if it hasn't run (or this isn't production).
fn backup_status(path: &str) -> Value {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .filter(Value::is_object)
        .unwrap_or(Value::Null)
}

pub async fn stats(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    // PowerUsers and Admins (roles.md); 404 for anyone else, so the panel
    // doesn't confirm it exists. PowerUsers get no users table: it names
    // people and holds the reset tool.
    let role = crate::roles::require(&state, &me, crate::roles::Role::Power).await?;
    let admin = role == crate::roles::Role::Admin;
    let db = &state.db;
    let at = now();
    let (day_ago, week_ago) = (at - DAY, at - 7 * DAY);

    let users = if !admin {
        Vec::new()
    } else {
        sqlx::query_as::<_, UserRow>(
        "SELECT u.id, u.username, u.created_at, u.last_seen_at,
            (SELECT COUNT(*) FROM friendships f
              WHERE (f.user_lo = u.id OR f.user_hi = u.id) AND f.ended_at IS NULL) AS friends,
            (SELECT COUNT(*) FROM messages m WHERE m.sender_id = u.id AND m.kind = 'text') AS texts_sent,
            (SELECT COUNT(*) FROM messages m WHERE m.sender_id = u.id AND m.kind = 'snap') AS snaps_sent
         FROM users u ORDER BY u.created_at DESC LIMIT 500",
    )
    .fetch_all(db)
    .await?
    };

    let (online_users, sockets) = state.hub.online();
    let (snaps_held, snap_bytes) = crate::snaps::usage(db).await?;
    let db_bytes = count(
        db,
        "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()",
        &[],
    )
    .await?;

    Ok(Json(json!({
        "generated_at": at,
        "users": {
            "total": count(db, "SELECT COUNT(*) FROM users", &[]).await?,
            "new_24h": count(db, "SELECT COUNT(*) FROM users WHERE created_at >= ?", &[day_ago]).await?,
            "new_7d": count(db, "SELECT COUNT(*) FROM users WHERE created_at >= ?", &[week_ago]).await?,
            "active_24h": count(db, "SELECT COUNT(*) FROM users WHERE last_seen_at >= ?", &[day_ago]).await?,
            "active_7d": count(db, "SELECT COUNT(*) FROM users WHERE last_seen_at >= ?", &[week_ago]).await?,
            "online": online_users,
            "sockets": sockets,
            "list": if admin { Some(users) } else { None },
        },
        "messages": {
            "texts": count(db, "SELECT COUNT(*) FROM messages WHERE kind = 'text'", &[]).await?,
            "snaps": count(db, "SELECT COUNT(*) FROM messages WHERE kind = 'snap'", &[]).await?,
            "texts_24h": count(db, "SELECT COUNT(*) FROM messages WHERE kind = 'text' AND created_at >= ?", &[day_ago]).await?,
            "snaps_24h": count(db, "SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND created_at >= ?", &[day_ago]).await?,
            "snaps_pending": count(db, "SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND snap_state = 'pending'", &[]).await?,
            "snaps_opened": count(db, "SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND snap_state = 'opened'", &[]).await?,
            "snaps_expired": count(db, "SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND snap_state = 'expired'", &[]).await?,
            "daily": daily(db, at).await?,
        },
        "social": {
            "friendships": count(db, "SELECT COUNT(*) FROM friendships WHERE ended_at IS NULL", &[]).await?,
            "ended_friendships": count(db, "SELECT COUNT(*) FROM friendships WHERE ended_at IS NOT NULL", &[]).await?,
            "pending_requests": count(db, "SELECT COUNT(*) FROM friend_requests WHERE resolved_at IS NULL", &[]).await?,
            "groups": count(db, "SELECT COUNT(*) FROM groups", &[]).await?,
            "group_messages": count(db, "SELECT COUNT(*) FROM group_messages WHERE kind = 'text'", &[]).await?,
            "active_sessions": count(db, "SELECT COUNT(*) FROM sessions WHERE expires_at > ? AND revoked_at IS NULL", &[at]).await?,
        },
        "server": {
            "version": version::SERVER_VERSION,
            "build": version::BUILD,
            "uptime_secs": state.started_at.elapsed().as_secs(),
            "db_bytes": db_bytes,
            "snaps_waiting": snaps_held,
            "snap_bytes_waiting": snap_bytes,
            "snap_disk_bytes": state.config.snap_disk_bytes,
            "snap_ttl_hours": state.config.snap_ttl.as_secs() / 3600,
            "invite_required": state.config.invite_code.is_some(),
            "backup": backup_status(&state.config.backup_status_path),
            "group_pics_pending": crate::group_pics::pending(db).await?.0,
            "group_pic_bytes": crate::group_pics::pending(db).await?.1,
            "group_pic_disk_bytes": state.config.group_pic_disk_bytes,
            "resources": crate::sysinfo::snapshot(&state.config.pic_dir),
            "protection": {
                "accounts_max": state.config.limits.max_accounts,
                "sessions_per_user_max": state.config.limits.max_sessions,
                "banned_addresses": state.bans.banned_count(),
                "refused_since_start": state.bans.refused.load(std::sync::atomic::Ordering::Relaxed),
            },
        },
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[test]
    fn backup_status_reads_the_job_file() {
        let path = std::env::temp_dir().join(format!("fade-backup-{}.json", rand::random::<u64>()));
        let p = path.to_str().unwrap();
        assert!(backup_status(p).is_null()); // never ran
        std::fs::write(&path, r#"{"ok": true, "at": 5, "bytes": 10}"#).unwrap();
        assert_eq!(backup_status(p)["bytes"], 10);
        std::fs::write(&path, "half a write").unwrap();
        assert!(backup_status(p).is_null());
        std::fs::remove_file(&path).unwrap();
    }

    #[tokio::test]
    async fn daily_counts_are_zero_filled_and_bucketed_by_utc_day() {
        let db = temp_db().await;
        let today = 20_000 * DAY + 3_600; // 01:00 UTC on some day
        for (id, created) in [(1, today - 2 * DAY), (2, today)] {
            sqlx::query(
                "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at)
                 VALUES (?, ?, 'h', 'k', 'w', ?)",
            )
            .bind(id)
            .bind(format!("u{id}"))
            .bind(created)
            .execute(&db)
            .await
            .unwrap();
        }
        for (kind, created) in [
            ("text", today),
            ("text", today - 60),
            ("snap", today - DAY),
            ("text", today - 30 * DAY),
        ] {
            sqlx::query(
                "INSERT INTO messages (sender_id, recipient_id, kind, created_at) VALUES (1, 2, ?, ?)",
            )
            .bind(kind)
            .bind(created)
            .execute(&db)
            .await
            .unwrap();
        }

        let days = daily(&db, today).await.unwrap();
        assert_eq!(days.len(), CHART_DAYS as usize);
        let last = &days[13];
        assert_eq!(
            (last.day, last.texts, last.snaps, last.signups),
            (20_000 * DAY, 2, 0, 1)
        );
        assert_eq!((days[12].texts, days[12].snaps), (0, 1));
        assert_eq!(days[11].signups, 1);
        // 30 days ago is outside the window; everything else in it is zero.
        let total: i64 = days.iter().map(|d| d.texts + d.snaps).sum();
        assert_eq!(total, 3);
    }
}
