//! System → Users (Admins only; docs/implementation/admin-users.md): every
//! account, one person's account at a glance, and what an Admin can do about
//! it: turn it off (and back on), sign it out everywhere, clear a sign-in
//! lock. Reset codes live in account.rs.
//!
//! Turning an account off never deletes anything (Rule 1). It adds a row to
//! `deactivations`; the person can't sign in, their sessions end, friends
//! can't send to them, and nothing reaches their devices. Their history stays
//! where it is, for them and for their friends. Turning it back on marks that
//! row ended. Every Admin action is recorded in `admin_actions`.
//!
//! Counts and dates only: nothing here reads a message, a key, or a profile.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    db::{now, UserPublic},
    error::{AppError, AppResult},
    roles::Role,
    ws::Event,
    SharedState,
};

/// The reason an Admin gives for turning an account off, at most this long.
const MAX_REASON_CHARS: usize = 200;

/// (id, reason, turned off by, at, turned back on by, at)
type DeactivationRow = (
    i64,
    Option<String>,
    String,
    i64,
    Option<String>,
    Option<i64>,
);
/// (admin, action, target id, target username, detail JSON, at)
type ActionRow = (
    String,
    String,
    Option<i64>,
    Option<String>,
    Option<String>,
    i64,
);

/// Whether `user`'s account is turned off now.
pub async fn is_deactivated(db: &SqlitePool, user: i64) -> sqlx::Result<bool> {
    sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM deactivations WHERE user_id = ? AND reactivated_at IS NULL)",
    )
    .bind(user)
    .fetch_one(db)
    .await
}

/// Records an Admin's action on an account (append-only).
pub async fn record(
    db: &SqlitePool,
    admin: i64,
    action: &str,
    target: Option<i64>,
    detail: Value,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO admin_actions (admin_id, action, target_user_id, detail, created_at)
         VALUES (?, ?, ?, ?, ?)",
    )
    .bind(admin)
    .bind(action)
    .bind(target)
    .bind(detail.to_string())
    .bind(now())
    .execute(db)
    .await?;
    Ok(())
}

async fn target(db: &SqlitePool, id: i64) -> AppResult<UserPublic> {
    sqlx::query_as::<_, UserPublic>("SELECT id, username FROM users WHERE id = ?")
        .bind(id)
        .fetch_optional(db)
        .await?
        .ok_or_else(|| AppError::not_found("No such account."))
}

/// An account a person uses: not one the server speaks for (Team Napsack),
/// which has no sessions, sign-in, or password to act on.
async fn person(db: &SqlitePool, id: i64) -> AppResult<UserPublic> {
    let user = target(db, id).await?;
    if crate::team::is_system(db, id).await? {
        return Err(AppError::bad(
            "That's napsack's own account: there's nothing to do to it here.",
        ));
    }
    Ok(user)
}

/// Friends see the account turned off or on in their chat list at once.
async fn tell_friends(state: &SharedState, user: i64) -> sqlx::Result<()> {
    let friends = crate::roles::friend_ids(&state.db, user).await?;
    state.hub.send_many(&friends, &Event::FriendsChanged);
    Ok(())
}

// ---------- the list ----------

#[derive(Serialize, sqlx::FromRow)]
struct Row {
    id: i64,
    username: String,
    created_at: i64,
    last_seen_at: Option<i64>,
    friends: i64,
    texts_sent: i64,
    snaps_sent: i64,
    deactivated: bool,
}

/// `GET /api/admin/users`: every account, newest first. Admins only.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let rows = sqlx::query_as::<_, Row>(
        "SELECT u.id, u.username, u.created_at, u.last_seen_at,
            (SELECT COUNT(*) FROM friendships f
              WHERE (f.user_lo = u.id OR f.user_hi = u.id) AND f.ended_at IS NULL) AS friends,
            (SELECT COUNT(*) FROM messages m WHERE m.sender_id = u.id AND m.kind = 'text') AS texts_sent,
            (SELECT COUNT(*) FROM messages m WHERE m.sender_id = u.id AND m.kind = 'snap') AS snaps_sent,
            EXISTS(SELECT 1 FROM deactivations d WHERE d.user_id = u.id AND d.reactivated_at IS NULL) AS deactivated
         FROM users u ORDER BY u.created_at DESC",
    )
    .fetch_all(&state.db)
    .await?;
    let mut out = Vec::with_capacity(rows.len());
    for r in rows {
        let role = crate::roles::role_of(
            &state,
            &UserPublic {
                id: r.id,
                username: r.username.clone(),
            },
        )
        .await?;
        let online = state.hub.is_online(r.id);
        let mut v = serde_json::to_value(&r).unwrap_or(Value::Null);
        // Team Napsack (team.rs) is napsack's own account, not a person's.
        v["role"] = if crate::team::is_system(&state.db, r.id).await? {
            json!("system")
        } else {
            json!(role)
        };
        v["online"] = json!(online);
        out.push(v);
    }
    let active = out.iter().filter(|u| u["deactivated"] == false).count();
    Ok(Json(json!({
        "users": out,
        "active": active,
        "accounts_max": state.config.limits.max_accounts,
    })))
}

// ---------- one account ----------

async fn scalar(db: &SqlitePool, sql: &str, user: i64) -> sqlx::Result<i64> {
    // Every query here binds the user id once per `?`.
    let mut q = sqlx::query_scalar::<_, i64>(sql);
    for _ in 0..sql.matches('?').count() {
        q = q.bind(user);
    }
    q.fetch_one(db).await
}

/// `GET /api/admin/users/{id}`: one account at a glance. Admins only.
pub async fn detail(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let user = target(&state.db, id).await?;
    let db = &state.db;
    let at = now();
    let (created_at, last_seen_at, recovery_set_at, key_reset_at): (
        i64,
        Option<i64>,
        Option<i64>,
        Option<i64>,
    ) = sqlx::query_as(
        "SELECT created_at, last_seen_at, recovery_set_at, key_reset_at FROM users WHERE id = ?",
    )
    .bind(id)
    .fetch_one(db)
    .await?;
    let sessions: Vec<(i64, i64)> = sqlx::query_as(
        "SELECT created_at, expires_at FROM sessions
         WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY created_at DESC",
    )
    .bind(id)
    .bind(at)
    .fetch_all(db)
    .await?;
    let history: Vec<DeactivationRow> = sqlx::query_as(
        "SELECT d.id, d.reason, a.username, d.deactivated_at, b.username, d.reactivated_at
         FROM deactivations d JOIN users a ON a.id = d.deactivated_by
         LEFT JOIN users b ON b.id = d.reactivated_by
         WHERE d.user_id = ? ORDER BY d.deactivated_at DESC",
    )
    .bind(id)
    .fetch_all(db)
    .await?;
    let actions: Vec<(String, String, Option<String>, i64)> = sqlx::query_as(
        "SELECT a.username, x.action, x.detail, x.created_at
         FROM admin_actions x JOIN users a ON a.id = x.admin_id
         WHERE x.target_user_id = ? ORDER BY x.created_at DESC, x.id DESC LIMIT 50",
    )
    .bind(id)
    .fetch_all(db)
    .await?;
    let account = user.username.to_lowercase();
    let failed = state.login_fail_limit.used(&account);
    let role = if crate::team::is_system(db, id).await? {
        json!("system")
    } else {
        json!(crate::roles::role_of(&state, &user).await?)
    };

    Ok(Json(json!({
        "id": user.id,
        "username": user.username,
        "role": role,
        "created_at": created_at,
        "last_seen_at": last_seen_at,
        "online": state.hub.is_online(id),
        "recovery_key": recovery_set_at.is_some(),
        "key_reset_at": key_reset_at,
        "deactivated": history.iter().any(|h| h.5.is_none()),
        "counts": {
            "friends": scalar(db, "SELECT COUNT(*) FROM friendships WHERE (user_lo = ? OR user_hi = ?) AND ended_at IS NULL", id).await?,
            "groups": scalar(db, "SELECT COUNT(*) FROM group_members WHERE user_id = ? AND left_at IS NULL", id).await?,
            "texts_sent": scalar(db, "SELECT COUNT(*) FROM messages WHERE sender_id = ? AND kind = 'text'", id).await?,
            "pics_sent": scalar(db, "SELECT COUNT(*) FROM messages WHERE sender_id = ? AND kind = 'snap'", id).await?,
            "group_messages_sent": scalar(db, "SELECT COUNT(*) FROM group_messages WHERE sender_id = ? AND kind = 'text'", id).await?,
            "invites_made": scalar(db, "SELECT COUNT(*) FROM invites WHERE created_by = ?", id).await?,
            "notification_devices": scalar(db, "SELECT COUNT(*) FROM push_subscriptions WHERE user_id = ? AND ended_at IS NULL", id).await?,
        },
        "sessions": sessions.iter().map(|(c, e)| json!({ "created_at": c, "expires_at": e })).collect::<Vec<_>>(),
        "sign_in": {
            "failures": failed,
            "limit": state.login_fail_limit.limit(),
            "locked": state.login_fail_limit.exhausted(&account),
        },
        "deactivations": history.iter().map(|(_, reason, by, at, back_by, back_at)| json!({
            "reason": reason, "by": by, "at": at, "reactivated_by": back_by, "reactivated_at": back_at,
        })).collect::<Vec<_>>(),
        "actions": actions.iter().map(|(by, action, detail, at)| json!({
            "by": by, "action": action, "at": at,
            "detail": detail.as_deref().and_then(|d| serde_json::from_str::<Value>(d).ok()),
        })).collect::<Vec<_>>(),
    })))
}

// ---------- actions ----------

#[derive(Deserialize)]
pub struct Deactivate {
    reason: Option<String>,
}

/// `POST /api/admin/users/{id}/deactivate` `{reason}`: turns an account off.
pub async fn deactivate(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
    Json(req): Json<Deactivate>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let user = person(&state.db, id).await?;
    if user.id == me.id {
        return Err(AppError::bad("You can't turn off your own account."));
    }
    if state.admins.contains(&user.username) {
        return Err(AppError::bad(
            "Admins come from settings: remove them from the admin list first.",
        ));
    }
    let reason = req
        .reason
        .map(|r| r.trim().to_owned())
        .filter(|r| !r.is_empty());
    if let Some(r) = &reason {
        if r.chars().count() > MAX_REASON_CHARS {
            return Err(AppError::bad(format!(
                "Keep the reason under {MAX_REASON_CHARS} characters."
            )));
        }
        crate::text::check_name(r).map_err(AppError::bad)?;
    }
    let inserted = sqlx::query(
        "INSERT INTO deactivations (user_id, reason, deactivated_by, deactivated_at) VALUES (?, ?, ?, ?)",
    )
    .bind(id)
    .bind(&reason)
    .bind(me.id)
    .bind(now())
    .execute(&state.db)
    .await;
    match inserted {
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            return Err(AppError::Conflict(
                "That account is already turned off.".into(),
            ));
        }
        other => {
            other?;
        }
    }
    let ended = crate::account::end_sessions(&state, id, None).await?;
    record(
        &state.db,
        me.id,
        "deactivate",
        Some(id),
        json!({ "sessions_ended": ended, "reason_given": reason.is_some() }),
    )
    .await?;
    tell_friends(&state, id).await?;
    tracing::info!(
        admin_id = me.id,
        user_id = id,
        sessions_ended = ended,
        "account turned off"
    );
    Ok(Json(
        json!({ "deactivated": true, "sessions_ended": ended }),
    ))
}

/// `POST /api/admin/users/{id}/reactivate`: turns an account back on.
pub async fn reactivate(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    person(&state.db, id).await?;
    let done = sqlx::query(
        "UPDATE deactivations SET reactivated_by = ?, reactivated_at = ?
         WHERE user_id = ? AND reactivated_at IS NULL",
    )
    .bind(me.id)
    .bind(now())
    .bind(id)
    .execute(&state.db)
    .await?
    .rows_affected();
    if done == 0 {
        return Err(AppError::Conflict("That account isn't turned off.".into()));
    }
    record(&state.db, me.id, "reactivate", Some(id), json!({})).await?;
    tell_friends(&state, id).await?;
    tracing::info!(admin_id = me.id, user_id = id, "account turned back on");
    Ok(Json(json!({ "deactivated": false })))
}

/// `POST /api/admin/users/{id}/sign-out`: ends every session (a lost phone).
pub async fn sign_out(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    person(&state.db, id).await?;
    if id == me.id {
        return Err(AppError::bad(
            "To sign yourself out elsewhere, use your profile.",
        ));
    }
    let ended = crate::account::end_sessions(&state, id, None).await?;
    record(
        &state.db,
        me.id,
        "sign_out",
        Some(id),
        json!({ "sessions_ended": ended }),
    )
    .await?;
    tracing::info!(
        admin_id = me.id,
        user_id = id,
        sessions_ended = ended,
        "signed out everywhere by an admin"
    );
    Ok(Json(json!({ "sessions_ended": ended })))
}

/// `POST /api/admin/users/{id}/unlock`: clears a sign-in lock from too many
/// wrong passwords, so the person can try again at once.
pub async fn unlock(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let user = person(&state.db, id).await?;
    let account = user.username.to_lowercase();
    let failures = state.login_fail_limit.used(&account);
    state.login_fail_limit.clear(&account);
    record(
        &state.db,
        me.id,
        "unlock",
        Some(id),
        json!({ "failures_cleared": failures }),
    )
    .await?;
    tracing::info!(
        admin_id = me.id,
        user_id = id,
        failures,
        "sign-in lock cleared by an admin"
    );
    Ok(Json(json!({ "failures_cleared": failures })))
}

/// `GET /api/admin/actions`: the newest 100 Admin actions, for the feed.
pub async fn actions(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let rows: Vec<ActionRow> = sqlx::query_as(
        "SELECT a.username, x.action, x.target_user_id, t.username, x.detail, x.created_at
         FROM admin_actions x JOIN users a ON a.id = x.admin_id
         LEFT JOIN users t ON t.id = x.target_user_id
         ORDER BY x.created_at DESC, x.id DESC LIMIT 100",
    )
    .fetch_all(&state.db)
    .await?;
    Ok(Json(json!({
        "actions": rows.iter().map(|(by, action, target_id, target, detail, at)| json!({
            "by": by, "action": action, "target_id": target_id, "target": target, "at": at,
            "detail": detail.as_deref().and_then(|d| serde_json::from_str::<Value>(d).ok()),
        })).collect::<Vec<_>>(),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[tokio::test]
    async fn turning_off_and_on_keeps_history() {
        let db = temp_db().await;
        for (id, name) in [(1, "admin"), (2, "ana")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        assert!(!is_deactivated(&db, 2).await.unwrap());
        sqlx::query(
            "INSERT INTO deactivations (user_id, deactivated_by, deactivated_at) VALUES (2, 1, 10)",
        )
        .execute(&db)
        .await
        .unwrap();
        assert!(is_deactivated(&db, 2).await.unwrap());
        // Only one current row per person.
        assert!(sqlx::query(
            "INSERT INTO deactivations (user_id, deactivated_by, deactivated_at) VALUES (2, 1, 11)"
        )
        .execute(&db)
        .await
        .is_err());
        sqlx::query("UPDATE deactivations SET reactivated_by = 1, reactivated_at = 20 WHERE user_id = 2 AND reactivated_at IS NULL")
            .execute(&db).await.unwrap();
        assert!(!is_deactivated(&db, 2).await.unwrap());
        // Off again: a new row; the first stays.
        sqlx::query(
            "INSERT INTO deactivations (user_id, deactivated_by, deactivated_at) VALUES (2, 1, 30)",
        )
        .execute(&db)
        .await
        .unwrap();
        let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM deactivations WHERE user_id = 2")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(n, 2);
        record(
            &db,
            1,
            "deactivate",
            Some(2),
            json!({ "sessions_ended": 1 }),
        )
        .await
        .unwrap();
        let (action, detail): (String, String) =
            sqlx::query_as("SELECT action, detail FROM admin_actions")
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!(
            (action.as_str(), detail.as_str()),
            ("deactivate", r#"{"sessions_ended":1}"#)
        );
    }
}
