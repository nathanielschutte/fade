//! Announcements (docs/implementation/admin-users.md): a short message from
//! the Admins that everyone signed in sees as a banner, live, until it ends
//! or is withdrawn ("napsack moved to napsack.io: your saved password is
//! under the old name"). One at a time; posting a new one withdraws the last.
//!
//! Plain text the server stores and shows to others, so it's checked like
//! other such text (text.rs) and shown with textContent.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    db::now,
    error::{AppError, AppResult},
    roles::Role,
    ws::Event,
    SharedState,
};

const MAX_CHARS: usize = 280;
/// How long one may run: an hour to two weeks.
const MIN_HOURS: i64 = 1;
const MAX_HOURS: i64 = 24 * 14;

#[derive(Serialize, Clone, Debug, sqlx::FromRow)]
pub struct Announcement {
    pub id: i64,
    pub body: String,
    pub created_at: i64,
    pub ends_at: i64,
}

/// The one showing now, if any.
pub async fn current(db: &SqlitePool) -> sqlx::Result<Option<Announcement>> {
    sqlx::query_as(
        "SELECT id, body, created_at, ends_at FROM announcements
         WHERE withdrawn_at IS NULL AND ends_at > ? ORDER BY created_at DESC LIMIT 1",
    )
    .bind(now())
    .fetch_optional(db)
    .await
}

/// `GET /api/announcement`: the current announcement, or null. Signed in.
pub async fn get(
    State(state): State<SharedState>,
    AuthUser(_me): AuthUser,
) -> AppResult<Json<Value>> {
    Ok(Json(json!({ "announcement": current(&state.db).await? })))
}

#[derive(Deserialize)]
pub struct Post {
    body: String,
    hours: i64,
}

/// Withdraws whatever is showing (`by` an Admin). Returns how many it ended.
async fn withdraw_current(db: &SqlitePool, by: i64) -> sqlx::Result<u64> {
    Ok(sqlx::query(
        "UPDATE announcements SET withdrawn_by = ?, withdrawn_at = ?
         WHERE withdrawn_at IS NULL AND ends_at > ?",
    )
    .bind(by)
    .bind(now())
    .bind(now())
    .execute(db)
    .await?
    .rows_affected())
}

/// `POST /api/admin/announcements` `{body, hours}`: Admins only.
pub async fn post(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<Post>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let body = req.body.trim();
    if body.is_empty() {
        return Err(AppError::bad("Write something to announce."));
    }
    if body.chars().count() > MAX_CHARS {
        return Err(AppError::bad(format!(
            "Keep it under {MAX_CHARS} characters."
        )));
    }
    crate::text::check_name(body).map_err(|_| AppError::bad("Announcements can't contain invisible or direction-changing characters, or line breaks."))?;
    if !(MIN_HOURS..=MAX_HOURS).contains(&req.hours) {
        return Err(AppError::bad("Show it for between an hour and two weeks."));
    }
    withdraw_current(&state.db, me.id).await?;
    let at = now();
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO announcements (body, created_by, created_at, ends_at) VALUES (?, ?, ?, ?) RETURNING id",
    )
    .bind(body)
    .bind(me.id)
    .bind(at)
    .bind(at + req.hours * 3600)
    .fetch_one(&state.db)
    .await?;
    crate::admin_users::record(
        &state.db,
        me.id,
        "announce",
        None,
        json!({ "announcement_id": id, "hours": req.hours }),
    )
    .await?;
    let now_showing = current(&state.db).await?;
    state.hub.send_all(&Event::Announcement {
        announcement: now_showing.clone(),
    });
    tracing::info!(
        admin_id = me.id,
        announcement_id = id,
        hours = req.hours,
        "announcement posted"
    );
    Ok(Json(json!({ "announcement": now_showing })))
}

/// `POST /api/admin/announcements/{id}/withdraw`: Admins only.
pub async fn withdraw(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let done = sqlx::query(
        "UPDATE announcements SET withdrawn_by = ?, withdrawn_at = ? WHERE id = ? AND withdrawn_at IS NULL",
    )
    .bind(me.id)
    .bind(now())
    .bind(id)
    .execute(&state.db)
    .await?
    .rows_affected();
    if done == 0 {
        return Err(AppError::not_found("That announcement isn't showing."));
    }
    crate::admin_users::record(
        &state.db,
        me.id,
        "withdraw_announcement",
        None,
        json!({ "announcement_id": id }),
    )
    .await?;
    state.hub.send_all(&Event::Announcement {
        announcement: current(&state.db).await?,
    });
    tracing::info!(
        admin_id = me.id,
        announcement_id = id,
        "announcement withdrawn"
    );
    Ok(Json(json!({ "withdrawn": true })))
}

/// `GET /api/admin/announcements`: the last 20, for the System page. Admins only.
pub async fn recent(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let rows: Vec<(i64, String, String, i64, i64, Option<i64>)> = sqlx::query_as(
        "SELECT a.id, a.body, u.username, a.created_at, a.ends_at, a.withdrawn_at
         FROM announcements a JOIN users u ON u.id = a.created_by
         ORDER BY a.created_at DESC LIMIT 20",
    )
    .fetch_all(&state.db)
    .await?;
    let at = now();
    Ok(Json(json!({
        "announcements": rows.iter().map(|(id, body, by, created, ends, withdrawn)| json!({
            "id": id, "body": body, "by": by, "created_at": created, "ends_at": ends,
            "withdrawn_at": withdrawn, "showing": withdrawn.is_none() && *ends > at,
        })).collect::<Vec<_>>(),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[tokio::test]
    async fn one_at_a_time_and_they_end() {
        let db = temp_db().await;
        sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (1, 'admin', 'h', 'k', 'w', 0)")
            .execute(&db).await.unwrap();
        assert!(current(&db).await.unwrap().is_none());
        let t = now();
        sqlx::query("INSERT INTO announcements (body, created_by, created_at, ends_at) VALUES ('old', 1, ?, ?), ('gone', 1, ?, ?)")
            .bind(t - 10).bind(t + 3600).bind(t - 7200).bind(t - 3600)
            .execute(&db).await.unwrap();
        assert_eq!(current(&db).await.unwrap().unwrap().body, "old");
        assert_eq!(
            withdraw_current(&db, 1).await.unwrap(),
            1,
            "only the one still showing"
        );
        assert!(current(&db).await.unwrap().is_none());
        let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM announcements")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(n, 2, "withdrawn, never deleted");
    }
}
