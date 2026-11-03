use std::sync::LazyLock;

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    birthdays::BIRTHDAY_MD,
    db::{self, now, pair, Message, UserPublic},
    error::{AppError, AppResult},
    marks::{FAVORITE_FRIEND, HIDDEN_UPTO, MUTED_FRIEND},
    people::{AVATAR_ID, DISPLAY_NAME, NICKNAME, SINCE_MY_KEY},
    ws::Event,
    SharedState,
};

#[derive(FromRow)]
struct ChatRow {
    id: i64,
    username: String,
    display_name: Option<String>,
    nickname: Option<String>,
    avatar_id: Option<i64>,
    public_key: String,
    key_reset_at: Option<i64>,
    share_activity: bool,
    last_seen_at: Option<i64>,
    last_id: Option<i64>,
    unread: i64,
    favorite: Option<bool>,
    hidden_upto: Option<i64>,
    birthday: Option<String>,
    muted_raw: Option<i64>,
    deactivated: bool,
    system: bool,
    /// Their newest past username, and when they stopped using it.
    was: Option<String>,
    renamed_at: Option<i64>,
}

/// The chat list's rows: every friend, and Team Napsack once it has sent you
/// something, with what the list shows of each. Everything per friend is a
/// search of an index: their newest message is the newer of two (the newest
/// each way, in messages_pair), and unread counts read messages_waiting,
/// whose condition the count repeats so SQLite uses it.
static CHAT_ROWS: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT u.id, u.username, u.public_key, u.key_reset_at, u.share_activity, u.last_seen_at,
            {DISPLAY_NAME} AS display_name, {NICKNAME} AS nickname, {AVATAR_ID} AS avatar_id,
            {FAVORITE_FRIEND} AS favorite, {HIDDEN_UPTO} AS hidden_upto, {BIRTHDAY_MD} AS birthday, {MUTED_FRIEND} AS muted_raw,
            {DEACTIVATED} AS deactivated, {SYSTEM} AS system,
            NULLIF(MAX(COALESCE((SELECT MAX(m.id) FROM messages m WHERE m.sender_id = ?1 AND m.recipient_id = u.id), 0),
                       COALESCE((SELECT MAX(m.id) FROM messages m WHERE m.sender_id = u.id AND m.recipient_id = ?1), 0)), 0) AS last_id,
            (SELECT COUNT(*) FROM messages m
              WHERE m.recipient_id = ?1 AND m.sender_id = u.id
                AND ((m.kind = 'text' AND m.read_at IS NULL)
                  OR (m.kind = 'snap' AND m.snap_state = 'pending'))
                -- Nothing from before an admin reset code: it's sealed to the old key (D14).
                AND m.created_at > {SINCE_MY_KEY}) AS unread,
            (SELECT p.username FROM past_usernames p WHERE p.user_id = u.id ORDER BY p.id DESC LIMIT 1) AS was,
            (SELECT p.until FROM past_usernames p WHERE p.user_id = u.id ORDER BY p.id DESC LIMIT 1) AS renamed_at
         FROM users u
         WHERE u.id IN (SELECT CASE WHEN f.user_lo = ?1 THEN f.user_hi ELSE f.user_lo END
                        FROM friendships f WHERE (f.user_lo = ?1 OR f.user_hi = ?1) AND f.ended_at IS NULL
                        UNION ALL
                        SELECT s.user_id FROM system_accounts s
                        WHERE EXISTS (SELECT 1 FROM messages m WHERE m.sender_id = s.user_id AND m.recipient_id = ?1))"
    )
});

#[derive(Serialize)]
pub struct ChatSummary {
    id: i64,
    username: String,
    /// The name they chose for themselves (people.rs).
    display_name: Option<String>,
    /// The name you gave them; only you see it.
    nickname: Option<String>,
    /// Their current profile picture: `GET /api/users/{id}/avatar/{avatar_id}`.
    avatar_id: Option<i64>,
    /// The friend's SPKI public key. Clients pin it on first sight.
    public_key: String,
    /// When an admin reset gave them a new key (so a changed safety code has an explanation).
    key_reset_at: Option<i64>,
    /// Napsack is open for them right now. Only when you both share activity (presence.rs).
    active_now: Option<bool>,
    /// When they were last around, under the same rule.
    last_seen_at: Option<i64>,
    last_message: Option<Message>,
    /// Unread texts plus unopened snaps from this friend.
    unread: i64,
    /// One of my favorites, kept at the top of my list. Only I see it (marks.rs).
    favorite: bool,
    /// I hid (archived) this chat and nothing newer has arrived since.
    hidden: bool,
    /// Their birthday as "MM-DD", if they've set one (birthdays.rs), for a 🎂 on the day.
    birthday: Option<String>,
    /// Days in a row you've both sent each other a pic (streaks.rs); shown from 3.
    streak: i64,
    /// That streak runs out tonight unless you both send one today.
    streak_expiring: bool,
    /// I muted this chat: no notifications or unread dot (marks.rs).
    muted: bool,
    /// When that mute ends by itself; null while muted means until turned off.
    muted_until: Option<i64>,
    /// An Admin turned their account off (admin_users.rs): the chat's history
    /// stays, but nothing new can be sent to them.
    deactivated: bool,
    /// Team Napsack (team.rs): napsack's own account, not a friend. Its chat
    /// is listed once it has sent you something, and it's read-only.
    system: bool,
    /// Their username before they changed it, and when, for 30 days after
    /// (usernames.rs): the chat says so.
    was: Option<String>,
    renamed_at: Option<i64>,
}

/// The home screen: every friend, with their latest message, newest chats first.
pub async fn list_chats(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Query(tz): Query<crate::streaks::Tz>,
) -> AppResult<Json<Vec<ChatSummary>>> {
    let chats = chats_for(&state.db, me.id, tz.offset_minutes(), |id| {
        state.hub.is_online(id)
    })
    .await?;
    Ok(Json(chats))
}

/// `list_chats` for `me`, in a few queries however many friends they have:
/// the rows, their newest messages, streaks, and whether `me` shares
/// activity. `online`: whether someone has napsack open right now.
pub(crate) async fn chats_for(
    db: &SqlitePool,
    me: i64,
    offset_minutes: i64,
    online: impl Fn(i64) -> bool,
) -> sqlx::Result<Vec<ChatSummary>> {
    let rows = sqlx::query_as::<_, ChatRow>(&CHAT_ROWS)
        .bind(me)
        .fetch_all(db)
        .await?;
    let ids: Vec<i64> = rows.iter().map(|r| r.id).collect();
    let streaks = crate::streaks::for_chats(db, me, &ids, offset_minutes).await?;
    let last_ids: Vec<i64> = rows.iter().filter_map(|r| r.last_id).collect();
    let mut newest = db::messages_by_id(db, &last_ids).await?;
    let i_share = crate::presence::shares(db, me).await?;
    let at = now();
    let mut chats = Vec::with_capacity(rows.len());
    for row in rows {
        let last_message = row.last_id.and_then(|id| newest.remove(&id));
        let renamed = row
            .was
            .zip(row.renamed_at)
            .filter(|(_, until)| at - until < crate::usernames::SHOW_RENAME_SECS);
        let (muted, muted_until) = crate::marks::muted(row.muted_raw, at);
        chats.push(ChatSummary {
            id: row.id,
            username: row.username,
            display_name: row.display_name,
            nickname: row.nickname,
            avatar_id: row.avatar_id,
            public_key: row.public_key,
            key_reset_at: row.key_reset_at,
            active_now: (i_share && row.share_activity && !row.deactivated && !row.system)
                .then(|| online(row.id)),
            last_seen_at: if i_share && row.share_activity && !row.deactivated {
                row.last_seen_at
            } else {
                None
            },
            hidden: crate::marks::is_hidden(row.hidden_upto, row.last_id),
            favorite: row.favorite.unwrap_or(false),
            birthday: row.birthday,
            streak: streaks.get(&row.id).map_or(0, |s| s.current),
            streak_expiring: streaks.get(&row.id).is_some_and(|s| s.expiring),
            muted,
            muted_until,
            last_message,
            unread: row.unread,
            deactivated: row.deactivated,
            system: row.system,
            was: renamed.as_ref().map(|(name, _)| name.clone()),
            renamed_at: renamed.map(|(_, until)| until),
        });
    }
    chats.sort_by(|a, b| {
        let ka = a.last_message.as_ref().map(|m| m.id).unwrap_or(0);
        let kb = b.last_message.as_ref().map(|m| m.id).unwrap_or(0);
        kb.cmp(&ka)
            .then_with(|| a.username.to_lowercase().cmp(&b.username.to_lowercase()))
    });
    Ok(chats)
}

#[derive(Serialize, FromRow)]
pub struct RequestEntry {
    id: i64,
    username: String,
    created_at: i64,
}

#[derive(Serialize)]
pub struct Requests {
    incoming: Vec<RequestEntry>,
    outgoing: Vec<RequestEntry>,
}

pub async fn list_requests(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Requests>> {
    let incoming = sqlx::query_as::<_, RequestEntry>(
        "SELECT u.id, u.username, r.created_at FROM friend_requests r
         JOIN users u ON u.id = r.from_id
         WHERE r.to_id = ? AND r.resolved_at IS NULL ORDER BY r.created_at DESC",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    let outgoing = sqlx::query_as::<_, RequestEntry>(
        "SELECT u.id, u.username, r.created_at FROM friend_requests r
         JOIN users u ON u.id = r.to_id
         WHERE r.from_id = ? AND r.resolved_at IS NULL ORDER BY r.created_at DESC",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(Requests { incoming, outgoing }))
}

#[derive(Deserialize)]
pub struct AddFriend {
    username: String,
}

/// Appends to the friendship history. Never updated or deleted.
pub async fn record_event<'e, E: sqlx::SqliteExecutor<'e>>(
    db: E,
    actor: i64,
    other: i64,
    kind: &str,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO friend_events (actor_id, other_id, kind, created_at) VALUES (?, ?, ?, ?)",
    )
    .bind(actor)
    .bind(other)
    .bind(kind)
    .bind(now())
    .execute(db)
    .await
    .map(|_| ())
}

/// `accepter` says yes: pending requests between the two are resolved as
/// accepted, and the friendship starts (or restarts, if they were friends before).
pub async fn make_friends(db: &SqlitePool, accepter: i64, other: i64) -> sqlx::Result<()> {
    let (lo, hi) = pair(accepter, other);
    let at = now();
    let mut tx = crate::db::write_tx(db).await?;
    sqlx::query(
        "UPDATE friend_requests SET resolved_at = ?, resolution = 'accepted'
         WHERE ((from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)) AND resolved_at IS NULL",
    )
    .bind(at)
    .bind(accepter)
    .bind(other)
    .bind(other)
    .bind(accepter)
    .execute(&mut *tx)
    .await?;
    // A past friendship reuses its row; friend_events keeps when it started before.
    sqlx::query(
        "INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (?, ?, ?)
         ON CONFLICT (user_lo, user_hi) DO UPDATE
           SET created_at = excluded.created_at, ended_at = NULL, ended_by = NULL
           WHERE friendships.ended_at IS NOT NULL",
    )
    .bind(lo)
    .bind(hi)
    .bind(at)
    .execute(&mut *tx)
    .await?;
    record_event(&mut *tx, accepter, other, "accepted").await?;
    tx.commit().await
}

pub async fn send_request(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<AddFriend>,
) -> AppResult<Json<Value>> {
    if !state.friend_request_limit.allow(&me.id.to_string()) {
        return Err(AppError::TooManyRequests(
            "That's a lot of friend requests for one day. Try again tomorrow.".into(),
        ));
    }
    // A turned-off account can't be found (admin_users.rs).
    // By their username, or one they had: an old name still finds them (usernames.rs).
    let target = sqlx::query_as::<_, UserPublic>(&format!(
        "SELECT id, username FROM users u
         WHERE (username = ?1 OR id IN (SELECT user_id FROM past_usernames WHERE username = ?1))
           AND NOT {DEACTIVATED} AND NOT {SYSTEM}"
    ))
    .bind(req.username.trim())
    .fetch_optional(&state.db)
    .await?
    .ok_or_else(|| AppError::not_found("No one has that username."))?;

    if target.id == me.id {
        return Err(AppError::bad("That's you."));
    }
    if db::are_friends(&state.db, me.id, target.id).await? {
        return Err(AppError::Conflict(format!(
            "You're already friends with {}.",
            target.username
        )));
    }

    // If they already asked us, sending a request back just accepts theirs.
    let reverse: Option<(i64,)> = sqlx::query_as(
        "SELECT 1 FROM friend_requests WHERE from_id = ? AND to_id = ? AND resolved_at IS NULL",
    )
    .bind(target.id)
    .bind(me.id)
    .fetch_optional(&state.db)
    .await?;

    let status = if reverse.is_some() {
        make_friends(&state.db, me.id, target.id).await?;
        "friends"
    } else {
        // Asking again after a decline or cancel reopens the same row; the
        // earlier outcome stays in friend_events.
        let opened = sqlx::query(
            "INSERT INTO friend_requests (from_id, to_id, created_at) VALUES (?, ?, ?)
             ON CONFLICT (from_id, to_id) DO UPDATE
               SET created_at = excluded.created_at, resolved_at = NULL, resolution = NULL
               WHERE friend_requests.resolved_at IS NOT NULL",
        )
        .bind(me.id)
        .bind(target.id)
        .bind(now())
        .execute(&state.db)
        .await?
        .rows_affected();
        if opened > 0 {
            record_event(&state.db, me.id, target.id, "requested").await?;
        }
        "requested"
    };

    tracing::info!(from = me.id, to = target.id, status, "friend request");
    state
        .hub
        .send_both(me.id, target.id, &Event::FriendsChanged);
    // Not friends yet, so the username: display names are friends-only.
    let note = if status == "friends" {
        crate::push::Note {
            title: crate::people::name_for(&state.db, target.id, me.id).await?,
            body: "You're friends now".into(),
            tag: format!("dm-{}", me.id),
            url: format!("/#chat={}", me.id),
        }
    } else {
        crate::push::Note {
            title: "napsack".into(),
            body: format!("{} wants to be friends", me.username),
            tag: "requests".into(),
            url: "/#friends".into(),
        }
    };
    crate::push::notify(&state, target.id, note);
    Ok(Json(json!({ "status": status, "user": target })))
}

pub async fn accept(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    let exists: Option<(i64,)> = sqlx::query_as(
        "SELECT 1 FROM friend_requests WHERE from_id = ? AND to_id = ? AND resolved_at IS NULL",
    )
    .bind(user_id)
    .bind(me.id)
    .fetch_optional(&state.db)
    .await?;
    if exists.is_none() {
        return Err(AppError::not_found("That friend request no longer exists."));
    }
    make_friends(&state.db, me.id, user_id).await?;
    tracing::info!(
        user_id = me.id,
        friend_id = user_id,
        "friend request accepted"
    );
    state.hub.send_both(me.id, user_id, &Event::FriendsChanged);
    crate::push::notify(
        &state,
        user_id,
        crate::push::Note {
            title: crate::people::name_for(&state.db, user_id, me.id).await?,
            body: "Accepted your friend request".into(),
            tag: format!("dm-{}", me.id),
            url: format!("/#chat={}", me.id),
        },
    );
    Ok(Json(json!({ "status": "friends" })))
}

/// Declines an incoming request or cancels an outgoing one. The request is
/// marked resolved, not removed.
pub async fn delete_request(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    let at = now();
    for (from, to, resolution) in [(me.id, user_id, "canceled"), (user_id, me.id, "declined")] {
        let changed = sqlx::query(
            "UPDATE friend_requests SET resolved_at = ?, resolution = ?
             WHERE from_id = ? AND to_id = ? AND resolved_at IS NULL",
        )
        .bind(at)
        .bind(resolution)
        .bind(from)
        .bind(to)
        .execute(&state.db)
        .await?
        .rows_affected();
        if changed > 0 {
            record_event(&state.db, me.id, user_id, resolution).await?;
            tracing::info!(
                user_id = me.id,
                other_id = user_id,
                resolution,
                "friend request resolved"
            );
        }
    }
    state.hub.send_both(me.id, user_id, &Event::FriendsChanged);
    Ok(Json(json!({ "ok": true })))
}

pub async fn remove(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(user_id): Path<i64>,
) -> AppResult<Json<Value>> {
    // Ends the friendship but keeps the row (and every message). Chats and
    // profiles only see current friendships.
    let (lo, hi) = pair(me.id, user_id);
    let ended = sqlx::query(
        "UPDATE friendships SET ended_at = ?, ended_by = ?
         WHERE user_lo = ? AND user_hi = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(me.id)
    .bind(lo)
    .bind(hi)
    .execute(&state.db)
    .await?
    .rows_affected();
    if ended > 0 {
        record_event(&state.db, me.id, user_id, "unfriended").await?;
        tracing::info!(user_id = me.id, friend_id = user_id, "unfriended");
    }
    state.hub.send_both(me.id, user_id, &Event::FriendsChanged);
    Ok(Json(json!({ "ok": true })))
}

/// `u` is an account the server speaks for, like Team Napsack (team.rs).
const SYSTEM: &str = "EXISTS(SELECT 1 FROM system_accounts s WHERE s.user_id = u.id)";

/// `u` (a user row in the query) has had their account turned off (admin_users.rs).
const DEACTIVATED: &str =
    "EXISTS(SELECT 1 FROM deactivations d WHERE d.user_id = u.id AND d.reactivated_at IS NULL)";

/// For sending something to a friend (a text, a pic, a reaction): they must
/// be a friend, and their account must be on. Reading history needs only
/// `require_friend`, so a turned-off friend's chat stays readable.
pub async fn require_reachable(state: &SharedState, me: i64, friend: i64) -> AppResult<()> {
    require_friend(state, me, friend).await?;
    if crate::admin_users::is_deactivated(&state.db, friend).await? {
        return Err(AppError::bad(
            "That account has been turned off, so it can't get messages.",
        ));
    }
    Ok(())
}

/// For reading a chat and marking it (read, favorite, hide, mute): a friend,
/// or Team Napsack once it has sent you something.
pub async fn require_friend_or_team(state: &SharedState, me: i64, other: i64) -> AppResult<()> {
    if crate::team::id(&state.db).await? == Some(other) {
        return Ok(());
    }
    require_friend(state, me, other).await
}

/// Shared guard for chat endpoints.
pub async fn require_friend(state: &SharedState, me: i64, friend: i64) -> AppResult<()> {
    if db::are_friends(&state.db, me, friend).await? {
        Ok(())
    } else {
        Err(AppError::not_found("You can only message friends."))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::db::tests::{assert_searches, temp_db};
    use crate::testdata::{self, *};

    /// The chat list as it was built before migration 0028 (a query per
    /// friend for their newest message and past usernames, and streaks from
    /// every pic ever): what `chats_for` must match exactly. `was` and
    /// `renamed_at` are read as before, from `past_of`.
    pub(crate) async fn old_chats(
        db: &SqlitePool,
        me: i64,
        offset_minutes: i64,
        online: impl Fn(i64) -> bool,
    ) -> Vec<ChatSummary> {
        let streaks = crate::streaks::tests::old_for_friends(db, me, offset_minutes)
            .await
            .unwrap();
        let rows = sqlx::query_as::<_, ChatRow>(&format!(
            "SELECT u.id, u.username, u.public_key, u.key_reset_at, u.share_activity, u.last_seen_at,
                {DISPLAY_NAME} AS display_name, {NICKNAME} AS nickname, {AVATAR_ID} AS avatar_id,
                {FAVORITE_FRIEND} AS favorite, {HIDDEN_UPTO} AS hidden_upto, {BIRTHDAY_MD} AS birthday, {MUTED_FRIEND} AS muted_raw,
                {DEACTIVATED} AS deactivated, {SYSTEM} AS system,
                (SELECT m.id FROM messages m
                  WHERE (m.sender_id = ?1 AND m.recipient_id = u.id)
                     OR (m.sender_id = u.id AND m.recipient_id = ?1)
                  ORDER BY m.id DESC LIMIT 1) AS last_id,
                (SELECT COUNT(*) FROM messages m
                  WHERE m.sender_id = u.id AND m.recipient_id = ?1
                    AND ((m.kind = 'text' AND m.read_at IS NULL)
                      OR (m.kind = 'snap' AND m.snap_state = 'pending'))
                    AND m.created_at > {SINCE_MY_KEY}) AS unread,
                NULL AS was, NULL AS renamed_at
             FROM users u
             WHERE u.id IN (SELECT CASE WHEN f.user_lo = ?1 THEN f.user_hi ELSE f.user_lo END
                            FROM friendships f WHERE (f.user_lo = ?1 OR f.user_hi = ?1) AND f.ended_at IS NULL)
                OR ({SYSTEM} AND EXISTS (SELECT 1 FROM messages m WHERE m.sender_id = u.id AND m.recipient_id = ?1))"
        ))
        .bind(me)
        .fetch_all(db)
        .await
        .unwrap();
        let i_share = crate::presence::shares(db, me).await.unwrap();
        let mut chats = Vec::with_capacity(rows.len());
        for row in rows {
            let last_message = match row.last_id {
                Some(id) => db::get_message(db, id).await.unwrap(),
                None => None,
            };
            let renamed = crate::usernames::past_of(db, row.id)
                .await
                .unwrap()
                .into_iter()
                .next()
                .filter(|(_, at)| now() - at < crate::usernames::SHOW_RENAME_SECS);
            chats.push(ChatSummary {
                id: row.id,
                username: row.username,
                display_name: row.display_name,
                nickname: row.nickname,
                avatar_id: row.avatar_id,
                public_key: row.public_key,
                key_reset_at: row.key_reset_at,
                active_now: (i_share && row.share_activity && !row.deactivated && !row.system)
                    .then(|| online(row.id)),
                last_seen_at: if i_share && row.share_activity && !row.deactivated {
                    row.last_seen_at
                } else {
                    None
                },
                hidden: crate::marks::is_hidden(row.hidden_upto, row.last_id),
                favorite: row.favorite.unwrap_or(false),
                birthday: row.birthday,
                streak: streaks.get(&row.id).map_or(0, |s| s.current),
                streak_expiring: streaks.get(&row.id).is_some_and(|s| s.expiring),
                muted: crate::marks::muted(row.muted_raw, now()).0,
                muted_until: crate::marks::muted(row.muted_raw, now()).1,
                last_message,
                unread: row.unread,
                deactivated: row.deactivated,
                system: row.system,
                was: renamed.as_ref().map(|(name, _)| name.clone()),
                renamed_at: renamed.map(|(_, at)| at),
            });
        }
        chats.sort_by(|a, b| {
            let ka = a.last_message.as_ref().map(|m| m.id).unwrap_or(0);
            let kb = b.last_message.as_ref().map(|m| m.id).unwrap_or(0);
            kb.cmp(&ka)
                .then_with(|| a.username.to_lowercase().cmp(&b.username.to_lowercase()))
        });
        chats
    }

    /// Everyone's chat list in the mix, in three time zones: exactly what
    /// the old queries made, field for field and in the same order.
    #[tokio::test]
    async fn chat_lists_are_what_they_were() {
        let db = temp_db().await;
        testdata::mix(&db).await;
        let online = |id: i64| id == BEN || id == JO;
        for me in PEOPLE {
            for tz in [0, -300, 840] {
                let old = serde_json::to_value(old_chats(&db, me, tz, online).await).unwrap();
                let new =
                    serde_json::to_value(chats_for(&db, me, tz, online).await.unwrap()).unwrap();
                assert_eq!(new, old, "{me}'s chat list, tz {tz}");
            }
        }

        // By hand, Ana's: the newest chats first; what's unread, renamed,
        // streaking, hidden, muted.
        let chats = chats_for(&db, ANA, 0, online).await.unwrap();
        let chat = |id: i64| chats.iter().find(|c| c.id == id).unwrap();
        let order: Vec<i64> = chats.iter().map(|c| c.id).collect();
        assert_eq!(
            order,
            [TEAM, JO, IVY, DEE, CAL, BEN, EVE],
            "by newest message (the mix's ids follow the order it's written in); \
             Fay is no friend now, Gus never was"
        );
        let ben = chat(BEN);
        assert_eq!(
            ben.unread, 3,
            "two texts and a pic since Ana's new key, not the one before"
        );
        assert_eq!(
            (ben.streak, ben.was.as_deref(), ben.favorite, ben.muted),
            (3, Some("benjamin"), true, false)
        );
        assert_eq!(ben.active_now, Some(true));
        let cal = chat(CAL);
        assert_eq!(
            (cal.streak, cal.was.as_deref(), cal.muted),
            (70, None, false),
            "renamed too long ago; mute over"
        );
        assert_eq!(
            cal.last_message.as_ref().map(|m| m.snap_state.as_deref()),
            Some(Some("pending"))
        );
        assert!(chat(IVY).hidden && chat(IVY).muted && !chat(JO).hidden);
        assert_eq!(chat(JO).active_now, None, "Jo doesn't share activity");
        assert!(chat(TEAM).system && chat(DEE).deactivated && chat(EVE).last_message.is_none());
        let bens = chats_for(&db, BEN, 0, online).await.unwrap();
        assert_eq!(bens.iter().find(|c| c.id == ANA).unwrap().unread, 2);
    }

    /// Every part of the chat list is a search of an index: no read of every
    /// message, and no chat's history sorted to find its newest.
    #[tokio::test]
    async fn chat_list_searches_indexes() {
        let db = temp_db().await;
        assert_searches(&db, &CHAT_ROWS, &["s"], &["m"]).await;
        assert_searches(&db, &db::BY_IDS, &[], &["messages"]).await;
        let plan = crate::db::tests::plan(&db, &CHAT_ROWS).await;
        assert!(
            plan.iter().any(|s| s.contains("INDEX messages_waiting")),
            "unread counts read the small index: {plan:#?}"
        );
        let newest_each_way = plan
            .iter()
            .filter(|s| s.contains("COVERING INDEX messages_pair (sender_id=? AND recipient_id=?)"))
            .count();
        assert_eq!(newest_each_way, 2, "{plan:#?}");
    }
}
