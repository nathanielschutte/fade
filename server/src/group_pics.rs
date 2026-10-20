//! Pics in group chats, and group pictures. Like group texts, NOT end-to-end
//! encrypted yet (migration 0007): the server can see these images.
//!
//! A group pic is view-once per member. Its bytes live in a file under
//! `Config::pic_dir` until everyone who was in the group when it was sent has
//! opened it, or it expires; then the file is discarded (that's the feature,
//! not data loss) and the database rows stay. Group pictures are small and
//! kept in the database, every one ever set, so backups include them.

use std::path::PathBuf;

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde::Serialize;
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    db::now,
    error::{AppError, AppResult},
    groups::{self, GroupMessage},
    ws::Event,
    SharedState,
};

/// Group pictures are downscaled by the client to about 256px; this is the cap.
pub const AVATAR_MAX_BYTES: usize = 128 * 1024;
const MIN_IMAGE_BYTES: usize = 64;

/// What clients need to show a group pic's state. The same for everyone;
/// each client works out "did I open it" from `viewers`.
#[derive(Debug, Clone, Serialize, FromRow)]
pub struct PicInfo {
    pub id: i64,
    pub bytes: i64,
    pub expires_at: i64,
    /// "opened" (everyone has seen it) or "expired", once the file is gone.
    pub discard_reason: Option<String>,
    #[sqlx(skip)]
    pub viewers: Vec<i64>,
}

/// Identify an image by its magic bytes rather than trusting the client.
pub fn sniff_image(data: &[u8]) -> Option<&'static str> {
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if data.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        Some("image/png")
    } else if data.len() > 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

pub fn image_response(mime: &str, data: Vec<u8>) -> Response {
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime).unwrap_or(HeaderValue::from_static("application/octet-stream")),
    );
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, private, max-age=0"),
    );
    // Even opened directly, an image response can't run anything or load anything.
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static("default-src 'none'; img-src 'self'; sandbox"),
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_static("inline; filename=\"pic.jpg\""),
    );
    (headers, data).into_response()
}

fn pic_path(state: &SharedState, id: i64) -> PathBuf {
    state.config.pic_dir.join(format!("{id}.bin"))
}

async fn pic_info(db: &SqlitePool, id: i64) -> sqlx::Result<PicInfo> {
    let mut info: PicInfo =
        sqlx::query_as("SELECT id, bytes, expires_at, discard_reason FROM group_pics WHERE id = ?")
            .bind(id)
            .fetch_one(db)
            .await?;
    info.viewers = sqlx::query_scalar(
        "SELECT user_id FROM group_pic_views WHERE pic_id = ? ORDER BY viewed_at",
    )
    .bind(id)
    .fetch_all(db)
    .await?;
    Ok(info)
}

/// Fills in `pic` on messages that carry one.
pub async fn attach(db: &SqlitePool, messages: &mut [GroupMessage]) -> sqlx::Result<()> {
    for m in messages.iter_mut() {
        if let Some(id) = m.pic_id {
            m.pic = Some(pic_info(db, id).await?);
        }
    }
    Ok(())
}

/// (count, bytes) of group pics whose files are still on disk.
pub async fn pending(db: &SqlitePool) -> sqlx::Result<(i64, i64)> {
    sqlx::query_as(
        "SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM group_pics WHERE discarded_at IS NULL",
    )
    .fetch_one(db)
    .await
}

/// Marks the pic discarded and removes its file. The rows stay.
async fn discard(state: &SharedState, id: i64, reason: &str) -> sqlx::Result<bool> {
    let changed = sqlx::query(
        "UPDATE group_pics SET discarded_at = ?, discard_reason = ? WHERE id = ? AND discarded_at IS NULL",
    )
    .bind(now())
    .bind(reason)
    .bind(id)
    .execute(&state.db)
    .await?
    .rows_affected();
    if changed > 0 {
        if let Err(e) = tokio::fs::remove_file(pic_path(state, id)).await {
            if e.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(pic_id = id, error = %e, "couldn't remove discarded pic file");
            }
        }
        tracing::info!(pic_id = id, reason, "group pic discarded");
    }
    Ok(changed > 0)
}

/// Discards the pic once everyone who can open it has. Returns true if it did.
async fn discard_if_everyone_opened(state: &SharedState, pic: i64) -> sqlx::Result<bool> {
    let (waiting,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM group_pics p
         JOIN group_messages gm ON gm.pic_id = p.id
         JOIN group_members m ON m.group_id = p.group_id
         WHERE p.id = ?1 AND m.left_at IS NULL AND m.user_id != p.sender_id
           AND m.visible_after_id < gm.id
           AND NOT EXISTS (SELECT 1 FROM group_pic_views v WHERE v.pic_id = p.id AND v.user_id = m.user_id)",
    )
    .bind(pic)
    .fetch_one(&state.db)
    .await?;
    let (viewed,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM group_pic_views WHERE pic_id = ?")
        .bind(pic)
        .fetch_one(&state.db)
        .await?;
    if waiting == 0 && viewed > 0 {
        return discard(state, pic, "opened").await;
    }
    Ok(false)
}

async fn message_for_pic(db: &SqlitePool, pic: i64) -> sqlx::Result<i64> {
    sqlx::query_scalar("SELECT id FROM group_messages WHERE pic_id = ?")
        .bind(pic)
        .fetch_one(db)
        .await
}

/// Sends the pic's message again so every client updates its state.
async fn rebroadcast(state: &SharedState, pic: i64) -> AppResult<()> {
    let id = message_for_pic(&state.db, pic).await?;
    groups::broadcast(state, groups::get_message(&state.db, id).await?).await?;
    Ok(())
}

pub const MAX_CAPTION_CHARS: usize = 200;

#[derive(serde::Deserialize)]
pub struct UploadParams {
    /// `?caption=...`: shown with the pic when it's opened. Query strings are never logged.
    #[serde(default)]
    caption: String,
}

/// One line, checked like any other text people see (text.rs). Blank is none.
fn clean_caption(raw: &str) -> AppResult<Option<String>> {
    crate::text::check_name(raw).map_err(|_| {
        AppError::bad("Captions can't contain line breaks or invisible characters.")
    })?;
    let caption = raw.trim();
    if caption.chars().count() > MAX_CAPTION_CHARS {
        return Err(AppError::bad(format!(
            "Captions can be at most {MAX_CAPTION_CHARS} characters."
        )));
    }
    Ok((!caption.is_empty()).then(|| caption.to_owned()))
}

/// `POST /api/groups/{id}/pics`: raw image body (the client compresses it).
pub async fn upload(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    Query(params): Query<UploadParams>,
    body: Bytes,
) -> AppResult<Json<GroupMessage>> {
    groups::require_member(&state.db, group, me.id).await?;
    let caption = clean_caption(&params.caption)?;
    if body.len() < MIN_IMAGE_BYTES {
        return Err(AppError::bad("That pic was empty."));
    }
    if body.len() > state.config.snap_max_bytes {
        return Err(AppError::PayloadTooLarge("That photo is too large.".into()));
    }
    sniff_image(&body).ok_or_else(|| AppError::bad("Pics must be JPEG, PNG, or WebP images."))?;
    if !state.image_upload_limit.allow(&me.id.to_string()) {
        return Err(AppError::TooManyRequests(
            "You're sending pics too fast. Wait a minute.".into(),
        ));
    }
    // Only the re-encoded image is ever stored or served (images.rs).
    let body = crate::images::clean(body, 1600).await?;
    let mime = "image/jpeg";
    let (_, held) = pending(&state.db).await?;
    if held as usize + body.len() > state.config.group_pic_disk_bytes {
        tracing::warn!(
            group_id = group,
            held,
            "group pic rejected: disk cap reached"
        );
        return Err(AppError::Unavailable(
            "The server is holding too many unopened pics. Try again later.".into(),
        ));
    }

    let at = now();
    let mut tx = state.db.begin().await?;
    let pic: i64 = sqlx::query_scalar(
        "INSERT INTO group_pics (group_id, sender_id, bytes, mime, caption, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(group)
    .bind(me.id)
    .bind(body.len() as i64)
    .bind(mime)
    .bind(caption.as_deref())
    .bind(at)
    .bind(at + state.config.group_pic_ttl.as_secs() as i64)
    .fetch_one(&mut *tx)
    .await?;
    // Write the file before committing; write-then-rename so a crash never leaves half a pic.
    let path = pic_path(&state, pic);
    let tmp = path.with_extension("tmp");
    tokio::fs::write(&tmp, &body)
        .await
        .map_err(|e| AppError::Internal(format!("writing pic: {e}")))?;
    tokio::fs::rename(&tmp, &path)
        .await
        .map_err(|e| AppError::Internal(format!("saving pic: {e}")))?;
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO group_messages (group_id, sender_id, kind, body, format, created_at, pic_id)
         VALUES (?, ?, 'text', '', ?, ?, ?) RETURNING id",
    )
    .bind(group)
    .bind(me.id)
    .bind(groups::FORMAT_PLAINTEXT)
    .bind(at)
    .bind(pic)
    .fetch_one(&mut *tx)
    .await?;
    if let Err(e) = tx.commit().await {
        let _ = tokio::fs::remove_file(&path).await;
        return Err(e.into());
    }

    tracing::info!(
        group_id = group,
        pic_id = pic,
        from = me.id,
        bytes = body.len(),
        "group pic sent"
    );
    let message = groups::get_message(&state.db, id).await?;
    groups::broadcast(&state, message.clone()).await?;
    Ok(Json(message))
}

/// sender, mime, discarded_at, expires_at, message id, caption
type PicRow = (i64, String, Option<i64>, i64, i64, Option<String>);

/// `GET /api/groups/{id}/pics/{pic_id}`: view once, for members who were there
/// when it was sent (not the sender).
pub async fn view(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((group, pic)): Path<(i64, i64)>,
) -> AppResult<Response> {
    let (_, visible_after) = groups::require_member(&state.db, group, me.id).await?;
    let row: Option<PicRow> = sqlx::query_as(
        "SELECT p.sender_id, p.mime, p.discarded_at, p.expires_at, gm.id, p.caption
         FROM group_pics p JOIN group_messages gm ON gm.pic_id = p.id
         WHERE p.id = ? AND p.group_id = ?",
    )
    .bind(pic)
    .bind(group)
    .fetch_optional(&state.db)
    .await?;
    let not_found = || AppError::not_found("Pic not found.");
    let (sender, mime, discarded, expires_at, message_id, caption) = row.ok_or_else(not_found)?;
    if message_id <= visible_after {
        return Err(not_found()); // sent before they joined
    }
    if sender == me.id {
        return Err(AppError::bad("You sent this pic."));
    }
    let seen: Option<(i64,)> =
        sqlx::query_as("SELECT 1 FROM group_pic_views WHERE pic_id = ? AND user_id = ?")
            .bind(pic)
            .bind(me.id)
            .fetch_optional(&state.db)
            .await?;
    if seen.is_some() {
        return Err(AppError::Gone("You've already opened this pic.".into()));
    }
    if discarded.is_some() || expires_at <= now() {
        return Err(AppError::Gone("This pic has expired.".into()));
    }
    let data = match tokio::fs::read(pic_path(&state, pic)).await {
        Ok(d) => d,
        Err(e) => {
            tracing::warn!(pic_id = pic, error = %e, "group pic file missing");
            discard(&state, pic, "expired").await?;
            rebroadcast(&state, pic).await?;
            return Err(AppError::Gone("This pic has expired.".into()));
        }
    };
    sqlx::query(
        "INSERT OR IGNORE INTO group_pic_views (pic_id, user_id, viewed_at) VALUES (?, ?, ?)",
    )
    .bind(pic)
    .bind(me.id)
    .bind(now())
    .execute(&state.db)
    .await?;
    tracing::info!(
        group_id = group,
        pic_id = pic,
        user_id = me.id,
        "group pic opened"
    );
    discard_if_everyone_opened(&state, pic).await?;
    rebroadcast(&state, pic).await?;
    let mut response = image_response(&mime, data);
    if let Some(caption) = caption {
        // Headers are ASCII; the client decodes this with decodeURIComponent.
        if let Ok(value) = HeaderValue::from_str(&percent_encode(&caption)) {
            response
                .headers_mut()
                .insert(header::HeaderName::from_static("x-napsack-caption"), value);
        }
    }
    Ok(response)
}

/// Percent-encodes everything but unreserved characters (RFC 3986).
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Every minute: discard expired group pics, and any that everyone left in
/// the group has now opened (someone may have left since).
pub fn spawn_sweeper(state: SharedState) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            tick.tick().await;
            if let Err(e) = sweep(&state).await {
                tracing::warn!(error = ?e, "group pic sweep failed");
            }
        }
    });
}

async fn sweep(state: &SharedState) -> AppResult<()> {
    let open: Vec<(i64, i64)> =
        sqlx::query_as("SELECT id, expires_at FROM group_pics WHERE discarded_at IS NULL")
            .fetch_all(&state.db)
            .await?;
    let at = now();
    for (pic, expires_at) in open {
        let changed = if expires_at <= at {
            discard(state, pic, "expired").await?
        } else {
            discard_if_everyone_opened(state, pic).await?
        };
        if changed {
            rebroadcast(state, pic).await?;
        }
    }
    Ok(())
}

// ---------- group pictures ----------

pub async fn current_avatar(db: &SqlitePool, group: i64) -> sqlx::Result<Option<i64>> {
    sqlx::query_scalar("SELECT MAX(id) FROM group_avatars WHERE group_id = ?")
        .bind(group)
        .fetch_one(db)
        .await
}

/// `POST /api/groups/{id}/avatar`: any member; raw small image body.
pub async fn set_avatar(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(group): Path<i64>,
    body: Bytes,
) -> AppResult<Json<Value>> {
    groups::require_member(&state.db, group, me.id).await?;
    if body.len() < MIN_IMAGE_BYTES || body.len() > AVATAR_MAX_BYTES {
        return Err(AppError::bad("Group pictures must be under 128 KB."));
    }
    sniff_image(&body)
        .ok_or_else(|| AppError::bad("Group pictures must be JPEG, PNG, or WebP images."))?;
    if !state.image_upload_limit.allow(&me.id.to_string()) {
        return Err(AppError::TooManyRequests(
            "You're changing pictures too fast. Wait a minute.".into(),
        ));
    }
    // Only the re-encoded image is ever stored or served (images.rs).
    let body = crate::images::clean(body, 512).await?;
    let mime = "image/jpeg";
    let mut tx = state.db.begin().await?;
    let avatar: i64 = sqlx::query_scalar(
        "INSERT INTO group_avatars (group_id, set_by, image, mime, created_at) VALUES (?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(group)
    .bind(me.id)
    .bind(body.as_slice())
    .bind(mime)
    .bind(now())
    .fetch_one(&mut *tx)
    .await?;
    let event = groups::post(
        &mut *tx,
        group,
        me.id,
        "event",
        &json!({ "type": "picture" }).to_string(),
    )
    .await?;
    tx.commit().await?;
    tracing::info!(
        group_id = group,
        user_id = me.id,
        avatar_id = avatar,
        bytes = body.len(),
        "group picture set"
    );
    let all = groups::member_ids(&state.db, group).await?;
    state
        .hub
        .send_many(&all, &Event::GroupsChanged { group_id: group });
    groups::broadcast(&state, groups::get_message(&state.db, event).await?).await?;
    Ok(Json(json!({ "avatar_id": avatar })))
}

/// `GET /api/groups/{id}/avatar/{avatar_id}`: members only.
pub async fn get_avatar(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((group, avatar)): Path<(i64, i64)>,
) -> AppResult<Response> {
    groups::require_member(&state.db, group, me.id).await?;
    let row: Option<(Vec<u8>, String)> =
        sqlx::query_as("SELECT image, mime FROM group_avatars WHERE id = ? AND group_id = ?")
            .bind(avatar)
            .bind(group)
            .fetch_optional(&state.db)
            .await?;
    let (image, mime) = row.ok_or_else(|| AppError::not_found("No such picture."))?;
    Ok(image_response(&mime, image))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_image_types() {
        assert_eq!(sniff_image(&[0xFF, 0xD8, 0xFF, 0xE0]), Some("image/jpeg"));
        assert_eq!(sniff_image(b"\x89PNG\r\n\x1a\nxxxx"), Some("image/png"));
        assert_eq!(sniff_image(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff_image(b"<svg onload=alert(1)>"), None);
        assert_eq!(sniff_image(b"GIF89a"), None);
    }

    #[test]
    fn captions_are_one_clean_line_and_encode_safely() {
        assert_eq!(
            clean_caption("  sunset 🌅 ").unwrap().as_deref(),
            Some("sunset 🌅")
        );
        assert_eq!(clean_caption("   ").unwrap(), None);
        assert!(clean_caption("two\nlines").is_err());
        assert!(clean_caption("a\u{202E}b").is_err());
        assert!(clean_caption(&"x".repeat(201)).is_err());
        assert_eq!(percent_encode("a b/é<"), "a%20b%2F%C3%A9%3C");
    }
}
