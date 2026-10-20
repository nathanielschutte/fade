//! Typing and "active now" (F12). Nothing here is stored except the
//! person's choice to share it: typing travels over the socket and is gone,
//! and "active" is whether someone has napsack open (a live socket), or when
//! they last did (`users.last_seen_at`).
//!
//! It's mutual and friends-only: you see a friend's activity only if you both
//! share yours. Group typing goes to members who share theirs.

use axum::{extract::State, Json};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    db::{self, now},
    error::AppResult,
    ws::Event,
    SharedState,
};

pub async fn shares(db: &SqlitePool, user: i64) -> sqlx::Result<bool> {
    Ok(
        sqlx::query_scalar::<_, bool>("SELECT share_activity FROM users WHERE id = ?")
            .bind(user)
            .fetch_optional(db)
            .await?
            .unwrap_or(false),
    )
}

/// Friends who may see `user`'s activity: none if `user` hides theirs, and
/// only those who share their own.
async fn audience(db: &SqlitePool, user: i64) -> sqlx::Result<Vec<i64>> {
    if !shares(db, user).await? {
        return Ok(Vec::new());
    }
    sqlx::query_scalar(
        "SELECT u.id FROM friendships f
         JOIN users u ON u.id = CASE WHEN f.user_lo = ?1 THEN f.user_hi ELSE f.user_lo END
         WHERE (f.user_lo = ?1 OR f.user_hi = ?1) AND f.ended_at IS NULL AND u.share_activity = 1",
    )
    .bind(user)
    .fetch_all(db)
    .await
}

/// Someone opened napsack (first socket) or closed it (last socket).
pub async fn announce(state: &SharedState, user: i64, active: bool) {
    let at = now();
    if !active {
        // The socket was the last sign of life; remember it.
        let _ = sqlx::query("UPDATE users SET last_seen_at = ? WHERE id = ?")
            .bind(at)
            .bind(user)
            .execute(&state.db)
            .await;
    }
    match audience(&state.db, user).await {
        Ok(ids) => state.hub.send_many(
            &ids,
            &Event::Presence {
                user_id: user,
                active,
                last_seen_at: at,
            },
        ),
        Err(e) => tracing::warn!(error = ?e, user_id = user, "presence lookup failed"),
    }
}

/// "Typing…" for one friend, or for a group's members. Unknown or not-allowed
/// targets are silently ignored: it's a hint, not a request.
pub async fn typing(state: &SharedState, from: i64, to: Option<i64>, group: Option<i64>) {
    let result: sqlx::Result<()> = async {
        if !shares(&state.db, from).await? {
            return Ok(());
        }
        if let Some(friend) = to {
            if db::are_friends(&state.db, from, friend).await? && shares(&state.db, friend).await? {
                state.hub.send(
                    friend,
                    &Event::Typing {
                        from,
                        group_id: None,
                    },
                );
            }
        } else if let Some(group) = group {
            if crate::groups::membership(&state.db, group, from).await?.is_some() {
                let members: Vec<i64> = sqlx::query_scalar(
                    "SELECT m.user_id FROM group_members m JOIN users u ON u.id = m.user_id
                     WHERE m.group_id = ? AND m.left_at IS NULL AND m.user_id != ? AND u.share_activity = 1",
                )
                .bind(group)
                .bind(from)
                .fetch_all(&state.db)
                .await?;
                state.hub.send_many(
                    &members,
                    &Event::Typing {
                        from,
                        group_id: Some(group),
                    },
                );
            }
        }
        Ok(())
    }
    .await;
    if let Err(e) = result {
        tracing::warn!(error = ?e, user_id = from, "typing relay failed");
    }
}

#[derive(Deserialize)]
pub struct Settings {
    share_activity: bool,
}

/// `PUT /api/me/settings`
pub async fn set_settings(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<Settings>,
) -> AppResult<Json<Value>> {
    sqlx::query("UPDATE users SET share_activity = ? WHERE id = ?")
        .bind(req.share_activity)
        .bind(me.id)
        .execute(&state.db)
        .await?;
    tracing::info!(
        user_id = me.id,
        share_activity = req.share_activity,
        "activity sharing set"
    );
    // Friends' lists show (or stop showing) it; so do mine.
    let mut ids: Vec<i64> = crate::profiles::friends_of(&state.db, me.id)
        .await?
        .into_iter()
        .map(|f| f.id)
        .collect();
    ids.push(me.id);
    state.hub.send_many(&ids, &Event::FriendsChanged);
    Ok(Json(json!({ "share_activity": req.share_activity })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::{pair, tests::temp_db};

    #[tokio::test]
    async fn activity_is_mutual_and_friends_only() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben"), (3, "cal"), (4, "dee")] {
            sqlx::query(
                "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at)
                 VALUES (?, ?, 'h', 'k', 'w', 0)",
            )
            .bind(id)
            .bind(name)
            .execute(&db)
            .await
            .unwrap();
        }
        for (a, b) in [(1, 2), (1, 3)] {
            let (lo, hi) = pair(a, b);
            sqlx::query("INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (?, ?, 0)")
                .bind(lo)
                .bind(hi)
                .execute(&db)
                .await
                .unwrap();
        }
        let mut seen = audience(&db, 1).await.unwrap();
        seen.sort();
        assert_eq!(seen, vec![2, 3], "friends only: dee isn't one");
        sqlx::query("UPDATE users SET share_activity = 0 WHERE id = 3")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(
            audience(&db, 1).await.unwrap(),
            vec![2],
            "cal hides theirs, so sees no one's"
        );
        assert!(
            audience(&db, 3).await.unwrap().is_empty(),
            "and shows no one theirs"
        );
    }
}
