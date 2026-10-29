//! Group chats. Messages are end-to-end encrypted (format 3,
//! docs/implementation/group-encryption.md): the server checks a sealed
//! message's member list and hands each member only their own key. Messages
//! from before a group switched stay plain text (`format` 0), and the group's
//! name and picture, and reactions, are visible to the server; clients say
//! so in every group. Nothing is deleted: leaving or removal sets
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
    marks::{FAVORITE_GROUP, MUTED_GROUP},
    ws::Event,
    SharedState,
};

const MAX_NAME_CHARS: usize = 40;
pub const MAX_MEMBERS: i64 = 32;
const MAX_TEXT_CHARS: usize = 2000;
/// `format` of an unencrypted group message.
pub const FORMAT_PLAINTEXT: i64 = 0;
/// `format` of an end-to-end encrypted group message (docs/implementation/group-encryption.md).
pub const FORMAT_E2E: i64 = 3;
/// `format` of an end-to-end encrypted group video: the same scheme, sealed
/// as kind "video" around a media envelope (plan X28).
pub const FORMAT_E2E_VIDEO: i64 = 5;
/// `format` of an end-to-end encrypted group photo in the media envelope,
/// with where its caption sits (plan X33): kind "image".
pub const FORMAT_E2E_IMAGE: i64 = 7;

/// End-to-end encrypted: content the server can't open, a key per member.
pub fn sealed(format: i64) -> bool {
    matches!(format, FORMAT_E2E | FORMAT_E2E_VIDEO | FORMAT_E2E_IMAGE)
}
/// Every format a group message or pic can have, for `/api/config`: plain
/// text from clients that predate encryption, and the sealed ones. A client
/// that reads all of these can show any group's history.
pub const MESSAGE_FORMATS: &[i64] = &[
    FORMAT_PLAINTEXT,
    FORMAT_E2E,
    FORMAT_E2E_VIDEO,
    FORMAT_E2E_IMAGE,
];
/// A format 3 text's sealed content, decoded: the 2,000-character envelope
/// with room for escapes, plus IV and tag.
const MAX_E2E_CONTENT_BYTES: usize = 16 * 1024;
/// A wrapped message key: IV (12) + key (32) + GCM tag (16).
const WRAP_BYTES: usize = 60;

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
    /// Format 3: the sender's random message id (base64).
    pub client_id: Option<String>,
    /// Format 3: the member list the sender encrypted for, as stored (JSON).
    #[serde(skip)]
    #[sqlx(rename = "recipients")]
    pub recipients_json: Option<String>,
    /// Format 3: that member list, which readers need to check their key.
    #[sqlx(skip)]
    pub recipients: Option<Vec<i64>>,
    /// Format 3: the sealed content (base64). `body` is empty for these, so a
    /// client that predates format 3 shows nothing rather than gibberish.
    /// Pics keep theirs in the pic file.
    #[sqlx(skip)]
    pub content: Option<String>,
    /// Format 3: the viewer's own wrap of the message key. Nobody gets anyone else's.
    #[sqlx(skip)]
    pub key: Option<String>,
    /// Format 3: the sender's public key, to unwrap with. Clients check it
    /// against the key they pinned for that person.
    pub sender_public_key: Option<String>,
    /// The newest edit of an encrypted text (edits.rs): sealed with its own
    /// message id, for the same members. `content` stays the original.
    #[serde(skip)]
    pub edit_id: Option<i64>,
    pub edit_content: Option<String>,
    pub edit_client_id: Option<String>,
    pub edited_at: Option<i64>,
    /// The viewer's own wrap of that edit's key.
    #[sqlx(skip)]
    pub edit_key: Option<String>,
}

const GM_SELECT: &str = "SELECT gm.id, gm.group_id, gm.sender_id, u.username AS sender_name,
        gm.kind, gm.body, gm.format, gm.created_at, gm.pic_id, gm.reply_to,
        gm.client_id, gm.recipients, CASE WHEN gm.format IN (3, 5, 7) THEN u.public_key END AS sender_public_key,
        (SELECT e.id FROM group_message_edits e WHERE e.message_id = gm.id ORDER BY e.id DESC LIMIT 1) AS edit_id,
        (SELECT e.content FROM group_message_edits e WHERE e.message_id = gm.id ORDER BY e.id DESC LIMIT 1) AS edit_content,
        (SELECT e.client_id FROM group_message_edits e WHERE e.message_id = gm.id ORDER BY e.id DESC LIMIT 1) AS edit_client_id,
        (SELECT e.created_at FROM group_message_edits e WHERE e.message_id = gm.id ORDER BY e.id DESC LIMIT 1) AS edited_at
     FROM group_messages gm JOIN users u ON u.id = gm.sender_id";

#[derive(Debug, Serialize, FromRow)]
pub struct Member {
    pub id: i64,
    pub username: String,
    /// For encrypting to them (format 3). Clients pin it on first sight.
    pub public_key: String,
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
    /// One of my favorites. Only I see it (marks.rs).
    favorite: bool,
    /// I muted it: no notifications or unread dot (marks.rs).
    muted: bool,
    /// When that mute ends by itself; null while muted means until turned off.
    muted_until: Option<i64>,
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
        "SELECT u.id, u.username, u.public_key, m.role, m.joined_at, m.added_by
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

/// Current members whose history includes `message_id`: everyone who was in
/// the group when it was sent. Someone added later must not get it, even as
/// an update (a reaction, "opened by"), or they'd see what came before they
/// joined (for older plaintext messages, the text itself).
pub async fn audience(db: &SqlitePool, group: i64, message_id: i64) -> sqlx::Result<Vec<i64>> {
    sqlx::query_scalar(
        "SELECT user_id FROM group_members
         WHERE group_id = ? AND left_at IS NULL AND visible_after_id < ?",
    )
    .bind(group)
    .bind(message_id)
    .fetch_all(db)
    .await
}

/// Sends a group message, new or updated, to the members whose history
/// includes it (`audience`). A format 3 message goes to each with their own key.
pub async fn broadcast(state: &SharedState, message: GroupMessage) -> sqlx::Result<()> {
    let ids = audience(&state.db, message.group_id, message.id).await?;
    if !sealed(message.format) {
        state.hub.send_many(
            &ids,
            &Event::GroupMessage {
                group_id: message.group_id,
                message: Box::new(message),
            },
        );
        return Ok(());
    }
    for id in ids {
        let mut m = message.clone();
        prepare_for(&state.db, id, std::slice::from_mut(&mut m)).await?;
        state.hub.send(
            id,
            &Event::GroupMessage {
                group_id: m.group_id,
                message: Box::new(m),
            },
        );
    }
    Ok(())
}

/// Readies format 3 messages for one viewer: content out of `body`, the
/// member list parsed, and that viewer's own wrap attached (or none, if it
/// wasn't sent to them). Safe to call twice on the same message.
pub async fn prepare_for(
    db: &SqlitePool,
    viewer: i64,
    messages: &mut [GroupMessage],
) -> sqlx::Result<()> {
    for m in messages.iter_mut().filter(|m| sealed(m.format)) {
        if m.content.is_none() && m.pic_id.is_none() {
            m.content = Some(std::mem::take(&mut m.body));
        }
        m.recipients = m
            .recipients_json
            .as_deref()
            .and_then(|j| serde_json::from_str(j).ok());
        m.key = sqlx::query_scalar(
            "SELECT wrapped FROM group_message_keys WHERE message_id = ? AND user_id = ?",
        )
        .bind(m.id)
        .bind(viewer)
        .fetch_optional(db)
        .await?;
        if let Some(edit) = m.edit_id {
            m.edit_key = sqlx::query_scalar(
                "SELECT wrapped FROM group_edit_keys WHERE edit_id = ? AND user_id = ?",
            )
            .bind(edit)
            .bind(viewer)
            .fetch_optional(db)
            .await?;
        }
    }
    Ok(())
}

/// What a format 3 sender sends besides the content.
#[derive(Deserialize)]
pub struct E2eKeys {
    pub client_id: String,
    pub recipients: Vec<i64>,
    /// Member id (as a string, JSON object keys being strings) -> wrapped key.
    pub wraps: std::collections::HashMap<String, String>,
}

#[derive(Debug, PartialEq)]
pub enum E2eProblem {
    /// The sender's member list isn't the group's: they should refetch and resend.
    Stale,
    Bad(&'static str),
}

/// Checks a format 3 send against the group's current members (sorted).
/// Returns the wraps by member id.
pub fn check_e2e(members: &[i64], keys: &E2eKeys) -> Result<Vec<(i64, String)>, E2eProblem> {
    use base64::{engine::general_purpose::STANDARD, Engine};
    if STANDARD.decode(&keys.client_id).map(|b| b.len()).ok() != Some(16) {
        return Err(E2eProblem::Bad("That message id isn't valid."));
    }
    let mut recipients = keys.recipients.clone();
    recipients.sort_unstable();
    recipients.dedup();
    if recipients.len() != keys.recipients.len() {
        return Err(E2eProblem::Bad("That member list has someone twice."));
    }
    if recipients != members {
        return Err(E2eProblem::Stale);
    }
    if keys.wraps.len() != members.len() {
        return Err(E2eProblem::Bad("There has to be one key for each member."));
    }
    let mut out = Vec::with_capacity(members.len());
    for (id, wrapped) in &keys.wraps {
        let id: i64 = id
            .parse()
            .map_err(|_| E2eProblem::Bad("Keys are by member id."))?;
        if !members.contains(&id) {
            return Err(E2eProblem::Bad(
                "There's a key for someone not in the group.",
            ));
        }
        if STANDARD.decode(wrapped).map(|b| b.len()).ok() != Some(WRAP_BYTES) {
            return Err(E2eProblem::Bad("A key isn't the right size."));
        }
        out.push((id, wrapped.clone()));
    }
    out.sort_unstable();
    Ok(out)
}

impl From<E2eProblem> for AppError {
    fn from(p: E2eProblem) -> Self {
        match p {
            E2eProblem::Stale => AppError::Conflict(
                "The group changed while you were writing. Sending again.".into(),
            ),
            E2eProblem::Bad(m) => AppError::bad(m),
        }
    }
}

/// The group's first encrypted message gets an event before it: "Messages
/// here are end-to-end encrypted from now on." Call inside the send's
/// transaction. Returns the event's id, if this was the first.
pub async fn mark_encrypted_start(
    tx: &mut sqlx::SqliteConnection,
    group: i64,
    sender: i64,
    at: i64,
) -> sqlx::Result<Option<i64>> {
    let already: Option<i64> = sqlx::query_scalar(
        "SELECT id FROM group_messages WHERE group_id = ? AND format IN (3, 5, 7) LIMIT 1",
    )
    .bind(group)
    .fetch_optional(&mut *tx)
    .await?;
    if already.is_some() {
        return Ok(None);
    }
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO group_messages (group_id, sender_id, kind, body, format, created_at)
         VALUES (?, ?, 'event', ?, 0, ?) RETURNING id",
    )
    .bind(group)
    .bind(sender)
    .bind(json!({ "type": "encrypted" }).to_string())
    .bind(at)
    .fetch_one(&mut *tx)
    .await?;
    Ok(Some(id))
}

/// Stores a format 3 message's wraps. Inside the send's transaction.
pub async fn store_wraps(
    tx: &mut sqlx::SqliteConnection,
    message: i64,
    wraps: &[(i64, String)],
) -> sqlx::Result<()> {
    for (user, wrapped) in wraps {
        sqlx::query(
            "INSERT INTO group_message_keys (message_id, user_id, wrapped) VALUES (?, ?, ?)",
        )
        .bind(message)
        .bind(user)
        .bind(wrapped)
        .execute(&mut *tx)
        .await?;
    }
    Ok(())
}

/// What `sender` already stored in `group` under `client_id`, readied for
/// them: a send retried after a dropped connection gets this back, not a
/// second copy.
pub async fn stored_e2e(
    db: &SqlitePool,
    group: i64,
    sender: i64,
    client_id: &str,
) -> sqlx::Result<Option<GroupMessage>> {
    let id: Option<i64> = sqlx::query_scalar(
        "SELECT id FROM group_messages WHERE group_id = ? AND sender_id = ? AND client_id = ?",
    )
    .bind(group)
    .bind(sender)
    .bind(client_id)
    .fetch_optional(db)
    .await?;
    let Some(id) = id else { return Ok(None) };
    let mut m = get_message(db, id).await?;
    prepare_for(db, sender, std::slice::from_mut(&mut m)).await?;
    tracing::debug!(
        group_id = group,
        message_id = id,
        from = sender,
        "group message resent; already stored"
    );
    Ok(Some(m))
}

/// A replayed format 3 message hits the unique index on its message id.
pub fn replay(e: sqlx::Error) -> AppError {
    match e {
        sqlx::Error::Database(d) if d.is_unique_violation() => {
            AppError::Conflict("That message was already sent.".into())
        }
        e => e.into(),
    }
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
    favorite: Option<bool>,
    muted_raw: Option<i64>,
}

/// `GET /api/groups`: the caller's current groups, newest activity first.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Vec<GroupSummary>>> {
    let rows = sqlx::query_as::<_, SummaryRow>(&format!(
        "SELECT g.id, g.name, m.role,
            (SELECT COUNT(*) FROM group_members x WHERE x.group_id = g.id AND x.left_at IS NULL) AS member_count,
            (SELECT MAX(gm.id) FROM group_messages gm
              WHERE gm.group_id = g.id AND gm.id > m.visible_after_id) AS last_id,
            (SELECT COUNT(*) FROM group_messages gm
              WHERE gm.group_id = g.id AND gm.id > m.last_read_id AND gm.kind = 'text'
                AND gm.sender_id != ?1 AND gm.id > m.visible_after_id) AS unread,
            {FAVORITE_GROUP} AS favorite, {MUTED_GROUP} AS muted_raw
         FROM group_members m JOIN groups g ON g.id = m.group_id
         WHERE m.user_id = ?1 AND m.left_at IS NULL"
    ))
    .bind(me.id)
    .fetch_all(&state.db)
    .await?;
    let mut out = Vec::with_capacity(rows.len());
    for r in rows {
        let last_message = match r.last_id {
            Some(id) => {
                let mut m = get_message(&state.db, id).await?;
                prepare_for(&state.db, me.id, std::slice::from_mut(&mut m)).await?;
                Some(m)
            }
            None => None,
        };
        out.push(GroupSummary {
            id: r.id,
            name: r.name,
            role: r.role,
            member_count: r.member_count,
            last_message,
            unread: r.unread,
            favorite: r.favorite.unwrap_or(false),
            muted: crate::marks::muted(r.muted_raw, now()).0,
            muted_until: crate::marks::muted(r.muted_raw, now()).1,
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
    prepare_for(&state.db, me.id, &mut out).await?;
    Ok(Json(out))
}

#[derive(Deserialize)]
pub struct NewText {
    /// Format 0: the text itself.
    #[serde(default)]
    text: String,
    /// Format 0: a message in this group to reply to (format 3 replies travel
    /// inside the encrypted envelope).
    reply_to: Option<i64>,
    /// 3 for an end-to-end encrypted message; 0 or absent for plain text.
    #[serde(default)]
    format: i64,
    /// Format 3: base64 of the sealed content.
    content: Option<String>,
    /// Format 3: `client_id`, `recipients`, `wraps`.
    #[serde(flatten)]
    keys: Option<E2eKeys>,
}

/// `POST /api/groups/{id}/messages`: an end-to-end encrypted message
/// (`format` 3: `content`, `client_id`, `recipients`, `wraps`), or plain text
/// (format 0, from clients that predate encryption).
pub async fn send(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    Json(req): Json<NewText>,
) -> AppResult<Json<GroupMessage>> {
    if req.format == FORMAT_E2E {
        return send_e2e(state, me.id, group, req).await;
    }
    if req.format != FORMAT_PLAINTEXT {
        return Err(AppError::bad("Unknown message format."));
    }
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

async fn send_e2e(
    state: SharedState,
    me: i64,
    group: i64,
    req: NewText,
) -> AppResult<Json<GroupMessage>> {
    use base64::{engine::general_purpose::STANDARD, Engine};
    require_member(&state.db, group, me).await?;
    let keys = req
        .keys
        .ok_or_else(|| AppError::bad("An encrypted message needs its keys."))?;
    let content = req.content.unwrap_or_default();
    let size = STANDARD.decode(&content).map(|b| b.len()).unwrap_or(0);
    if !(12 + 16 + 1..=MAX_E2E_CONTENT_BYTES).contains(&size) {
        return Err(AppError::bad("That message is empty or too long."));
    }
    if let Some(stored) = stored_e2e(&state.db, group, me, &keys.client_id).await? {
        return Ok(Json(stored));
    }
    let mut members = member_ids(&state.db, group).await?;
    members.sort_unstable();
    let wraps = check_e2e(&members, &keys)?;
    let recipients =
        serde_json::to_string(&members).map_err(|e| AppError::Internal(e.to_string()))?;
    let at = now();
    let mut tx = state.db.begin().await?;
    let started = mark_encrypted_start(&mut tx, group, me, at).await?;
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO group_messages (group_id, sender_id, kind, body, format, created_at, client_id, recipients)
         VALUES (?, ?, 'text', ?, 3, ?, ?, ?) RETURNING id",
    )
    .bind(group)
    .bind(me)
    .bind(&content)
    .bind(at)
    .bind(&keys.client_id)
    .bind(&recipients)
    .fetch_one(&mut *tx)
    .await
    .map_err(replay)?;
    store_wraps(&mut tx, id, &wraps).await?;
    tx.commit().await?;
    tracing::debug!(
        group_id = group,
        message_id = id,
        from = me,
        "group text sent, encrypted"
    );
    if let Some(event) = started {
        tracing::info!(group_id = group, "group switched to end-to-end encryption");
        broadcast(&state, get_message(&state.db, event).await?).await?;
    }
    let message = get_message(&state.db, id).await?;
    broadcast(&state, message.clone()).await?;
    notify_members(&state, group, me, "new message").await?;
    let mut mine = message;
    prepare_for(&state.db, me, std::slice::from_mut(&mut mine)).await?;
    Ok(Json(mine))
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
    fn config_lists_every_group_format() {
        for format in -1..16 {
            let stored = format == FORMAT_PLAINTEXT || sealed(format);
            assert_eq!(MESSAGE_FORMATS.contains(&format), stored, "format {format}");
        }
    }

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
    async fn updates_reach_only_members_who_had_the_message() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben"), (3, "cal")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        sqlx::query("INSERT INTO groups (id, name, created_by, created_at) VALUES (9, 'g', 1, 0)")
            .execute(&db)
            .await
            .unwrap();
        // Ana and Ben from the start; Cal added once message 50 had been sent; Ben left.
        sqlx::query("INSERT INTO group_members (group_id, user_id, role, joined_at, visible_after_id, left_at) VALUES (9, 1, 'owner', 10, 0, NULL), (9, 2, 'member', 10, 0, 60), (9, 3, 'member', 70, 50, NULL)")
            .execute(&db).await.unwrap();
        assert_eq!(
            audience(&db, 9, 50).await.unwrap(),
            vec![1],
            "Cal wasn't there for message 50"
        );
        let mut later = audience(&db, 9, 51).await.unwrap();
        later.sort_unstable();
        assert_eq!(later, vec![1, 3]);
        assert!(audience(&db, 8, 51).await.unwrap().is_empty());
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

    #[test]
    fn encrypted_sends_must_match_the_group_exactly() {
        use base64::{engine::general_purpose::STANDARD, Engine};
        let wrap = STANDARD.encode([7u8; 60]);
        let keys = |recipients: Vec<i64>, wraps: Vec<(&str, String)>, client_id: String| E2eKeys {
            client_id,
            recipients,
            wraps: wraps.into_iter().map(|(k, v)| (k.to_string(), v)).collect(),
        };
        let mid = STANDARD.encode([1u8; 16]);
        let members = [3, 7];
        let ok = keys(
            vec![7, 3],
            vec![("3", wrap.clone()), ("7", wrap.clone())],
            mid.clone(),
        );
        assert_eq!(
            check_e2e(&members, &ok).unwrap(),
            vec![(3, wrap.clone()), (7, wrap.clone())]
        );

        // Someone joined or left meanwhile: the sender refetches and resends.
        let stale = keys(
            vec![3, 7, 9],
            vec![
                ("3", wrap.clone()),
                ("7", wrap.clone()),
                ("9", wrap.clone()),
            ],
            mid.clone(),
        );
        assert_eq!(check_e2e(&members, &stale), Err(E2eProblem::Stale));
        assert_eq!(
            check_e2e(
                &members,
                &keys(vec![3], vec![("3", wrap.clone())], mid.clone())
            ),
            Err(E2eProblem::Stale)
        );
        // Malformed: a missing or extra key, a wrong-size key, a bad message id, a duplicate.
        for bad in [
            keys(vec![3, 7], vec![("3", wrap.clone())], mid.clone()),
            keys(
                vec![3, 7],
                vec![("3", wrap.clone()), ("9", wrap.clone())],
                mid.clone(),
            ),
            keys(
                vec![3, 7],
                vec![("3", wrap.clone()), ("7", STANDARD.encode([7u8; 59]))],
                mid.clone(),
            ),
            keys(
                vec![3, 7],
                vec![("3", wrap.clone()), ("seven", wrap.clone())],
                mid.clone(),
            ),
            keys(
                vec![3, 7],
                vec![("3", wrap.clone()), ("7", wrap.clone())],
                STANDARD.encode([1u8; 15]),
            ),
            keys(
                vec![3, 3, 7],
                vec![("3", wrap.clone()), ("7", wrap.clone())],
                mid.clone(),
            ),
        ] {
            assert!(matches!(check_e2e(&members, &bad), Err(E2eProblem::Bad(_))));
        }
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
