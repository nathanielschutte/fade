//! Group chats. Version 1 is NOT end-to-end encrypted (messages are stored as
//! plain text, `format` 0), and clients say so in every group; direct chats
//! stay end-to-end encrypted. Nothing is deleted: leaving or removal sets
//! `left_at`, and membership and name changes are posted into the group as
//! `event` messages, which doubles as its history.
//!
//! Rules: any member can add their own friends and rename the group; only the
//! owner removes other people; anyone can leave. When the owner leaves, the
//! longest-standing member becomes owner. Members see messages from when they
//! (last) joined, by message id (`visible_after_id`).

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    db::{self, now},
    error::{AppError, AppResult},
    ws::Event,
    SharedState,
};

const MAX_NAME_CHARS: usize = 40;
pub const MAX_MEMBERS: i64 = 32;
const MAX_TEXT_CHARS: usize = 2000;
/// `format` of an unencrypted group message.
pub const FORMAT_PLAINTEXT: i64 = 0;

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct GroupMessage {
    pub id: i64,
    pub group_id: i64,
    pub sender_id: i64,
    pub sender_name: String,
    /// "text" or "event"
    pub kind: String,
    /// The text, or for events a JSON object like {"type":"added","target":5,"target_name":"ben"}.
    pub body: String,
    pub format: i64,
    pub created_at: i64,
    /// Set on a message that carries a pic (see group_pics.rs).
    pub pic_id: Option<i64>,
    /// The message this one replies to, in the same group.
    pub reply_to: Option<i64>,
    #[sqlx(skip)]
    pub pic: Option<crate::group_pics::PicInfo>,
    #[sqlx(skip)]
    pub reactions: Vec<crate::reactions::GroupReaction>,
}

const GM_SELECT: &str = "SELECT gm.id, gm.group_id, gm.sender_id, u.username AS sender_name,
        gm.kind, gm.body, gm.format, gm.created_at, gm.pic_id, gm.reply_to
     FROM group_messages gm JOIN users u ON u.id = gm.sender_id";

#[derive(Debug, Serialize, FromRow)]
pub struct Member {
    pub id: i64,
    pub username: String,
    pub role: String,
    pub joined_at: i64,
    pub added_by: Option<i64>,
}

#[derive(Serialize)]
pub struct GroupSummary {
    id: i64,
    name: String,
    role: String,
    member_count: i64,
    last_message: Option<GroupMessage>,
    unread: i64,
    /// Current group picture, for `GET /api/groups/{id}/avatar/{avatar_id}`.
    avatar_id: Option<i64>,
    /// Always false in version 1. Clients show a notice when it's false.
    encrypted: bool,
}

#[derive(Serialize)]
pub struct GroupDetail {
    id: i64,
    name: String,
    created_at: i64,
    created_by: i64,
    role: String,
    encrypted: bool,
    avatar_id: Option<i64>,
    members: Vec<Member>,
}

// ---------- helpers ----------

fn not_found() -> AppError {
    AppError::not_found("That group doesn't exist, or you're not in it.")
}

fn clean_name(raw: &str) -> AppResult<String> {
    crate::text::check_name(raw).map_err(AppError::bad)?;
    let name = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let chars = name.chars().count();
    if chars == 0 || chars > MAX_NAME_CHARS {
        return Err(AppError::bad(format!(
            "Group names are 1 to {MAX_NAME_CHARS} characters."
        )));
    }
    Ok(name)
}

/// (role, visible_after_id) if `user` is currently in `group`.
pub async fn membership(
    db: &SqlitePool,
    group: i64,
    user: i64,
) -> sqlx::Result<Option<(String, i64)>> {
    sqlx::query_as(
        "SELECT role, visible_after_id FROM group_members
         WHERE group_id = ? AND user_id = ? AND left_at IS NULL",
    )
    .bind(group)
    .bind(user)
    .fetch_optional(db)
    .await
}

pub async fn require_member(db: &SqlitePool, group: i64, user: i64) -> AppResult<(String, i64)> {
    membership(db, group, user).await?.ok_or_else(not_found)
}

pub async fn member_ids(db: &SqlitePool, group: i64) -> sqlx::Result<Vec<i64>> {
    sqlx::query_scalar("SELECT user_id FROM group_members WHERE group_id = ? AND left_at IS NULL")
        .bind(group)
        .fetch_all(db)
        .await
}

pub async fn members(db: &SqlitePool, group: i64) -> sqlx::Result<Vec<Member>> {
    sqlx::query_as(
        "SELECT u.id, u.username, m.role, m.joined_at, m.added_by
         FROM group_members m JOIN users u ON u.id = m.user_id
         WHERE m.group_id = ? AND m.left_at IS NULL
         ORDER BY m.role = 'owner' DESC, lower(u.username)",
    )
    .bind(group)
    .fetch_all(db)
    .await
}

pub async fn get_message(db: &SqlitePool, id: i64) -> sqlx::Result<GroupMessage> {
    let mut m: GroupMessage = sqlx::query_as(&format!("{GM_SELECT} WHERE gm.id = ?"))
        .bind(id)
        .fetch_one(db)
        .await?;
    crate::group_pics::attach(db, std::slice::from_mut(&mut m)).await?;
    crate::reactions::attach_group(db, std::slice::from_mut(&mut m)).await?;
    Ok(m)
}

/// Notifies everyone in the group but `sender` ("Ana: new message"), each
/// with the name they know the sender by.
pub async fn notify_members(
    state: &SharedState,
    group: i64,
    sender: i64,
    what: &str,
) -> sqlx::Result<()> {
    let name: String = sqlx::query_scalar("SELECT name FROM groups WHERE id = ?")
        .bind(group)
        .fetch_one(&state.db)
        .await?;
    for member in member_ids(&state.db, group).await? {
        if member == sender {
            continue;
        }
        let who = crate::people::name_for(&state.db, member, sender).await?;
        crate::push::notify(
            state,
            member,
            crate::push::Note {
                title: name.clone(),
                body: format!("{who}: {what}"),
                tag: format!("group-{group}"),
                url: format!("/#group={group}"),
            },
        );
    }
    Ok(())
}

pub async fn post<'e, E: sqlx::SqliteExecutor<'e>>(
    db: E,
    group: i64,
    sender: i64,
    kind: &str,
    body: &str,
) -> sqlx::Result<i64> {
    sqlx::query_scalar(
        "INSERT INTO group_messages (group_id, sender_id, kind, body, format, created_at)
         VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(group)
    .bind(sender)
    .bind(kind)
    .bind(body)
    .bind(FORMAT_PLAINTEXT)
    .bind(now())
    .fetch_one(db)
    .await
}

async fn username(db: &SqlitePool, id: i64) -> sqlx::Result<String> {
    sqlx::query_scalar("SELECT username FROM users WHERE id = ?")
        .bind(id)
        .fetch_one(db)
        .await
}

/// Sends a new group message to everyone currently in the group.
pub async fn broadcast(state: &SharedState, message: GroupMessage) -> sqlx::Result<()> {
    let ids = member_ids(&state.db, message.group_id).await?;
    state.hub.send_many(
        &ids,
        &Event::GroupMessage {
            group_id: message.group_id,
            message,
        },
    );
    Ok(())
}

async fn detail(db: &SqlitePool, group: i64, role: String) -> AppResult<GroupDetail> {
    let (name, created_at, created_by): (String, i64, i64) =
        sqlx::query_as("SELECT name, created_at, created_by FROM groups WHERE id = ?")
            .bind(group)
            .fetch_one(db)
            .await?;
    Ok(GroupDetail {
        id: group,
        name,
        created_at,
        created_by,
        role,
        encrypted: false,
        avatar_id: crate::group_pics::current_avatar(db, group).await?,
        members: members(db, group).await?,
    })
}

// ---------- handlers ----------

#[derive(FromRow)]
struct SummaryRow {
    id: i64,
    name: String,
    role: String,
    member_count: i64,
    last_id: Option<i64>,
    unread: i64,
}

/// `GET /api/groups`: the caller's current groups, newest activity first.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Vec<GroupSummary>>> {
    let rows = sqlx::query_as::<_, SummaryRow>(
        "SELECT g.id, g.name, m.role,
            (SELECT COUNT(*) FROM group_members x WHERE x.group_id = g.id AND x.left_at IS NULL) AS member_count,
            (SELECT MAX(gm.id) FROM group_messages gm
              WHERE gm.group_id = g.id AND gm.id > m.visible_after_id) AS last_id,
            (SELECT COUNT(*) FROM group_messages gm
              WHERE gm.group_id = g.id AND gm.id > m.last_read_id AND gm.kind = 'text'
                AND gm.sender_id != ?1 AND gm.id > m.visible_after_id) AS unread
         FROM group_members m JOIN groups g ON g.id = m.group_id
         WHERE m.user_id = ?1 AND m.left_at IS NULL",
    )
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    let mut out = Vec::with_capacity(rows.len());
    for r in rows {
        let last_message = match r.last_id {
            Some(id) => Some(get_message(&state.db, id).await?),
            None => None,
        };
        out.push(GroupSummary {
            id: r.id,
            name: r.name,
            role: r.role,
            member_count: r.member_count,
            last_message,
            unread: r.unread,
            encrypted: false,
            avatar_id: crate::group_pics::current_avatar(&state.db, r.id).await?,
        });
    }
    out.sort_by_key(|g| std::cmp::Reverse(g.last_message.as_ref().map_or(0, |m| m.id)));
    Ok(Json(out))
}

#[derive(Deserialize)]
pub struct NewGroup {
    name: String,
    #[serde(default)]
    member_ids: Vec<i64>,
}

/// `POST /api/groups`: the caller becomes owner; everyone else must be their friend.
pub async fn create(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<NewGroup>,
) -> AppResult<Json<GroupDetail>> {
    if !state.group_create_limit.allow(&me.id.to_string()) {
        return Err(AppError::TooManyRequests(
            "That's a lot of new groups for one day. Try again tomorrow.".into(),
        ));
    }
    let name = clean_name(&req.name)?;
    let mut ids = req.member_ids;
    ids.sort_unstable();
    ids.dedup();
    ids.retain(|&id| id != me.id);
    if ids.len() as i64 + 1 > MAX_MEMBERS {
        return Err(AppError::bad(format!(
            "Groups can have up to {MAX_MEMBERS} people."
        )));
    }
    for &id in &ids {
        if !db::are_friends(&state.db, me.id, id).await? {
            return Err(AppError::bad("You can only add your friends to a group."));
        }
    }

    let at = now();
    let mut tx = state.db.begin().await?;
    let group: i64 = sqlx::query_scalar(
        "INSERT INTO groups (name, created_by, created_at) VALUES (?, ?, ?) RETURNING id",
    )
    .bind(&name)
    .bind(me.id)
    .bind(at)
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO group_members (group_id, user_id, role, added_by, joined_at)
         VALUES (?, ?, 'owner', NULL, ?)",
    )
    .bind(group)
    .bind(me.id)
    .bind(at)
    .execute(&mut *tx)
    .await?;
    for &id in &ids {
        sqlx::query(
            "INSERT INTO group_members (group_id, user_id, role, added_by, joined_at)
             VALUES (?, ?, 'member', ?, ?)",
        )
        .bind(group)
        .bind(id)
        .bind(me.id)
        .bind(at)
        .execute(&mut *tx)
        .await?;
    }
    let event = json!({ "type": "created", "name": name }).to_string();
    let first = post(&mut *tx, group, me.id, "event", &event).await?;
    tx.commit().await?;

    tracing::info!(
        group_id = group,
        user_id = me.id,
        members = ids.len() + 1,
        "group created"
    );
    let all = member_ids(&state.db, group).await?;
    state
        .hub
        .send_many(&all, &Event::GroupsChanged { group_id: group });
    broadcast(&state, get_message(&state.db, first).await?).await?;
    Ok(Json(detail(&state.db, group, "owner".into()).await?))
}

/// `GET /api/groups/{id}`: name and current members. Members only.
pub async fn get(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
) -> AppResult<Json<GroupDetail>> {
    let (role, _) = require_member(&state.db, group, me.id).await?;
    Ok(Json(detail(&state.db, group, role).await?))
}

#[derive(Deserialize)]
pub struct Rename {
    name: String,
}

/// `PATCH /api/groups/{id}`: any member can rename it.
pub async fn rename(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    Json(req): Json<Rename>,
) -> AppResult<Json<GroupDetail>> {
    let (role, _) = require_member(&state.db, group, me.id).await?;
    let name = clean_name(&req.name)?;
    let mut tx = state.db.begin().await?;
    sqlx::query("UPDATE groups SET name = ? WHERE id = ?")
        .bind(&name)
        .bind(group)
        .execute(&mut *tx)
        .await?;
    let id = post(
        &mut *tx,
        group,
        me.id,
        "event",
        &json!({ "type": "renamed", "name": name }).to_string(),
    )
    .await?;
    tx.commit().await?;
    tracing::info!(group_id = group, user_id = me.id, "group renamed");
    let all = member_ids(&state.db, group).await?;
    state
        .hub
        .send_many(&all, &Event::GroupsChanged { group_id: group });
    broadcast(&state, get_message(&state.db, id).await?).await?;
    Ok(Json(detail(&state.db, group, role).await?))
}

#[derive(Deserialize)]
pub struct AddMember {
    user_id: i64,
}

/// `POST /api/groups/{id}/members`: any member can add one of their friends.
pub async fn add_member(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    Json(req): Json<AddMember>,
) -> AppResult<Json<GroupDetail>> {
    let (role, _) = require_member(&state.db, group, me.id).await?;
    let target = req.user_id;
    if !db::are_friends(&state.db, me.id, target).await? {
        return Err(AppError::bad("You can only add your friends to a group."));
    }
    if membership(&state.db, group, target).await?.is_some() {
        return Err(AppError::Conflict("They're already in this group.".into()));
    }
    if member_ids(&state.db, group).await?.len() as i64 >= MAX_MEMBERS {
        return Err(AppError::bad(format!(
            "Groups can have up to {MAX_MEMBERS} people."
        )));
    }
    let target_name = username(&state.db, target).await?;
    let at = now();
    let mut tx = state.db.begin().await?;
    // Rejoining reuses the row; the earlier membership is in the group's events.
    sqlx::query(
        "INSERT INTO group_members (group_id, user_id, role, added_by, joined_at, visible_after_id)
         VALUES (?1, ?2, 'member', ?3, ?4,
                 (SELECT COALESCE(MAX(id), 0) FROM group_messages WHERE group_id = ?1))
         ON CONFLICT (group_id, user_id) DO UPDATE
           SET role = 'member', added_by = excluded.added_by, joined_at = excluded.joined_at,
               visible_after_id = excluded.visible_after_id,
               left_at = NULL, removed_by = NULL, last_read_id = excluded.visible_after_id
           WHERE group_members.left_at IS NOT NULL",
    )
    .bind(group)
    .bind(target)
    .bind(me.id)
    .bind(at)
    .execute(&mut *tx)
    .await?;
    let event =
        json!({ "type": "added", "target": target, "target_name": target_name }).to_string();
    let id = post(&mut *tx, group, me.id, "event", &event).await?;
    tx.commit().await?;

    tracing::info!(
        group_id = group,
        user_id = me.id,
        added = target,
        "group member added"
    );
    let all = member_ids(&state.db, group).await?;
    state
        .hub
        .send_many(&all, &Event::GroupsChanged { group_id: group });
    broadcast(&state, get_message(&state.db, id).await?).await?;
    Ok(Json(detail(&state.db, group, role).await?))
}

/// `DELETE /api/groups/{id}/members/{user_id}`: leave (yourself) or remove
/// someone (owner only). Marks the membership ended; nothing is deleted.
pub async fn remove_member(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((group, target)): Path<(i64, i64)>,
) -> AppResult<Json<Value>> {
    let (my_role, _) = require_member(&state.db, group, me.id).await?;
    let leaving = target == me.id;
    if !leaving && my_role != "owner" {
        return Err(AppError::bad("Only the group's owner can remove people."));
    }
    let (target_role, _) = membership(&state.db, group, target)
        .await?
        .ok_or_else(|| AppError::not_found("They're not in this group."))?;
    let target_name = username(&state.db, target).await?;

    let mut tx = state.db.begin().await?;
    sqlx::query(
        "UPDATE group_members SET left_at = ?, removed_by = ?
         WHERE group_id = ? AND user_id = ? AND left_at IS NULL",
    )
    .bind(now())
    .bind(if leaving { None } else { Some(me.id) })
    .bind(group)
    .bind(target)
    .execute(&mut *tx)
    .await?;
    let event = if leaving {
        json!({ "type": "left" })
    } else {
        json!({ "type": "removed", "target": target, "target_name": target_name })
    };
    let mut posted = vec![post(&mut *tx, group, me.id, "event", &event.to_string()).await?];

    // An owner who leaves hands the group to whoever has been in it longest.
    if target_role == "owner" {
        let next: Option<(i64, String)> = sqlx::query_as(
            "SELECT m.user_id, u.username FROM group_members m JOIN users u ON u.id = m.user_id
             WHERE m.group_id = ? AND m.left_at IS NULL
             ORDER BY m.joined_at, m.user_id LIMIT 1",
        )
        .bind(group)
        .fetch_optional(&mut *tx)
        .await?;
        if let Some((next_id, next_name)) = next {
            sqlx::query(
                "UPDATE group_members SET role = 'owner' WHERE group_id = ? AND user_id = ?",
            )
            .bind(group)
            .bind(next_id)
            .execute(&mut *tx)
            .await?;
            let event = json!({ "type": "owner", "target": next_id, "target_name": next_name });
            posted.push(post(&mut *tx, group, me.id, "event", &event.to_string()).await?);
        }
    }
    tx.commit().await?;

    tracing::info!(
        group_id = group,
        user_id = me.id,
        target,
        leaving,
        "group member left or removed"
    );
    let mut notify = member_ids(&state.db, group).await?;
    notify.push(target); // so the removed person's list updates too
    state
        .hub
        .send_many(&notify, &Event::GroupsChanged { group_id: group });
    for id in posted {
        broadcast(&state, get_message(&state.db, id).await?).await?;
    }
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct Page {
    before: Option<i64>,
    limit: Option<i64>,
}

/// `GET /api/groups/{id}/messages?before=&limit=`: oldest first, from when the caller joined.
pub async fn messages(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    Query(page): Query<Page>,
) -> AppResult<Json<Vec<GroupMessage>>> {
    let (_, visible_after) = require_member(&state.db, group, me.id).await?;
    let mut out: Vec<GroupMessage> = sqlx::query_as(&format!(
        "{GM_SELECT} WHERE gm.group_id = ? AND gm.id > ? AND gm.id < ?
         ORDER BY gm.id DESC LIMIT ?"
    ))
    .bind(group)
    .bind(visible_after)
    .bind(page.before.unwrap_or(i64::MAX))
    .bind(page.limit.unwrap_or(50).clamp(1, 200))
    .fetch_all(&state.db)
    .await?;
    out.reverse();
    crate::group_pics::attach(&state.db, &mut out).await?;
    crate::reactions::attach_group(&state.db, &mut out).await?;
    Ok(Json(out))
}

#[derive(Deserialize)]
pub struct NewText {
    text: String,
    /// A message in this group to reply to.
    reply_to: Option<i64>,
}

/// `POST /api/groups/{id}/messages`: plain text (not end-to-end encrypted in v1).
pub async fn send(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    Json(req): Json<NewText>,
) -> AppResult<Json<GroupMessage>> {
    let (_, visible_after) = require_member(&state.db, group, me.id).await?;
    let text = req.text.trim();
    if text.is_empty() {
        return Err(AppError::bad("Write something first."));
    }
    crate::text::check_message(text).map_err(AppError::bad)?;
    if text.chars().count() > MAX_TEXT_CHARS {
        return Err(AppError::bad(format!(
            "Messages can be at most {MAX_TEXT_CHARS} characters."
        )));
    }
    if let Some(target) = req.reply_to {
        // Only to a message in this group that the sender can see.
        let ok: Option<i64> = sqlx::query_scalar(
            "SELECT id FROM group_messages WHERE id = ? AND group_id = ? AND id > ? AND kind = 'text'",
        )
        .bind(target)
        .bind(group)
        .bind(visible_after)
        .fetch_optional(&state.db)
        .await?;
        if ok.is_none() {
            return Err(AppError::bad("That message can't be replied to."));
        }
    }
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO group_messages (group_id, sender_id, kind, body, format, created_at, reply_to)
         VALUES (?, ?, 'text', ?, ?, ?, ?) RETURNING id",
    )
    .bind(group)
    .bind(me.id)
    .bind(text)
    .bind(FORMAT_PLAINTEXT)
    .bind(now())
    .bind(req.reply_to)
    .fetch_one(&state.db)
    .await?;
    let message = get_message(&state.db, id).await?;
    tracing::debug!(
        group_id = group,
        message_id = id,
        from = me.id,
        reply = req.reply_to.is_some(),
        "group text sent"
    );
    broadcast(&state, message.clone()).await?;
    notify_members(&state, group, me.id, "new message").await?;
    Ok(Json(message))
}

/// `POST /api/groups/{id}/read`: everything up to now is read.
pub async fn mark_read(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
) -> AppResult<Json<Value>> {
    require_member(&state.db, group, me.id).await?;
    let moved = advance_read(&state.db, group, me.id).await?;
    // The caller's other devices clear their badge.
    state
        .hub
        .send(me.id, &Event::GroupsChanged { group_id: group });
    // Everyone else updates "Seen by". Only when it moved, so reading an
    // already-read chat sends nothing.
    if let Some(last_read_id) = moved {
        let others: Vec<i64> = member_ids(&state.db, group)
            .await?
            .into_iter()
            .filter(|&id| id != me.id)
            .collect();
        state.hub.send_many(
            &others,
            &Event::GroupRead {
                group_id: group,
                user_id: me.id,
                last_read_id,
            },
        );
    }
    Ok(Json(json!({ "ok": true })))
}

/// Moves `user`'s read position to the group's newest message. Returns the
/// new position if it moved forward.
async fn advance_read(db: &SqlitePool, group: i64, user: i64) -> sqlx::Result<Option<i64>> {
    let latest: i64 =
        sqlx::query_scalar("SELECT COALESCE(MAX(id), 0) FROM group_messages WHERE group_id = ?")
            .bind(group)
            .fetch_one(db)
            .await?;
    let moved = sqlx::query(
        "UPDATE group_members SET last_read_id = ?
         WHERE group_id = ? AND user_id = ? AND left_at IS NULL AND last_read_id < ?",
    )
    .bind(latest)
    .bind(group)
    .bind(user)
    .bind(latest)
    .execute(db)
    .await?
    .rows_affected();
    Ok((moved > 0).then_some(latest))
}

/// How far a current member has read, for "Seen by".
#[derive(Debug, Serialize, FromRow, PartialEq)]
pub struct ReadPosition {
    pub user_id: i64,
    pub username: String,
    pub last_read_id: i64,
}

pub async fn read_positions(db: &SqlitePool, group: i64) -> sqlx::Result<Vec<ReadPosition>> {
    sqlx::query_as(
        "SELECT m.user_id, u.username, m.last_read_id
         FROM group_members m JOIN users u ON u.id = m.user_id
         WHERE m.group_id = ? AND m.left_at IS NULL
         ORDER BY m.user_id",
    )
    .bind(group)
    .fetch_all(db)
    .await
}

/// `GET /api/groups/{id}/reads`: every current member's read position.
pub async fn reads(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
) -> AppResult<Json<Vec<ReadPosition>>> {
    require_member(&state.db, group, me.id).await?;
    Ok(Json(read_positions(&state.db, group).await?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[test]
    fn names_are_trimmed_and_bounded() {
        assert_eq!(clean_name("  road   trip  ").unwrap(), "road trip");
        assert!(clean_name("   ").is_err());
        assert!(clean_name("evil\u{202E}gpj").is_err());
        assert!(clean_name("tab\tname").is_err());
        assert!(clean_name(&"x".repeat(41)).is_err());
        assert_eq!(clean_name(&"é".repeat(40)).unwrap().chars().count(), 40);
    }

    #[tokio::test]
    async fn membership_only_counts_current_members() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        sqlx::query("INSERT INTO groups (id, name, created_by, created_at) VALUES (9, 'g', 1, 0)")
            .execute(&db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO group_members (group_id, user_id, role, joined_at) VALUES (9, 1, 'owner', 10), (9, 2, 'member', 20)")
            .execute(&db).await.unwrap();
        assert_eq!(member_ids(&db, 9).await.unwrap(), vec![1, 2]);
        assert_eq!(
            membership(&db, 9, 2).await.unwrap(),
            Some(("member".into(), 0))
        );

        sqlx::query("UPDATE group_members SET left_at = 30 WHERE group_id = 9 AND user_id = 2")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(member_ids(&db, 9).await.unwrap(), vec![1]);
        assert_eq!(membership(&db, 9, 2).await.unwrap(), None);
        let names: Vec<String> = members(&db, 9)
            .await
            .unwrap()
            .into_iter()
            .map(|m| m.username)
            .collect();
        assert_eq!(names, vec!["ana"]);
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM group_members")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rows, 2, "leaving keeps the row");
    }

    #[tokio::test]
    async fn read_positions_move_forward_and_say_when() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben"), (3, "cal")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        sqlx::query("INSERT INTO groups (id, name, created_by, created_at) VALUES (9, 'g', 1, 0)")
            .execute(&db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO group_members (group_id, user_id, role, joined_at) VALUES (9, 1, 'owner', 0), (9, 2, 'member', 0), (9, 3, 'member', 0)")
            .execute(&db).await.unwrap();
        for id in [40, 41] {
            sqlx::query("INSERT INTO group_messages (id, group_id, sender_id, kind, body, created_at) VALUES (?, 9, 1, 'text', 'hi', 0)")
                .bind(id).execute(&db).await.unwrap();
        }

        assert_eq!(advance_read(&db, 9, 2).await.unwrap(), Some(41));
        assert_eq!(
            advance_read(&db, 9, 2).await.unwrap(),
            None,
            "already there: nothing to announce"
        );
        sqlx::query("UPDATE group_members SET left_at = 5 WHERE group_id = 9 AND user_id = 3")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(
            advance_read(&db, 9, 3).await.unwrap(),
            None,
            "former members don't move"
        );

        let seen = read_positions(&db, 9).await.unwrap();
        assert_eq!(
            seen,
            vec![
                ReadPosition {
                    user_id: 1,
                    username: "ana".into(),
                    last_read_id: 0
                },
                ReadPosition {
                    user_id: 2,
                    username: "ben".into(),
                    last_read_id: 41
                },
            ]
        );
    }
}
