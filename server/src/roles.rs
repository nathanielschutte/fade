//! Roles (docs/implementation/roles.md): User, PowerUser, Admin.
//!
//! Admins are a list in settings: `FADE_ADMINS`, plus the SSM parameter named
//! by `FADE_ADMINS_PARAM` in production, reloadable without a deploy. They're
//! never stored in the database. PowerUsers are granted in the app
//! (`user_roles`, append-only marks) by Admins or other PowerUsers, and taken
//! away only by Admins.
//!
//! PowerUser is for curiosity, not power: it opens parts of the System pages
//! but never shows more private data than a User sees, and can't act on
//! anyone. Every handler checks the role itself (`require`); a role that's
//! too low gets 404, so pages don't confirm they exist.

use std::sync::RwLock;

use axum::{
    extract::{Path, State},
    Json,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use hmac::{Hmac, Mac};
use serde::Serialize;
use serde_json::{json, Value};
use sha2::Sha256;
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    db::{now, UserPublic},
    error::{AppError, AppResult},
    SharedState,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    User,
    Power,
    Admin,
}

/// Usernames from a comma-, space-, or line-separated list, lowercased.
pub fn parse_list(text: &str) -> Vec<String> {
    let mut list: Vec<String> = text
        .split(|c: char| c == ',' || c.is_whitespace())
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    list.sort();
    list.dedup();
    list
}

/// The admin list: settings plus, in production, an SSM parameter.
pub struct Admins {
    from_env: Vec<String>,
    param: Option<String>,
    list: RwLock<Vec<String>>,
}

impl Admins {
    pub fn new(from_env: Vec<String>, param: Option<String>) -> Self {
        Self {
            list: RwLock::new(from_env.clone()),
            from_env,
            param,
        }
    }

    pub fn contains(&self, username: &str) -> bool {
        self.list
            .read()
            .unwrap()
            .iter()
            .any(|a| a == &username.to_lowercase())
    }

    pub fn count(&self) -> usize {
        self.list.read().unwrap().len()
    }

    pub fn has_param(&self) -> bool {
        self.param.is_some()
    }

    /// Reads the SSM parameter again and replaces the list with settings plus
    /// it. On failure the list stays as it was. Returns how many admins now.
    pub async fn reload(&self) -> anyhow::Result<usize> {
        let Some(name) = &self.param else {
            anyhow::bail!("no admin parameter is configured (FADE_ADMINS_PARAM)");
        };
        let aws = crate::aws::Aws::detect()
            .await
            .ok_or_else(|| anyhow::anyhow!("not running on AWS"))?;
        let mut list = self.from_env.clone();
        list.extend(parse_list(&aws.ssm_parameter(name).await?));
        list.sort();
        list.dedup();
        let count = list.len();
        *self.list.write().unwrap() = list;
        Ok(count)
    }
}

/// Whether `user_id` currently holds a PowerUser grant.
async fn granted_power(db: &SqlitePool, user_id: i64) -> sqlx::Result<bool> {
    let row: Option<i64> = sqlx::query_scalar(
        "SELECT 1 FROM user_roles WHERE user_id = ? AND role = 'power' AND revoked_at IS NULL",
    )
    .bind(user_id)
    .fetch_optional(db)
    .await?;
    Ok(row.is_some())
}

/// Someone's role. Being listed as an Admin beats a PowerUser grant.
pub async fn role_of(state: &SharedState, user: &UserPublic) -> sqlx::Result<Role> {
    if state.admins.contains(&user.username) {
        return Ok(Role::Admin);
    }
    Ok(if granted_power(&state.db, user.id).await? {
        Role::Power
    } else {
        Role::User
    })
}

/// The caller's role, if it's at least `min`; otherwise 404.
pub async fn require(state: &SharedState, user: &UserPublic, min: Role) -> AppResult<Role> {
    let role = role_of(state, user).await?;
    if role < min {
        return Err(AppError::not_found("Not found."));
    }
    Ok(role)
}

/// The ids of `user`'s current friends.
pub async fn friend_ids(db: &SqlitePool, user: i64) -> sqlx::Result<Vec<i64>> {
    sqlx::query_scalar(
        "SELECT CASE WHEN user_lo = ? THEN user_hi ELSE user_lo END FROM friendships
         WHERE (user_lo = ? OR user_hi = ?) AND ended_at IS NULL",
    )
    .bind(user)
    .bind(user)
    .bind(user)
    .fetch_all(db)
    .await
}

// ---------- aliases (anonymous people on a PowerUser's graph) ----------

/// The server's secret for aliases, made once and kept (`server_keys`).
pub async fn alias_key(db: &SqlitePool) -> sqlx::Result<Vec<u8>> {
    let fresh: [u8; 32] = rand::random();
    sqlx::query(
        "INSERT OR IGNORE INTO server_keys (name, value, created_at) VALUES ('graph_alias', ?, ?)",
    )
    .bind(B64.encode(fresh))
    .bind(now())
    .execute(db)
    .await?;
    let value: String =
        sqlx::query_scalar("SELECT value FROM server_keys WHERE name = 'graph_alias'")
            .fetch_one(db)
            .await?;
    Ok(B64.decode(value).unwrap_or_default())
}

/// `user` as `viewer` sees them when anonymous: the same every time for this
/// viewer, different for every other viewer, and unrelated to the user id.
pub fn alias(key: &[u8], viewer: i64, user: i64) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC takes any key length");
    mac.update(format!("napsack/graph-alias:{viewer}:{user}").as_bytes());
    let bytes = mac.finalize().into_bytes();
    let hex: String = bytes[..6].iter().map(|b| format!("{b:02x}")).collect();
    format!("a{hex}")
}

// ---------- the Roles page ----------

#[derive(Serialize, sqlx::FromRow)]
struct Person {
    id: i64,
    username: String,
    granted_by: Option<String>,
    granted_at: Option<i64>,
}

/// `GET /api/admin/roles`: everyone for Admins; for PowerUsers, themselves
/// and their friends.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    let role = require(&state, &me, Role::Power).await?;
    let rows: Vec<Person> = sqlx::query_as(
        "SELECT u.id, u.username, g.username AS granted_by, r.granted_at
         FROM users u
         LEFT JOIN user_roles r ON r.user_id = u.id AND r.role = 'power' AND r.revoked_at IS NULL
         LEFT JOIN users g ON g.id = r.granted_by
         ORDER BY lower(u.username)",
    )
    .fetch_all(&state.db)
    .await?;
    let visible: Option<Vec<i64>> = if role == Role::Admin {
        None
    } else {
        let mut ids = friend_ids(&state.db, me.id).await?;
        ids.push(me.id);
        Some(ids)
    };
    let people: Vec<Value> = rows
        .into_iter()
        .filter(|p| visible.as_ref().is_none_or(|ids| ids.contains(&p.id)))
        .map(|p| {
            let their_role = if state.admins.contains(&p.username) {
                Role::Admin
            } else if p.granted_at.is_some() {
                Role::Power
            } else {
                Role::User
            };
            json!({
                "id": p.id,
                "username": p.username,
                "role": their_role,
                // Who granted it is an Admin's business only.
                "granted_by": if role == Role::Admin { p.granted_by } else { None },
                "granted_at": p.granted_at,
            })
        })
        .collect();
    Ok(Json(json!({
        "role": role,
        "people": people,
        "admins_from_settings": role == Role::Admin && state.admins.has_param(),
    })))
}

/// `POST /api/admin/roles/{user_id}`: make them a PowerUser. Admins can
/// choose anyone; PowerUsers only their friends.
pub async fn grant(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    let role = require(&state, &me, Role::Power).await?;
    let target: Option<UserPublic> = sqlx::query_as("SELECT id, username FROM users WHERE id = ?")
        .bind(user_id)
        .fetch_optional(&state.db)
        .await?;
    let Some(target) = target else {
        return Err(AppError::not_found("They aren't on napsack."));
    };
    if target.id == me.id {
        return Err(AppError::bad("You can't change your own role."));
    }
    if role == Role::Power && !friend_ids(&state.db, me.id).await?.contains(&target.id) {
        // Same answer as someone who doesn't exist: PowerUsers only see their friends.
        return Err(AppError::not_found("They aren't on napsack."));
    }
    match role_of(&state, &target).await? {
        Role::Admin => return Err(AppError::Conflict("They're an Admin already.".into())),
        Role::Power => return Err(AppError::Conflict("They're a PowerUser already.".into())),
        Role::User => {}
    }
    let added = sqlx::query(
        "INSERT INTO user_roles (user_id, role, granted_by, granted_at) VALUES (?, 'power', ?, ?)",
    )
    .bind(target.id)
    .bind(me.id)
    .bind(now())
    .execute(&state.db)
    .await;
    match added {
        Ok(_) => {}
        // Two grants racing: the other one won.
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            return Err(AppError::Conflict("They're a PowerUser already.".into()))
        }
        Err(e) => return Err(e.into()),
    }
    tracing::info!(user_id = target.id, by = me.id, "poweruser granted");
    Ok(Json(json!({ "ok": true, "role": Role::Power })))
}

/// `DELETE /api/admin/roles/{user_id}`: take PowerUser away. Admins only.
pub async fn revoke(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    require(&state, &me, Role::Admin).await?;
    let marked = sqlx::query(
        "UPDATE user_roles SET revoked_at = ?, revoked_by = ?
         WHERE user_id = ? AND role = 'power' AND revoked_at IS NULL",
    )
    .bind(now())
    .bind(me.id)
    .bind(user_id)
    .execute(&state.db)
    .await?
    .rows_affected();
    if marked == 0 {
        return Err(AppError::not_found("They aren't a PowerUser."));
    }
    tracing::info!(user_id, by = me.id, "poweruser revoked");
    Ok(Json(json!({ "ok": true, "role": Role::User })))
}

/// `POST /api/admin/roles/reload`: read the admin list from settings again. Admins only.
pub async fn reload(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    require(&state, &me, Role::Admin).await?;
    match state.admins.reload().await {
        Ok(count) => {
            tracing::info!(by = me.id, admins = count, "admin list reloaded");
            Ok(Json(json!({ "ok": true, "admins": count })))
        }
        Err(e) => {
            tracing::warn!(by = me.id, error = %e, "admin list reload failed");
            Err(AppError::bad(format!(
                "Couldn't reload the admin list: {e}"
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[test]
    fn admin_lists() {
        assert_eq!(
            parse_list(" Nate, liana\nmaint  nate,,"),
            ["liana", "maint", "nate"]
        );
        assert!(parse_list("").is_empty());
        let admins = Admins::new(vec!["nate".into()], None);
        assert!(admins.contains("NATE") && !admins.contains("liana"));
        assert!(!admins.has_param());
    }

    #[test]
    fn aliases_are_per_viewer_and_hide_the_id() {
        let key = [7u8; 32];
        let a = alias(&key, 1, 42);
        assert_eq!(a, alias(&key, 1, 42), "stable for the same viewer");
        assert_ne!(a, alias(&key, 2, 42), "different for another viewer");
        assert_ne!(a, alias(&key, 1, 43));
        assert_ne!(a, alias(&[8u8; 32], 1, 42), "depends on the secret");
        assert_eq!(a.len(), 13);
        assert!(!a.contains("42"));
    }

    #[test]
    fn roles_order() {
        assert!(Role::User < Role::Power && Role::Power < Role::Admin);
        assert_eq!(serde_json::to_value(Role::Power).unwrap(), "power");
    }

    #[tokio::test]
    async fn grants_and_the_alias_secret() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben"), (3, "cal")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        assert!(!granted_power(&db, 2).await.unwrap());
        sqlx::query("INSERT INTO user_roles (user_id, role, granted_by, granted_at) VALUES (2, 'power', 1, 5)")
            .execute(&db).await.unwrap();
        assert!(granted_power(&db, 2).await.unwrap());
        // One current grant at a time.
        assert!(sqlx::query("INSERT INTO user_roles (user_id, role, granted_by, granted_at) VALUES (2, 'power', 3, 6)")
            .execute(&db).await.is_err());
        sqlx::query("UPDATE user_roles SET revoked_at = 7, revoked_by = 1 WHERE user_id = 2")
            .execute(&db)
            .await
            .unwrap();
        assert!(!granted_power(&db, 2).await.unwrap());
        // Granting again adds a row; the old one stays.
        sqlx::query("INSERT INTO user_roles (user_id, role, granted_by, granted_at) VALUES (2, 'power', 1, 8)")
            .execute(&db).await.unwrap();
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_roles")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rows, 2);

        let k1 = alias_key(&db).await.unwrap();
        assert_eq!(k1.len(), 32);
        assert_eq!(alias_key(&db).await.unwrap(), k1, "made once, then kept");

        sqlx::query(
            "INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (1, 2, 0), (1, 3, 0)",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query("UPDATE friendships SET ended_at = 9 WHERE user_hi = 3")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(friend_ids(&db, 1).await.unwrap(), vec![2]);
        assert_eq!(friend_ids(&db, 2).await.unwrap(), vec![1]);
    }
}
