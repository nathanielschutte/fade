//! Blocking (F28; docs/design/report-and-block.md). Blocking someone ends the
//! friendship (a mark with the reason `blocked`, as unfriending marks it),
//! resolves any friend request between the two, and from then on their
//! friend requests and add-a-friend link answer as an unknown person's do,
//! and they can't add the blocker to a group. Groups they're both already in
//! stay as they are. Nothing tells them: every refusal is one they'd get
//! without the block.
//!
//! Unblocking marks `ended_at`; blocking again adds a new row (Rule 1). The
//! friendship stays ended: they can be friends again the usual way.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Serialize;
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    db::{now, pair},
    error::{AppError, AppResult},
    guard::{MAX_BLOCKS, MAX_BLOCKS_PER_DAY},
    ws::Event,
    SharedState,
};

/// Whether `blocker` blocks `blocked` now.
pub async fn blocks(db: &SqlitePool, blocker: i64, blocked: i64) -> sqlx::Result<bool> {
    sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM blocks WHERE blocker_id = ? AND blocked_id = ? AND ended_at IS NULL)",
    )
    .bind(blocker)
    .bind(blocked)
    .fetch_one(db)
    .await
}

/// Whether either of the two blocks the other.
pub async fn between(db: &SqlitePool, a: i64, b: i64) -> sqlx::Result<bool> {
    Ok(blocks(db, a, b).await? || blocks(db, b, a).await?)
}

/// Someone `me` has been shown on napsack: a friend (now or before), someone
/// in a group with them now, someone with a friend request either way, or
/// someone they block. Only such a person can be blocked or reported, and
/// the answer for anyone else is the same whether the account exists or not.
pub async fn known(db: &SqlitePool, me: i64, other: i64) -> sqlx::Result<bool> {
    let (lo, hi) = pair(me, other);
    sqlx::query_scalar(
        "SELECT ?1 != ?2 AND EXISTS(SELECT 1 FROM users u WHERE u.id = ?2
              AND NOT EXISTS (SELECT 1 FROM deleted_accounts d WHERE d.user_id = u.id)
              AND NOT EXISTS (SELECT 1 FROM system_accounts s WHERE s.user_id = u.id))
           AND (EXISTS(SELECT 1 FROM friendships WHERE user_lo = ?3 AND user_hi = ?4)
             OR EXISTS(SELECT 1 FROM group_members a JOIN group_members b ON b.group_id = a.group_id
                       WHERE a.user_id = ?1 AND b.user_id = ?2 AND a.left_at IS NULL AND b.left_at IS NULL)
             OR EXISTS(SELECT 1 FROM friend_requests WHERE (from_id = ?1 AND to_id = ?2) OR (from_id = ?2 AND to_id = ?1))
             OR EXISTS(SELECT 1 FROM blocks WHERE blocker_id = ?1 AND blocked_id = ?2 AND ended_at IS NULL))",
    )
    .bind(me)
    .bind(other)
    .bind(lo)
    .bind(hi)
    .fetch_one(db)
    .await
}

fn not_blockable() -> AppError {
    AppError::not_found("That isn't someone you can block.")
}

/// `me` blocks `them`, in one transaction: the block, the friendship marked
/// ended (reason `blocked`), and pending requests either way resolved, each
/// in the friendship history. Returns false if `me` already blocked them.
pub async fn block(db: &SqlitePool, me: i64, them: i64) -> AppResult<bool> {
    let at = now();
    let mut tx = crate::db::write_tx(db).await?;
    let current: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM blocks WHERE blocker_id = ? AND ended_at IS NULL")
            .bind(me)
            .fetch_one(&mut *tx)
            .await?;
    if current >= MAX_BLOCKS {
        return Err(AppError::bad(format!(
            "You can block up to {MAX_BLOCKS} people. Unblock someone first."
        )));
    }
    let inserted =
        sqlx::query("INSERT INTO blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)")
            .bind(me)
            .bind(them)
            .bind(at)
            .execute(&mut *tx)
            .await;
    match inserted {
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => return Ok(false),
        other => {
            other?;
        }
    }
    let (lo, hi) = pair(me, them);
    let ended = sqlx::query(
        "UPDATE friendships SET ended_at = ?, ended_by = ?, ended_reason = 'blocked'
         WHERE user_lo = ? AND user_hi = ? AND ended_at IS NULL",
    )
    .bind(at)
    .bind(me)
    .bind(lo)
    .bind(hi)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if ended > 0 {
        crate::friends::record_event(&mut *tx, me, them, "unfriended").await?;
    }
    // Their request to me is declined; mine to them, canceled.
    for (from, to, resolution) in [(them, me, "declined"), (me, them, "canceled")] {
        let resolved = sqlx::query(
            "UPDATE friend_requests SET resolved_at = ?, resolution = ?
             WHERE from_id = ? AND to_id = ? AND resolved_at IS NULL",
        )
        .bind(at)
        .bind(resolution)
        .bind(from)
        .bind(to)
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if resolved > 0 {
            crate::friends::record_event(&mut *tx, me, them, resolution).await?;
        }
    }
    tx.commit().await?;
    Ok(true)
}

/// `me` unblocks `them`: the block is marked ended. Returns false if there
/// was none.
pub async fn unblock(db: &SqlitePool, me: i64, them: i64) -> sqlx::Result<bool> {
    let mut tx = crate::db::write_tx(db).await?;
    let ended = sqlx::query(
        "UPDATE blocks SET ended_at = ? WHERE blocker_id = ? AND blocked_id = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(me)
    .bind(them)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    tx.commit().await?;
    Ok(ended > 0)
}

/// `POST /api/blocks/{user_id}`: block someone you know (`known`).
pub async fn add(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(them): Path<i64>,
) -> AppResult<Json<Value>> {
    if them == me.id {
        return Err(AppError::bad("You can't block yourself."));
    }
    if crate::team::is_system(&state.db, them).await? {
        return Err(AppError::bad(
            "That's napsack's own account. You can mute its chat instead.",
        ));
    }
    if !known(&state.db, me.id, them).await? {
        return Err(not_blockable());
    }
    let made_today: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM blocks WHERE blocker_id = ? AND created_at > ?")
            .bind(me.id)
            .bind(now() - 86_400)
            .fetch_one(&state.db)
            .await?;
    if made_today >= MAX_BLOCKS_PER_DAY {
        return Err(AppError::TooManyRequests(
            "That's a lot of blocking for one day. Try again tomorrow.".into(),
        ));
    }
    let username: String = sqlx::query_scalar("SELECT username FROM users WHERE id = ?")
        .bind(them)
        .fetch_one(&state.db)
        .await?;
    let new = block(&state.db, me.id, them).await?;
    if new {
        tracing::info!(user_id = me.id, blocked_id = them, "blocked");
        // Both lists lose the chat (the friendship ended); neither icon counts it.
        state.hub.send_both(me.id, them, &Event::FriendsChanged);
        crate::apns::badge_changed(&state, me.id);
        crate::apns::badge_changed(&state, them);
    }
    Ok(Json(json!({
        "blocked": true,
        "already": !new,
        "user": { "id": them, "username": username },
    })))
}

/// `POST /api/blocks/{user_id}/remove`: unblock. The friendship stays ended.
pub async fn remove(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(them): Path<i64>,
) -> AppResult<Json<Value>> {
    if !unblock(&state.db, me.id, them).await? {
        return Err(AppError::not_found("You haven't blocked them."));
    }
    tracing::info!(user_id = me.id, blocked_id = them, "unblocked");
    state.hub.send(me.id, &Event::FriendsChanged);
    Ok(Json(json!({ "blocked": false })))
}

#[derive(Serialize, FromRow)]
struct Blocked {
    id: i64,
    username: String,
    blocked_at: i64,
}

/// `GET /api/blocks`: who I block now, newest first (Profile › Blocked).
/// Usernames only: display names are for friends.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    let blocked = sqlx::query_as::<_, Blocked>(
        "SELECT u.id, u.username, b.created_at AS blocked_at FROM blocks b JOIN users u ON u.id = b.blocked_id
         WHERE b.blocker_id = ? AND b.ended_at IS NULL
           AND NOT EXISTS (SELECT 1 FROM deleted_accounts d WHERE d.user_id = u.id)
         ORDER BY b.created_at DESC, b.id DESC",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(json!({ "blocks": blocked })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    /// Ana (1) and Ben (2) are friends, Cat (3) asked Ana to be friends, Dee
    /// (4) is in a group with Ana, Eve (5) is a stranger.
    async fn seeded() -> SqlitePool {
        let db = temp_db().await;
        sqlx::raw_sql(
            "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES
                (1, 'ana', 'h', 'k', 'w', 0), (2, 'ben', 'h', 'k', 'w', 0), (3, 'cat', 'h', 'k', 'w', 0),
                (4, 'dee', 'h', 'k', 'w', 0), (5, 'eve', 'h', 'k', 'w', 0);
             INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (1, 2, 0);
             INSERT INTO friend_requests (from_id, to_id, created_at) VALUES (3, 1, 0);
             INSERT INTO groups (id, name, created_by, created_at) VALUES (1, 'trip', 1, 0);
             INSERT INTO group_members (group_id, user_id, role, joined_at) VALUES (1, 1, 'owner', 0), (1, 4, 'member', 0);",
        )
        .execute(&db)
        .await
        .unwrap();
        db
    }

    #[tokio::test]
    async fn only_people_you_know() {
        let db = seeded().await;
        for (other, want) in [
            (2, true),
            (3, true),
            (4, true),
            (5, false),
            (1, false),
            (99, false),
        ] {
            assert_eq!(known(&db, 1, other).await.unwrap(), want, "{other}");
        }
        // Leaving the group: no longer someone she's in a group with.
        sqlx::query("UPDATE group_members SET left_at = 5 WHERE user_id = 4")
            .execute(&db)
            .await
            .unwrap();
        assert!(!known(&db, 1, 4).await.unwrap());
    }

    #[tokio::test]
    async fn blocking_ends_the_friendship_and_requests_and_unblocking_keeps_the_record() {
        let db = seeded().await;
        assert!(block(&db, 1, 2).await.unwrap());
        assert!(!block(&db, 1, 2).await.unwrap(), "once");
        assert!(blocks(&db, 1, 2).await.unwrap() && !blocks(&db, 2, 1).await.unwrap());
        assert!(between(&db, 2, 1).await.unwrap());
        assert!(!crate::db::are_friends(&db, 1, 2).await.unwrap());
        let (ended_by, reason): (i64, String) = sqlx::query_as(
            "SELECT ended_by, ended_reason FROM friendships WHERE user_lo = 1 AND user_hi = 2",
        )
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!((ended_by, reason.as_str()), (1, "blocked"));

        assert!(block(&db, 1, 3).await.unwrap());
        let resolution: String =
            sqlx::query_scalar("SELECT resolution FROM friend_requests WHERE from_id = 3")
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!(resolution, "declined");
        let events: Vec<String> = sqlx::query_scalar("SELECT kind FROM friend_events ORDER BY id")
            .fetch_all(&db)
            .await
            .unwrap();
        assert_eq!(events, ["unfriended", "declined"]);
        // Still someone she knows, while she blocks them.
        assert!(known(&db, 1, 3).await.unwrap());

        assert!(unblock(&db, 1, 2).await.unwrap());
        assert!(!unblock(&db, 1, 2).await.unwrap());
        assert!(!blocks(&db, 1, 2).await.unwrap());
        assert!(block(&db, 1, 2).await.unwrap(), "blocking again adds a row");
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM blocks WHERE blocked_id = 2")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rows, 2, "the first block is kept, marked ended");
    }

    #[tokio::test]
    async fn blocks_are_capped() {
        let db = seeded().await;
        sqlx::query(
            "WITH RECURSIVE n(i) AS (SELECT 100 UNION ALL SELECT i + 1 FROM n WHERE i < 99 + ?)
             INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at)
             SELECT i, 'u' || i, 'h', 'k', 'w', 0 FROM n",
        )
        .bind(MAX_BLOCKS)
        .execute(&db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO blocks (blocker_id, blocked_id, created_at) SELECT 1, id, 0 FROM users WHERE id >= 100",
        )
        .execute(&db)
        .await
        .unwrap();
        assert!(matches!(
            block(&db, 1, 2).await,
            Err(AppError::BadRequest(m)) if m.contains("up to")
        ));
    }
}
