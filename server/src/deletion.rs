//! Deleting your own account (F22; docs/design/account-deletion.md): the one
//! exception to Rule 1, and only ever by the person themselves. Everything of
//! theirs goes in one transaction: the account, the profile, friendships,
//! every direct chat (their friends lose it), and everything they sent in
//! groups. The users row stays hollow (its id only, turned off), because
//! other people's records point at it (who created a group, who set its
//! picture), and `deleted_accounts` says when.
//!
//! The username is held for 30 days as a keyed hash, so nobody can take it
//! and pose as the person their friends just lost. A marker per deletion in
//! the backups bucket (production only) lets a restored backup be wiped again
//! at start: backups last 30 days, so after that no copy remains anywhere.
//!
//! This is the only file allowed to `DELETE` (db::tests::code_never_deletes_rows).

use axum::{extract::State, Json};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::Sha256;
use sqlx::{SqliteConnection, SqlitePool};
use std::path::Path;

use crate::{
    auth::AuthUser,
    db::now,
    error::{AppError, AppResult},
    ws::Event,
    SharedState,
};

/// How long a deleted account's username stays taken.
pub const HOLD_SECS: i64 = 30 * 86_400;
/// Where deletion markers go in the backups bucket.
const MARKERS: &str = "deletions/";

/// The key the username hold's hash is made with, made once and kept.
async fn hold_key(db: &SqlitePool) -> sqlx::Result<Vec<u8>> {
    let mut fresh = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut fresh);
    sqlx::query("INSERT OR IGNORE INTO server_keys (name, value, created_at) VALUES ('username_hold', ?, ?)")
        .bind(hex(&fresh))
        .bind(now())
        .execute(db)
        .await?;
    let stored: String =
        sqlx::query_scalar("SELECT value FROM server_keys WHERE name = 'username_hold'")
            .fetch_one(db)
            .await?;
    Ok(stored.into_bytes())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn username_hmac(key: &[u8], name: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("any key length works for HMAC");
    mac.update(name.trim().to_lowercase().as_bytes());
    hex(&mac.finalize().into_bytes())
}

/// Is `name` held: the username of an account deleted in the last 30 days?
pub async fn held(db: &SqlitePool, name: &str) -> sqlx::Result<bool> {
    let hash = username_hmac(&hold_key(db).await?, name);
    sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM deleted_accounts WHERE username_hmac = ? AND held_until > ?)",
    )
    .bind(hash)
    .bind(now())
    .fetch_one(db)
    .await
}

#[derive(Deserialize)]
pub struct DeleteRequest {
    /// The password, proven as for a password change.
    auth_key: String,
    /// The username, typed again.
    username: String,
}

/// `POST /api/me/delete`: the password and the username typed again, then
/// everything of the account goes, at once. Every session ends.
pub async fn delete(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<DeleteRequest>,
) -> AppResult<Json<Value>> {
    if crate::team::is_system(&state.db, me.id).await? {
        return Err(AppError::bad("This account can't be deleted."));
    }
    crate::account::require_password(&state, &me, &req.auth_key).await?;
    if !req.username.trim().eq_ignore_ascii_case(&me.username) {
        return Err(AppError::bad(
            "That isn't your username. Type it exactly to delete your account.",
        ));
    }
    let wiped = wipe(&state.db, &state.config.pic_dir, me.id, &me.username, now()).await?;
    after(&state, me.id, &wiped).await;
    if state.config.deletion_markers {
        mark(&state, me.id).await;
    }
    tracing::info!(
        user_id = me.id,
        friends = wiped.friends.len(),
        groups = wiped.groups.len(),
        "account deleted by its owner"
    );
    Ok(Json(json!({ "deleted": true })))
}

/// What a wipe touched, for telling the others once it's done.
#[derive(Default, Debug)]
pub struct Wiped {
    /// Friends whose list loses the chat.
    pub friends: Vec<i64>,
    /// Groups they were in, and the events posted there ("left", a new owner).
    pub groups: Vec<i64>,
    pub events: Vec<i64>,
    /// Files of pics and videos (direct by message id, group by pic id).
    pub direct_files: Vec<i64>,
    pub group_files: Vec<i64>,
}

/// Their group messages, and events about them (which name them).
/// (A CASE, so only an event's body is read as JSON: SQLite doesn't promise
/// to test `kind` first otherwise, and texts aren't JSON.)
const THEIR_GROUP_MESSAGES: &str = "SELECT id FROM group_messages
     WHERE sender_id = ?1
        OR CASE WHEN kind = 'event' AND json_valid(body) THEN json_extract(body, '$.target') END = ?1";

/// Everything of `user`'s, in one transaction. `deleted_at` is now, or (for a
/// restored backup) when they first deleted it.
pub async fn wipe(
    db: &SqlitePool,
    pic_dir: &Path,
    user: i64,
    username: &str,
    deleted_at: i64,
) -> AppResult<Wiped> {
    let hold = username_hmac(&hold_key(db).await?, username);
    let mut tx = crate::db::write_tx(db).await?;
    let mut wiped = Wiped {
        friends: sqlx::query_scalar(
            "SELECT CASE WHEN user_lo = ?1 THEN user_hi ELSE user_lo END FROM friendships
             WHERE (user_lo = ?1 OR user_hi = ?1) AND ended_at IS NULL",
        )
        .bind(user)
        .fetch_all(&mut *tx)
        .await?,
        direct_files: sqlx::query_scalar(
            "SELECT id FROM messages WHERE (sender_id = ?1 OR recipient_id = ?1) AND kind = 'snap'",
        )
        .bind(user)
        .fetch_all(&mut *tx)
        .await?,
        group_files: sqlx::query_scalar("SELECT id FROM group_pics WHERE sender_id = ?1")
            .bind(user)
            .fetch_all(&mut *tx)
            .await?,
        ..Default::default()
    };
    direct(&mut tx, user).await?;
    groups(&mut tx, user, &mut wiped).await?;
    account(&mut tx, user).await?;

    // The hollow row: nothing of theirs, turned off, so every "current"
    // filter leaves it out; and when, with the username held for 30 days.
    sqlx::query(
        "UPDATE users SET username = 'deleted:' || id, auth_hash = '', public_key = '',
            wrapped_private_key = '', created_at = 0, last_seen_at = NULL, recovery_hash = NULL,
            recovery_wrapped_key = NULL, recovery_set_at = NULL, key_reset_at = NULL, share_activity = 0
         WHERE id = ?1",
    )
    .bind(user)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO deactivations (user_id, deactivated_by, deactivated_at) VALUES (?1, ?1, ?2)",
    )
    .bind(user)
    .bind(deleted_at)
    .execute(&mut *tx)
    .await?;
    let held_until = deleted_at + HOLD_SECS;
    let holding = held_until > now();
    sqlx::query(
        "INSERT INTO deleted_accounts (user_id, deleted_at, username_hmac, held_until) VALUES (?, ?, ?, ?)",
    )
    .bind(user)
    .bind(deleted_at)
    .bind(holding.then_some(hold))
    .bind(holding.then_some(held_until))
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    for id in &wiped.direct_files {
        let _ = tokio::fs::remove_file(crate::snaps::dir(pic_dir).join(format!("{id}.bin"))).await;
    }
    for id in &wiped.group_files {
        let _ = tokio::fs::remove_file(pic_dir.join(format!("{id}.bin"))).await;
    }
    Ok(wiped)
}

/// Direct chats: every message to or from them, with what hangs off it.
async fn direct(tx: &mut SqliteConnection, user: i64) -> sqlx::Result<()> {
    for sql in [
        "DELETE FROM reactions WHERE sender_id = ?1 OR message_id IN
            (SELECT id FROM messages WHERE sender_id = ?1 OR recipient_id = ?1)",
        "DELETE FROM message_edits WHERE message_id IN
            (SELECT id FROM messages WHERE sender_id = ?1 OR recipient_id = ?1)",
        "DELETE FROM occasion_sends WHERE user_id = ?1 OR message_id IN
            (SELECT id FROM messages WHERE sender_id = ?1 OR recipient_id = ?1)",
        "DELETE FROM messages WHERE sender_id = ?1 OR recipient_id = ?1",
    ] {
        sqlx::query(sql).bind(user).execute(&mut *tx).await?;
    }
    Ok(())
}

/// Groups: everything they sent, events about them, their keys and views,
/// and their memberships. A group they owned passes to whoever has been in
/// it longest, as when an owner leaves, and each group they were in says a
/// member left.
async fn groups(tx: &mut SqliteConnection, user: i64, wiped: &mut Wiped) -> sqlx::Result<()> {
    let member_of: Vec<(i64, String)> = sqlx::query_as(
        "SELECT group_id, role FROM group_members WHERE user_id = ? AND left_at IS NULL",
    )
    .bind(user)
    .fetch_all(&mut *tx)
    .await?;
    for sql in [
        // Others' replies to theirs keep their own text, without the link.
        "UPDATE group_messages SET reply_to = NULL WHERE reply_to IN (THEIRS)",
        "DELETE FROM group_reactions WHERE user_id = ?1 OR message_id IN (THEIRS)",
        "DELETE FROM group_edit_keys WHERE user_id = ?1 OR edit_id IN
            (SELECT id FROM group_message_edits WHERE message_id IN (THEIRS))",
        "DELETE FROM group_message_edits WHERE message_id IN (THEIRS)",
        "DELETE FROM group_message_keys WHERE user_id = ?1 OR message_id IN (THEIRS)",
        "DELETE FROM group_messages WHERE id IN (THEIRS)",
        "DELETE FROM group_pic_views WHERE user_id = ?1 OR pic_id IN (SELECT id FROM group_pics WHERE sender_id = ?1)",
        "DELETE FROM group_pic_fetches WHERE user_id = ?1 OR pic_id IN (SELECT id FROM group_pics WHERE sender_id = ?1)",
        "DELETE FROM group_pics WHERE sender_id = ?1",
        "UPDATE group_members SET added_by = NULL WHERE added_by = ?1",
        "UPDATE group_members SET removed_by = NULL WHERE removed_by = ?1",
        "DELETE FROM group_members WHERE user_id = ?1",
    ] {
        sqlx::query(&sql.replace("THEIRS", THEIR_GROUP_MESSAGES))
            .bind(user)
            .execute(&mut *tx)
            .await?;
    }
    for (group, role) in member_of {
        wiped.groups.push(group);
        if role == "owner" {
            let next: Option<(i64, String)> = sqlx::query_as(
                "SELECT m.user_id, u.username FROM group_members m JOIN users u ON u.id = m.user_id
                 WHERE m.group_id = ? AND m.left_at IS NULL ORDER BY m.joined_at, m.user_id LIMIT 1",
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
                wiped.events.push(
                    crate::groups::post(&mut *tx, group, user, "event", &event.to_string()).await?,
                );
            }
        }
        let left = json!({ "type": "left" }).to_string();
        wiped
            .events
            .push(crate::groups::post(&mut *tx, group, user, "event", &left).await?);
    }
    Ok(())
}

/// The account, profile, friends, links, and marks: theirs, or about them.
async fn account(tx: &mut SqliteConnection, user: i64) -> sqlx::Result<()> {
    for sql in [
        "DELETE FROM friendships WHERE user_lo = ?1 OR user_hi = ?1",
        "DELETE FROM friend_requests WHERE from_id = ?1 OR to_id = ?1",
        "DELETE FROM friend_events WHERE actor_id = ?1 OR other_id = ?1",
        "DELETE FROM invite_uses WHERE user_id = ?1 OR invite_id IN (SELECT id FROM invites WHERE created_by = ?1)",
        "DELETE FROM invites WHERE created_by = ?1",
        "DELETE FROM chat_marks WHERE user_id = ?1 OR friend_id = ?1",
        "DELETE FROM chat_mutes WHERE user_id = ?1 OR friend_id = ?1",
        "DELETE FROM user_names WHERE user_id = ?1 OR set_by = ?1",
        "DELETE FROM user_avatars WHERE user_id = ?1",
        "DELETE FROM user_birthdays WHERE user_id = ?1",
        "DELETE FROM credential_history WHERE user_id = ?1",
        "DELETE FROM reset_codes WHERE user_id = ?1",
        "DELETE FROM sessions WHERE user_id = ?1",
        "DELETE FROM push_subscriptions WHERE user_id = ?1",
        "DELETE FROM apns_devices WHERE user_id = ?1",
        "DELETE FROM passkeys WHERE user_id = ?1",
        "DELETE FROM past_usernames WHERE user_id = ?1",
        "DELETE FROM user_roles WHERE user_id = ?1",
        "DELETE FROM user_role_upgrades WHERE user_id = ?1",
        "DELETE FROM deactivations WHERE user_id = ?1",
        "DELETE FROM admin_actions WHERE target_user_id = ?1",
    ] {
        sqlx::query(sql).bind(user).execute(&mut *tx).await?;
    }
    Ok(())
}

/// Tells everyone affected: their sockets close, friends' lists refresh,
/// groups get their events.
async fn after(state: &SharedState, user: i64, wiped: &Wiped) {
    state.hub.end_sessions(user, None);
    state.hub.send_many(&wiped.friends, &Event::FriendsChanged);
    // Their chats and messages no longer count on anyone's icon.
    for friend in &wiped.friends {
        crate::apns::badge_changed(state, *friend);
    }
    for group in &wiped.groups {
        if let Ok(members) = crate::groups::member_ids(&state.db, *group).await {
            for member in &members {
                crate::apns::badge_changed(state, *member);
            }
            state
                .hub
                .send_many(&members, &Event::GroupsChanged { group_id: *group });
        }
    }
    for id in &wiped.events {
        if let Ok(message) = crate::groups::get_message(&state.db, *id).await {
            let _ = crate::groups::broadcast(state, message).await;
        }
    }
}

/// A marker in the backups bucket (the id only), so a restored backup is
/// wiped again at start (`reapply`).
async fn mark(state: &SharedState, user: i64) {
    let Some(aws) = state.metrics.aws() else {
        return;
    };
    let Some(bucket) = aws
        .instance
        .s3_buckets()
        .into_iter()
        .find(|b| b.contains("-backups-"))
    else {
        return;
    };
    if let Err(e) = aws
        .s3_put_json(
            &bucket,
            &format!("{MARKERS}{user}"),
            &json!({ "user_id": user }),
        )
        .await
    {
        tracing::error!(user_id = user, error = %e, "deletion marker not written");
    }
}

/// At start (production): any account the markers say was deleted, but which
/// this database still has (it came from a backup), is wiped again.
pub async fn reapply(state: &SharedState) {
    if !state.config.deletion_markers {
        return;
    }
    let Some(aws) = state.metrics.aws() else {
        return;
    };
    let Some(bucket) = aws
        .instance
        .s3_buckets()
        .into_iter()
        .find(|b| b.contains("-backups-"))
    else {
        return;
    };
    let markers = match aws.s3_list(&bucket, MARKERS).await {
        Ok(m) => m,
        Err(e) => {
            tracing::error!(error = %e, "deletion markers not read");
            return;
        }
    };
    for (key, at) in markers {
        let Some(user) = key
            .strip_prefix(MARKERS)
            .and_then(|s| s.parse::<i64>().ok())
        else {
            continue;
        };
        let row: Option<(String, bool)> = sqlx::query_as(
            "SELECT username, EXISTS(SELECT 1 FROM deleted_accounts d WHERE d.user_id = u.id) FROM users u WHERE id = ?",
        )
        .bind(user)
        .fetch_optional(&state.db)
        .await
        .ok()
        .flatten();
        if let Some((username, false)) = row {
            match wipe(&state.db, &state.config.pic_dir, user, &username, at).await {
                Ok(_) => tracing::warn!(
                    user_id = user,
                    "deleted account wiped again (restored from a backup)"
                ),
                Err(e) => {
                    tracing::error!(user_id = user, error = ?e, "deleted account not wiped again")
                }
            }
        }
    }
}

/// Hourly: holds past their 30 days let the username go.
pub fn spawn_sweeper(state: SharedState) {
    tokio::spawn(async move {
        loop {
            if let Err(e) = sqlx::query(
                "UPDATE deleted_accounts SET username_hmac = NULL, held_until = NULL WHERE held_until <= ?",
            )
            .bind(now())
            .execute(&state.db)
            .await
            {
                tracing::warn!(error = %e, "username holds not cleared");
            }
            tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    /// Columns where other people's records may still point at the hollow row
    /// (account-deletion.md, What stays). Every other column that refers to
    /// users must be seeded below and hold nothing of theirs afterwards.
    const MAY_POINT_AT_THEM: &[(&str, &str)] = &[
        ("groups", "created_by"),
        ("group_avatars", "set_by"),
        ("announcements", "created_by"),
        ("announcements", "withdrawn_by"),
        ("admin_actions", "admin_id"),
        ("reset_codes", "created_by"),
        ("user_roles", "granted_by"),
        ("user_roles", "revoked_by"),
        ("user_role_upgrades", "granted_by"),
        ("user_role_upgrades", "revoked_by"),
        ("deactivations", "user_id"),
        ("deactivations", "deactivated_by"),
        ("deactivations", "reactivated_by"),
        ("deleted_accounts", "user_id"),
        // Only the events the deletion posts ("left", a new owner); checked below.
        ("group_messages", "sender_id"),
        // Napsack's own account can't be deleted, so it can't be seeded as one.
        ("system_accounts", "user_id"),
    ];

    /// Ana (1) is deleted; Ben (2) and Cat (3) are friends and group members;
    /// Root (4) is an Admin; Zed (0) is a friend with the lower id (friendships
    /// keep the lower id first, so Ana is on both sides). A row in every table that refers to users.
    const SEED: &str = "
        INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES
            (0, 'zed', 'h', 'k', 'w', 5), (1, 'ana', 'h', 'k', 'w', 5), (2, 'ben', 'h', 'k', 'w', 5), (3, 'cat', 'h', 'k', 'w', 5), (4, 'root', 'h', 'k', 'w', 5);
        INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES ('s1', 1, 0, 9999999999), ('s2', 2, 0, 9999999999);
        INSERT INTO friend_requests (from_id, to_id, created_at, resolved_at, resolution) VALUES (1, 4, 0, NULL, NULL), (4, 1, 0, 1, 'declined'), (4, 2, 0, NULL, NULL);
        INSERT INTO friendships (user_lo, user_hi, created_at, ended_at, ended_by) VALUES (0, 1, 0, NULL, NULL), (1, 2, 0, NULL, NULL), (1, 3, 0, 5, 1), (2, 3, 0, NULL, NULL);
        INSERT INTO messages (id, sender_id, recipient_id, kind, ciphertext, snap_state, created_at, format) VALUES
            (1, 1, 2, 'text', 'c', NULL, 0, 2), (2, 2, 1, 'snap', NULL, 'pending', 0, 2), (3, 2, 3, 'text', 'c', NULL, 0, 2);
        INSERT INTO reactions (id, message_id, sender_id, ciphertext, format, created_at) VALUES (1, 1, 2, 'c', 2, 0), (2, 2, 1, 'c', 2, 0), (3, 3, 3, 'c', 2, 0);
        INSERT INTO message_edits (id, message_id, ciphertext, format, created_at) VALUES (1, 1, 'c', 2, 0), (2, 3, 'c', 2, 0);
        INSERT INTO occasion_sends (id, occasion, occurrence, user_id, message_id, sent_at) VALUES (1, 'birthday', '2026', 1, NULL, 0), (2, 'birthday', '2026', 2, NULL, 0);
        INSERT INTO friend_events (id, actor_id, other_id, kind, created_at) VALUES (1, 1, 2, 'requested', 0), (2, 2, 1, 'accepted', 0), (3, 2, 3, 'requested', 0);
        INSERT INTO groups (id, name, created_by, created_at) VALUES (1, 'trip', 1, 0), (2, 'old', 2, 0);
        INSERT INTO group_members (group_id, user_id, role, added_by, joined_at, left_at, removed_by) VALUES
            (1, 1, 'owner', NULL, 0, NULL, NULL), (1, 2, 'member', 1, 1, NULL, NULL), (1, 3, 'member', 2, 2, NULL, NULL),
            (2, 2, 'owner', NULL, 0, NULL, NULL), (2, 3, 'member', 1, 0, 5, 1);
        INSERT INTO group_pics (id, group_id, sender_id, bytes, mime, created_at, expires_at) VALUES (1, 1, 1, 10, 'image/jpeg', 0, 99), (2, 1, 3, 10, 'image/jpeg', 0, 99);
        INSERT INTO group_messages (id, group_id, sender_id, kind, body, format, created_at, pic_id, reply_to) VALUES
            (1, 1, 1, 'text', 'hi', 0, 0, NULL, NULL),
            (2, 1, 3, 'text', 'not json {', 0, 1, NULL, 1),
            (3, 1, 2, 'event', '{\"type\":\"added\",\"target\":1,\"target_name\":\"ana\"}', 0, 0, NULL, NULL),
            (4, 1, 1, 'text', 'a pic', 0, 3, 1, NULL),
            (5, 1, 2, 'event', '{\"type\":\"added\",\"target\":3,\"target_name\":\"cat\"}', 0, 0, NULL, NULL);
        INSERT INTO group_pic_views (pic_id, user_id, viewed_at) VALUES (1, 2, 0), (2, 1, 0), (2, 2, 0);
        INSERT INTO group_pic_fetches (pic_id, user_id, fetched_at) VALUES (1, 3, 0), (2, 1, 0), (2, 2, 0);
        INSERT INTO group_avatars (id, group_id, set_by, image, mime, created_at) VALUES (1, 1, 1, x'00', 'image/jpeg', 0);
        INSERT INTO group_reactions (id, message_id, user_id, emoji, created_at) VALUES (1, 2, 1, 'x', 0), (2, 1, 2, 'x', 0), (3, 2, 2, 'x', 0);
        INSERT INTO group_message_keys (message_id, user_id, wrapped) VALUES (1, 2, 'w'), (2, 1, 'w'), (2, 2, 'w');
        INSERT INTO group_message_edits (id, message_id, content, client_id, created_at) VALUES (1, 1, 'c', 'e1', 0), (2, 2, 'c', 'e2', 0);
        INSERT INTO group_edit_keys (edit_id, user_id, wrapped) VALUES (1, 2, 'w'), (2, 1, 'w'), (2, 2, 'w');
        INSERT INTO user_avatars (id, user_id, image, mime, created_at) VALUES (1, 1, x'00', 'image/jpeg', 0), (2, 2, x'00', 'image/jpeg', 0);
        INSERT INTO user_names (id, user_id, set_by, name, created_at) VALUES (1, 1, 1, 'Ana', 0), (2, 2, 1, 'Benny', 0), (3, 1, 2, 'A', 0), (4, 2, 2, 'Ben', 0);
        INSERT INTO credential_history (id, user_id, auth_hash, public_key, wrapped_private_key, replaced_at, reason) VALUES (1, 1, 'h', 'k', 'w', 0, 'password_changed');
        INSERT INTO reset_codes (id, user_id, code_hash, created_by, created_at, expires_at) VALUES (1, 1, 'c', 4, 0, 9), (2, 2, 'c', 1, 0, 9);
        INSERT INTO push_subscriptions (id, user_id, session_hash, endpoint, p256dh, auth, created_at) VALUES (1, 1, 's1', 'e', 'p', 'a', 0);
        INSERT INTO invites (id, created_by, token_hash, created_at, expires_at, max_uses, personal) VALUES (1, 1, 't1', 0, 9, 0, 1), (2, 2, 't2', 0, 9, 0, 1);
        INSERT INTO invite_uses (id, invite_id, user_id, kind, created_at) VALUES (1, 1, 3, 'added', 0), (2, 2, 1, 'added', 0), (3, 2, 3, 'added', 0);
        INSERT INTO chat_marks (id, user_id, friend_id, group_id, kind, value, created_at) VALUES (1, 1, 2, NULL, 'favorite', 1, 0), (2, 2, 1, NULL, 'favorite', 1, 0), (3, 2, NULL, 1, 'favorite', 1, 0);
        INSERT INTO user_birthdays (id, user_id, month, day, year, created_at) VALUES (1, 1, 1, 2, NULL, 0);
        INSERT INTO chat_mutes (id, user_id, friend_id, group_id, value, until_at, created_at) VALUES (1, 1, 2, NULL, 1, NULL, 0), (2, 2, 1, NULL, 1, NULL, 0), (3, 2, NULL, 1, 1, NULL, 0);
        INSERT INTO user_roles (id, user_id, role, granted_by, granted_at, revoked_by, revoked_at) VALUES (1, 1, 'power', 4, 0, NULL, NULL), (2, 2, 'power', 1, 0, 1, 5);
        INSERT INTO user_role_upgrades (id, user_id, role, granted_by, granted_at, revoked_by, revoked_at) VALUES (1, 1, 'x', 4, 0, NULL, NULL), (2, 2, 'x', 1, 0, 1, 5);
        INSERT INTO deactivations (id, user_id, reason, deactivated_by, deactivated_at, reactivated_by, reactivated_at) VALUES (1, 1, NULL, 4, 0, 4, 1), (2, 2, NULL, 1, 0, 1, 1);
        INSERT INTO admin_actions (id, admin_id, action, target_user_id, detail, created_at) VALUES (1, 4, 'x', 1, NULL, 0), (2, 1, 'x', 2, NULL, 0);
        INSERT INTO announcements (id, body, created_by, created_at, ends_at, withdrawn_by, withdrawn_at) VALUES (1, 'hi', 1, 0, 9, 1, 5);
        INSERT INTO past_usernames (id, user_id, username, until) VALUES (1, 1, 'anna', 0);
        INSERT INTO apns_devices (id, user_id, session_hash, token, environment, created_at) VALUES (1, 1, 's1', 'ab', 'sandbox', 0);
        INSERT INTO passkeys (id, user_id, credential_id, public_key, wrapped_key, created_at) VALUES (1, 1, 'c1', x'04', 'w', 0), (2, 2, 'c2', x'04', 'w', 0);
    ";

    /// Every (table, column) that refers to users.
    async fn user_columns(db: &SqlitePool) -> Vec<(String, String)> {
        let tables: Vec<String> = sqlx::query_scalar(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_sqlx%'",
        )
        .fetch_all(db)
        .await
        .unwrap();
        let mut out = vec![];
        for t in tables {
            let fks: Vec<(String, String)> =
                sqlx::query_as("SELECT \"table\", \"from\" FROM pragma_foreign_key_list(?)")
                    .bind(&t)
                    .fetch_all(db)
                    .await
                    .unwrap();
            out.extend(
                fks.into_iter()
                    .filter(|(to, _)| to == "users")
                    .map(|(_, col)| (t.clone(), col)),
            );
        }
        out
    }

    // Table and column names from the schema itself (user_columns), never
    // from input, so they're spliced; the value is bound.
    async fn count(db: &SqlitePool, table: &str, col: &str, user: i64) -> i64 {
        let sql = format!("SELECT COUNT(*) FROM \"{table}\" WHERE \"{col}\" = ?");
        sqlx::query_scalar(&sql)
            .bind(user)
            .fetch_one(db)
            .await
            .unwrap()
    }

    async fn rows(db: &SqlitePool, table: &str) -> i64 {
        let sql = format!("SELECT COUNT(*) FROM \"{table}\"");
        sqlx::query_scalar(&sql).fetch_one(db).await.unwrap()
    }

    #[tokio::test]
    async fn everything_of_theirs_goes_and_nothing_of_anyone_elses() {
        let db = temp_db().await;
        sqlx::raw_sql(SEED).execute(&db).await.unwrap();
        let columns = user_columns(&db).await;
        // A table added later that refers to users is seeded here, and handled.
        for (t, c) in &columns {
            if !MAY_POINT_AT_THEM.contains(&(t.as_str(), c.as_str())) {
                assert!(
                    count(&db, t, c, 1).await > 0,
                    "seed {t}.{c} with Ana, and delete it in deletion.rs"
                );
            }
        }
        let pics = tempdir();
        std::fs::create_dir_all(crate::snaps::dir(&pics)).unwrap();
        for f in [
            crate::snaps::dir(&pics).join("2.bin"),
            pics.join("1.bin"),
            pics.join("2.bin"),
        ] {
            std::fs::write(f, b"x").unwrap();
        }

        let wiped = wipe(&db, &pics, 1, "ana", now()).await.unwrap();

        for (t, c) in &columns {
            if !MAY_POINT_AT_THEM.contains(&(t.as_str(), c.as_str())) {
                assert_eq!(count(&db, t, c, 1).await, 0, "{t}.{c} still refers to Ana");
            }
        }
        // The hollow row: nothing of hers.
        let (name, hash, key, created): (String, String, String, i64) = sqlx::query_as(
            "SELECT username, auth_hash, public_key, created_at FROM users WHERE id = 1",
        )
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(
            (name.as_str(), hash.as_str(), key.as_str(), created),
            ("deleted:1", "", "", 0)
        );
        // Only the events the deletion posted: Ben owns her group now, and she "left".
        let events: Vec<String> =
            sqlx::query_scalar("SELECT body FROM group_messages WHERE sender_id = 1 ORDER BY id")
                .fetch_all(&db)
                .await
                .unwrap();
        assert_eq!(events.len(), 2, "{events:?}");
        assert!(
            events[0].contains("\"owner\"") && events[0].contains("\"target\":2"),
            "{events:?}"
        );
        assert!(events[1].contains("\"left\""));
        let owner: String =
            sqlx::query_scalar("SELECT role FROM group_members WHERE group_id = 1 AND user_id = 2")
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!(owner, "owner");
        let mut friends = wiped.friends.clone();
        friends.sort();
        assert_eq!(friends, vec![0, 2]);
        assert_eq!(wiped.groups, vec![1]);

        // Everyone else's: Ben and Cat's chat, Cat's group text (no longer a
        // reply to hers), the event about Cat, Cat's pic, Ben's profile.
        for (table, left) in [
            ("messages", 1),
            ("reactions", 1),
            ("message_edits", 1),
            ("occasion_sends", 1),
            ("friendships", 1),
            ("friend_requests", 1),
            ("friend_events", 1),
            ("group_pics", 1),
            ("group_pic_views", 1),
            ("group_pic_fetches", 1),
            ("group_reactions", 1),
            ("group_message_keys", 1),
            ("group_message_edits", 1),
            ("group_edit_keys", 1),
            ("user_avatars", 1),
            ("user_names", 1),
            ("invites", 1),
            ("invite_uses", 1),
            ("chat_marks", 1),
            ("chat_mutes", 1),
            ("sessions", 1),
            ("group_avatars", 1),
            ("groups", 2),
        ] {
            assert_eq!(rows(&db, table).await, left, "{table}");
        }
        let (reply_to, body): (Option<i64>, String) =
            sqlx::query_as("SELECT reply_to, body FROM group_messages WHERE id = 2")
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!((reply_to, body.as_str()), (None, "not json {"));
        assert!(sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM group_messages WHERE id = 5)"
        )
        .fetch_one(&db)
        .await
        .unwrap());
        let (added_by, removed_by): (Option<i64>, Option<i64>) = sqlx::query_as(
            "SELECT added_by, removed_by FROM group_members WHERE group_id = 2 AND user_id = 3",
        )
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!((added_by, removed_by), (None, None));
        // Her files, not Cat's.
        assert!(!crate::snaps::dir(&pics).join("2.bin").exists());
        assert!(!pics.join("1.bin").exists());
        assert!(pics.join("2.bin").exists());
    }

    #[tokio::test]
    async fn the_username_is_held_for_30_days_then_free() {
        let db = temp_db().await;
        sqlx::raw_sql(SEED).execute(&db).await.unwrap();
        wipe(&db, &tempdir(), 1, "ana", now()).await.unwrap();
        assert!(held(&db, "ana").await.unwrap());
        assert!(held(&db, " ANA ").await.unwrap(), "any case");
        assert!(!held(&db, "ben").await.unwrap());
        assert!(!crate::usernames::available_to(&db, 2, "ana").await.unwrap());
        let stored: String =
            sqlx::query_scalar("SELECT username_hmac FROM deleted_accounts WHERE user_id = 1")
                .fetch_one(&db)
                .await
                .unwrap();
        assert!(!stored.contains("ana"), "a keyed hash, not the name");

        // 30 days on.
        sqlx::query("UPDATE deleted_accounts SET held_until = ?")
            .bind(now() - 1)
            .execute(&db)
            .await
            .unwrap();
        assert!(!held(&db, "ana").await.unwrap());
        assert!(crate::usernames::available_to(&db, 2, "ana").await.unwrap());

        // A backup restored long after: wiped again, nothing held.
        let db2 = temp_db().await;
        sqlx::raw_sql(SEED).execute(&db2).await.unwrap();
        wipe(&db2, &tempdir(), 1, "ana", now() - HOLD_SECS - 10)
            .await
            .unwrap();
        assert!(!held(&db2, "ana").await.unwrap());
    }

    #[tokio::test]
    async fn a_deleted_account_cant_sign_in_or_be_found() {
        let db = temp_db().await;
        sqlx::raw_sql(SEED).execute(&db).await.unwrap();
        wipe(&db, &tempdir(), 1, "ana", now()).await.unwrap();
        assert!(
            crate::admin_users::is_deactivated(&db, 1).await.unwrap(),
            "turned off: every current-user filter leaves it out"
        );
    }

    fn tempdir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("fade-deletion-{}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
