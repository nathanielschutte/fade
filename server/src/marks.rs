//! Private, per-person marks on chats (X3): favorites, kept at the top of
//! your chat list, and hidden direct chats, archived out of it until a new
//! message arrives or you open them again. Groups aren't hidden; you leave
//! them.
//!
//! Only the person who sets a mark ever sees it; friends see no difference.
//! Rows are never updated or deleted (Rule 1): the newest row per
//! (user, chat, kind) is the current state.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    db::now,
    error::{AppError, AppResult},
    ws::Event,
    SharedState,
};

/// Favorites are for the few closest chats; this keeps the list meaningful
/// and the table bounded.
pub const MAX_FAVORITES: i64 = 10;

/// For `list_chats`: whether `u` is one of `?1`'s favorites (NULL if never set).
pub const FAVORITE_FRIEND: &str = "(SELECT k.value FROM chat_marks k
     WHERE k.user_id = ?1 AND k.kind = 'favorite' AND k.friend_id = u.id ORDER BY k.id DESC LIMIT 1)";
/// For the group list: whether group `g` is one of `?1`'s favorites.
pub const FAVORITE_GROUP: &str = "(SELECT k.value FROM chat_marks k
     WHERE k.user_id = ?1 AND k.kind = 'favorite' AND k.group_id = g.id ORDER BY k.id DESC LIMIT 1)";
/// For `list_chats`: if `?1` hid their chat with `u`, the newest message id at
/// the time (see `is_hidden`).
pub const HIDDEN_UPTO: &str = "(SELECT CASE WHEN k.value = 1 THEN COALESCE(k.upto_id, 0) END
     FROM chat_marks k
     WHERE k.user_id = ?1 AND k.kind = 'hidden' AND k.friend_id = u.id ORDER BY k.id DESC LIMIT 1)";

/// For the chat list: `?1`'s current mute on chat `u` (a friend) or `g` (a
/// group), as when it ends: NULL when not muted, 0 when muted until turned
/// off, else the Unix time it ends (which may already have passed: see `muted`).
pub const MUTED_FRIEND: &str = "(SELECT CASE WHEN k.value = 1 THEN COALESCE(k.until_at, 0) END
     FROM chat_mutes k WHERE k.user_id = ?1 AND k.friend_id = u.id ORDER BY k.id DESC LIMIT 1)";
pub const MUTED_GROUP: &str = "(SELECT CASE WHEN k.value = 1 THEN COALESCE(k.until_at, 0) END
     FROM chat_mutes k WHERE k.user_id = ?1 AND k.group_id = g.id ORDER BY k.id DESC LIMIT 1)";

/// From the column above: (muted now, when it ends if it ends by itself).
pub fn muted(raw: Option<i64>, now: i64) -> (bool, Option<i64>) {
    match raw {
        None => (false, None),
        Some(0) => (true, None),
        Some(until) if until > now => (true, Some(until)),
        Some(_) => (false, None),
    }
}

/// Mutes last at most a year (or until turned off).
const MAX_MUTE_HOURS: i64 = 24 * 365;

/// Whether `user` has muted the chat a notification with `tag` belongs to
/// ("dm-<friend>" or "group-<group>"). Friend requests are never muted.
pub async fn muted_for_tag(db: &SqlitePool, user: i64, tag: &str) -> sqlx::Result<bool> {
    let chat = if let Some(id) = tag.strip_prefix("dm-").and_then(|s| s.parse().ok()) {
        Chat::Friend(id)
    } else if let Some(id) = tag.strip_prefix("group-").and_then(|s| s.parse().ok()) {
        Chat::Group(id)
    } else {
        return Ok(false);
    };
    let (friend, group) = chat.ids();
    let raw: Option<Option<i64>> = sqlx::query_scalar(
        "SELECT CASE WHEN value = 1 THEN COALESCE(until_at, 0) END FROM chat_mutes
         WHERE user_id = ? AND friend_id IS ? AND group_id IS ? ORDER BY id DESC LIMIT 1",
    )
    .bind(user)
    .bind(friend)
    .bind(group)
    .fetch_optional(db)
    .await?;
    Ok(muted(raw.flatten(), now()).0)
}

#[derive(Deserialize)]
pub struct MuteRequest {
    on: bool,
    /// How long, in hours; none (with `on`) means until turned off.
    hours: Option<i64>,
}

async fn set_mute(
    db: &SqlitePool,
    user: i64,
    chat: Chat,
    req: &MuteRequest,
) -> AppResult<Option<i64>> {
    let until = match (req.on, req.hours) {
        (true, Some(h)) if (1..=MAX_MUTE_HOURS).contains(&h) => Some(now() + h * 3600),
        (true, Some(_)) => return Err(AppError::bad("Mute for between an hour and a year.")),
        _ => None,
    };
    let (friend, group) = chat.ids();
    sqlx::query(
        "INSERT INTO chat_mutes (user_id, friend_id, group_id, value, until_at, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(user)
    .bind(friend)
    .bind(group)
    .bind(req.on)
    .bind(until)
    .bind(now())
    .execute(db)
    .await?;
    Ok(until)
}

/// `PUT /api/chats/{friend_id}/mute` `{"on": bool, "hours": 8}`: no
/// notifications and no unread dot from this chat, for `hours` or until
/// turned off (no `hours`).
pub async fn mute_chat(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend): Path<i64>,
    Json(req): Json<MuteRequest>,
) -> AppResult<Json<Value>> {
    crate::friends::require_friend(&state, me.id, friend).await?;
    let until = set_mute(&state.db, me.id, Chat::Friend(friend), &req).await?;
    tracing::info!(
        user_id = me.id,
        friend_id = friend,
        on = req.on,
        "chat muted"
    );
    state.hub.send(me.id, &Event::FriendsChanged);
    Ok(Json(json!({ "muted": req.on, "muted_until": until })))
}

/// `PUT /api/groups/{group_id}/mute`, like `mute_chat`.
pub async fn mute_group(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    Json(req): Json<MuteRequest>,
) -> AppResult<Json<Value>> {
    crate::groups::require_member(&state.db, group, me.id).await?;
    let until = set_mute(&state.db, me.id, Chat::Group(group), &req).await?;
    tracing::info!(user_id = me.id, group_id = group, on = req.on, "chat muted");
    state
        .hub
        .send(me.id, &Event::GroupsChanged { group_id: group });
    Ok(Json(json!({ "muted": req.on, "muted_until": until })))
}

/// A hidden chat stays hidden until something newer than what was there
/// when it was hidden arrives.
pub fn is_hidden(hidden_upto: Option<i64>, last_message_id: Option<i64>) -> bool {
    hidden_upto.is_some_and(|upto| last_message_id.unwrap_or(0) <= upto)
}

#[derive(Clone, Copy)]
enum Chat {
    Friend(i64),
    Group(i64),
}

impl Chat {
    fn ids(self) -> (Option<i64>, Option<i64>) {
        match self {
            Chat::Friend(id) => (Some(id), None),
            Chat::Group(id) => (None, Some(id)),
        }
    }
}

async fn current(db: &SqlitePool, user: i64, chat: Chat, kind: &str) -> sqlx::Result<bool> {
    let (friend, group) = chat.ids();
    let v: Option<i64> = sqlx::query_scalar(
        "SELECT value FROM chat_marks
         WHERE user_id = ? AND kind = ? AND friend_id IS ? AND group_id IS ?
         ORDER BY id DESC LIMIT 1",
    )
    .bind(user)
    .bind(kind)
    .bind(friend)
    .bind(group)
    .fetch_optional(db)
    .await?;
    Ok(v == Some(1))
}

async fn record(
    db: &SqlitePool,
    user: i64,
    chat: Chat,
    kind: &str,
    on: bool,
    upto: Option<i64>,
) -> sqlx::Result<()> {
    let (friend, group) = chat.ids();
    sqlx::query(
        "INSERT INTO chat_marks (user_id, friend_id, group_id, kind, value, upto_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(user)
    .bind(friend)
    .bind(group)
    .bind(kind)
    .bind(on)
    .bind(upto)
    .bind(now())
    .execute(db)
    .await?;
    Ok(())
}

/// Favorites that still point at a current friend or group. One left behind
/// by unfriending or leaving doesn't count against the limit (it comes back
/// if the chat does).
async fn favorite_count(db: &SqlitePool, user: i64) -> sqlx::Result<i64> {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM chat_marks k
         WHERE k.user_id = ?1 AND k.kind = 'favorite' AND k.value = 1
           AND k.id = (SELECT MAX(x.id) FROM chat_marks x
                        WHERE x.user_id = ?1 AND x.kind = 'favorite'
                          AND x.friend_id IS k.friend_id AND x.group_id IS k.group_id)
           AND (k.friend_id IS NULL OR EXISTS (SELECT 1 FROM friendships f
                 WHERE f.ended_at IS NULL
                   AND f.user_lo = MIN(?1, k.friend_id) AND f.user_hi = MAX(?1, k.friend_id)))
           AND (k.group_id IS NULL OR EXISTS (SELECT 1 FROM group_members m
                 WHERE m.group_id = k.group_id AND m.user_id = ?1 AND m.left_at IS NULL))",
    )
    .bind(user)
    .fetch_one(db)
    .await
}

/// Turns a favorite on or off. Returns whether anything changed.
async fn set_favorite(db: &SqlitePool, user: i64, chat: Chat, on: bool) -> AppResult<bool> {
    if current(db, user, chat, "favorite").await? == on {
        return Ok(false);
    }
    if on && favorite_count(db, user).await? >= MAX_FAVORITES {
        return Err(AppError::bad(
            "You can have up to 10 favorites. Unfavorite one first.",
        ));
    }
    record(db, user, chat, "favorite", on, None).await?;
    Ok(true)
}

#[derive(Deserialize)]
pub struct Toggle {
    on: bool,
}

/// `PUT /api/chats/{friend_id}/favorite` `{"on": bool}`
pub async fn favorite_chat(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend): Path<i64>,
    Json(t): Json<Toggle>,
) -> AppResult<Json<Value>> {
    crate::friends::require_friend(&state, me.id, friend).await?;
    if set_favorite(&state.db, me.id, Chat::Friend(friend), t.on).await? {
        tracing::info!(
            user_id = me.id,
            friend_id = friend,
            on = t.on,
            "favorite set"
        );
        // My other devices reorder their lists.
        state.hub.send(me.id, &Event::FriendsChanged);
    }
    Ok(Json(json!({ "favorite": t.on })))
}

/// `PUT /api/groups/{group_id}/favorite` `{"on": bool}`
pub async fn favorite_group(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    Json(t): Json<Toggle>,
) -> AppResult<Json<Value>> {
    crate::groups::require_member(&state.db, group, me.id).await?;
    if set_favorite(&state.db, me.id, Chat::Group(group), t.on).await? {
        tracing::info!(user_id = me.id, group_id = group, on = t.on, "favorite set");
        state
            .hub
            .send(me.id, &Event::GroupsChanged { group_id: group });
    }
    Ok(Json(json!({ "favorite": t.on })))
}

/// `PUT /api/chats/{friend_id}/hidden` `{"on": bool}`: hides the chat from my
/// list (archive) or shows it again. The messages stay; a new one, from
/// either side, brings the chat back by itself.
pub async fn hide_chat(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend): Path<i64>,
    Json(t): Json<Toggle>,
) -> AppResult<Json<Value>> {
    crate::friends::require_friend(&state, me.id, friend).await?;
    let newest: i64 = sqlx::query_scalar(
        "SELECT COALESCE(MAX(id), 0) FROM messages
         WHERE (sender_id = ?1 AND recipient_id = ?2) OR (sender_id = ?2 AND recipient_id = ?1)",
    )
    .bind(me.id)
    .bind(friend)
    .fetch_one(&state.db)
    .await?;
    record(
        &state.db,
        me.id,
        Chat::Friend(friend),
        "hidden",
        t.on,
        t.on.then_some(newest),
    )
    .await?;
    tracing::info!(
        user_id = me.id,
        friend_id = friend,
        on = t.on,
        "chat hidden"
    );
    state.hub.send(me.id, &Event::FriendsChanged);
    Ok(Json(json!({ "hidden": t.on })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    async fn people(db: &SqlitePool, n: i64) {
        for id in 1..=n {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(format!("u{id}")).execute(db).await.unwrap();
        }
    }

    async fn befriend(db: &SqlitePool, a: i64, b: i64) {
        let (lo, hi) = crate::db::pair(a, b);
        sqlx::query("INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (?, ?, 0)")
            .bind(lo)
            .bind(hi)
            .execute(db)
            .await
            .unwrap();
    }

    #[test]
    fn mutes_end_by_themselves() {
        assert_eq!(muted(None, 100), (false, None));
        assert_eq!(muted(Some(0), 100), (true, None), "until turned off");
        assert_eq!(muted(Some(500), 100), (true, Some(500)));
        assert_eq!(muted(Some(50), 100), (false, None), "over");
    }

    #[tokio::test]
    async fn muting_silences_that_chat_only() {
        let db = temp_db().await;
        people(&db, 3).await;
        let on = |hours| MuteRequest { on: true, hours };
        set_mute(&db, 1, Chat::Friend(2), &on(None)).await.unwrap();
        assert!(muted_for_tag(&db, 1, "dm-2").await.unwrap());
        assert!(
            !muted_for_tag(&db, 1, "dm-3").await.unwrap(),
            "another chat"
        );
        assert!(
            !muted_for_tag(&db, 2, "dm-1").await.unwrap(),
            "the friend's side"
        );
        assert!(
            !muted_for_tag(&db, 1, "requests").await.unwrap(),
            "friend requests always come through"
        );
        set_mute(
            &db,
            1,
            Chat::Friend(2),
            &MuteRequest {
                on: false,
                hours: None,
            },
        )
        .await
        .unwrap();
        assert!(!muted_for_tag(&db, 1, "dm-2").await.unwrap());
        sqlx::query("INSERT INTO groups (id, name, created_by, created_at) VALUES (7, 'g', 1, 0)")
            .execute(&db)
            .await
            .unwrap();
        set_mute(&db, 1, Chat::Group(7), &on(Some(8)))
            .await
            .unwrap();
        assert!(muted_for_tag(&db, 1, "group-7").await.unwrap());
        assert!(set_mute(&db, 1, Chat::Friend(2), &on(Some(0)))
            .await
            .is_err());
        assert!(set_mute(&db, 1, Chat::Friend(2), &on(Some(24 * 366)))
            .await
            .is_err());
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM chat_mutes")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rows, 3, "unmuting adds a row; nothing is deleted");
    }

    #[test]
    fn hidden_until_something_newer_arrives() {
        assert!(!is_hidden(None, Some(5)));
        assert!(is_hidden(Some(5), Some(5)));
        assert!(is_hidden(Some(0), None), "an empty chat stays hidden");
        assert!(!is_hidden(Some(5), Some(6)), "a new message brings it back");
    }

    #[tokio::test]
    async fn favorites_toggle_by_adding_rows_and_are_capped() {
        let db = temp_db().await;
        people(&db, 13).await;
        for f in 2..=13 {
            befriend(&db, 1, f).await;
        }
        assert!(set_favorite(&db, 1, Chat::Friend(2), true).await.unwrap());
        assert!(
            !set_favorite(&db, 1, Chat::Friend(2), true).await.unwrap(),
            "already on: no new row"
        );
        assert!(current(&db, 1, Chat::Friend(2), "favorite").await.unwrap());
        assert!(set_favorite(&db, 1, Chat::Friend(2), false).await.unwrap());
        assert!(!current(&db, 1, Chat::Friend(2), "favorite").await.unwrap());
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM chat_marks")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rows, 2, "turning it off adds a row; nothing is deleted");

        for f in 2..=11 {
            set_favorite(&db, 1, Chat::Friend(f), true).await.unwrap();
        }
        assert_eq!(favorite_count(&db, 1).await.unwrap(), MAX_FAVORITES);
        assert!(
            set_favorite(&db, 1, Chat::Friend(12), true).await.is_err(),
            "the 11th is refused"
        );
        // Someone else's favorites are their own.
        befriend(&db, 13, 2).await;
        assert!(set_favorite(&db, 13, Chat::Friend(2), true).await.unwrap());

        // Unfriending one frees a slot; its mark stays for if they're friends again.
        sqlx::query("UPDATE friendships SET ended_at = 1 WHERE user_lo = 1 AND user_hi = 2")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(favorite_count(&db, 1).await.unwrap(), MAX_FAVORITES - 1);
        assert!(set_favorite(&db, 1, Chat::Friend(12), true).await.unwrap());
        assert!(current(&db, 1, Chat::Friend(2), "favorite").await.unwrap());
    }

    #[tokio::test]
    async fn group_and_direct_marks_are_separate() {
        let db = temp_db().await;
        people(&db, 2).await;
        sqlx::query("INSERT INTO groups (id, name, created_by, created_at) VALUES (2, 'g', 1, 0)")
            .execute(&db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO group_members (group_id, user_id, role, joined_at) VALUES (2, 1, 'owner', 0)")
            .execute(&db).await.unwrap();
        // Friend 2 and group 2 share an id, not a mark.
        set_favorite(&db, 1, Chat::Group(2), true).await.unwrap();
        assert!(current(&db, 1, Chat::Group(2), "favorite").await.unwrap());
        assert!(!current(&db, 1, Chat::Friend(2), "favorite").await.unwrap());
        assert_eq!(favorite_count(&db, 1).await.unwrap(), 1);
    }
}
