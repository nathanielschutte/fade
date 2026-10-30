//! Pics in direct chats ("snaps" internally) are view-once photos, encrypted
//! in the sender's browser. The server only ever holds ciphertext.
//!
//! An unopened pic waits in a file on the data volume (`<pic_dir>/direct/`)
//! until its recipient opens it or it expires (30 days by default), so
//! restarts and deploys don't lose it. Opening or expiring it discards the
//! file: that's the feature, not data loss. The database row stays, so the
//! chat can show "Opened" or "Expired".

use std::{path::PathBuf, time::Duration};

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    db::{self, now, Message, MESSAGE_COLS},
    error::{AppError, AppResult},
    friends::require_reachable,
    version,
    ws::Event,
    SharedState,
};

/// 12-byte IV + 16-byte AES-GCM tag. Anything shorter can't be a real snap.
const MIN_SNAP_BYTES: usize = 29;

pub fn dir(pic_dir: &std::path::Path) -> PathBuf {
    pic_dir.join("direct")
}

fn snap_path(state: &SharedState, id: i64) -> PathBuf {
    dir(&state.config.pic_dir).join(format!("{id}.bin"))
}

/// (count, bytes) of unopened pics waiting on disk.
pub async fn usage(db: &SqlitePool) -> sqlx::Result<(i64, i64)> {
    sqlx::query_as(
        "SELECT COUNT(*), COALESCE(SUM(snap_bytes), 0) FROM messages
         WHERE kind = 'snap' AND snap_state = 'pending'",
    )
    .fetch_one(db)
    .await
}

/// Moves a pending snap to `opened` or `expired` and discards its file.
/// Returns the updated message if this call made the change (so exactly one
/// caller wins when two race).
async fn finish(state: &SharedState, id: i64, to: &str) -> sqlx::Result<Option<Message>> {
    let changed = sqlx::query(
        "UPDATE messages SET snap_state = ?, read_at = COALESCE(read_at, ?)
         WHERE id = ? AND kind = 'snap' AND snap_state = 'pending'",
    )
    .bind(to)
    .bind(now())
    .bind(id)
    .execute(&state.db)
    .await?
    .rows_affected();
    if changed == 0 {
        return Ok(None);
    }
    if let Err(e) = tokio::fs::remove_file(snap_path(state, id)).await {
        if e.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!(message_id = id, error = %e, "couldn't remove pic file");
        }
    }
    db::get_message(&state.db, id).await
}

/// Body is the encrypted image: IV || AES-GCM ciphertext. No multipart needed.
/// The server can't see or check the image, only its size.
#[derive(serde::Deserialize)]
pub struct UploadParams {
    /// `?format=2`. Optional; clients from before formats existed wrote format 1.
    #[serde(default = "version::default_format")]
    format: i64,
    /// `?client_id=...`: picked by the app, so a retried upload isn't stored twice.
    client_id: Option<String>,
}

pub async fn upload(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend_id): Path<i64>,
    Query(params): Query<UploadParams>,
    body: Bytes,
) -> AppResult<Json<Message>> {
    require_reachable(&state, me.id, friend_id).await?;
    version::check_snap_format(params.format)?;
    if params
        .client_id
        .as_deref()
        .is_some_and(|c| !db::valid_client_id(c))
    {
        return Err(AppError::bad("That pic id isn't valid."));
    }
    if let Some(stored) = db::sent_before(&state.db, me.id, params.client_id.as_deref()).await? {
        tracing::debug!(
            message_id = stored.id,
            from = me.id,
            "pic resent; already stored"
        );
        return Ok(Json(stored));
    }

    if body.len() < MIN_SNAP_BYTES {
        return Err(AppError::bad("That pic wasn't encrypted correctly."));
    }
    if params.format == version::VIDEO_FORMAT {
        if body.len() > state.config.video_max_bytes {
            return Err(AppError::PayloadTooLarge("That video is too large.".into()));
        }
    } else if body.len() > state.config.snap_max_bytes {
        return Err(AppError::PayloadTooLarge("That photo is too large.".into()));
    }
    crate::guard::check_upload_room(&state)?;
    let (_, held) = usage(&state.db).await?;
    if held as usize + body.len() > state.config.snap_disk_bytes {
        tracing::warn!(
            from = me.id,
            to = friend_id,
            held,
            "pic rejected: disk cap reached"
        );
        return Err(AppError::Unavailable(
            "The server is holding too many unopened pics. Try again later.".into(),
        ));
    }

    // The row and the file go in together: the file is written (then renamed,
    // so a crash never leaves half a pic) before the row commits.
    let mut tx = crate::db::write_tx(&state.db).await?;
    let message = sqlx::query_as::<_, Message>(&format!(
        "INSERT INTO messages (sender_id, recipient_id, kind, format, snap_state, snap_bytes, created_at, client_id)
         VALUES (?, ?, 'snap', ?, 'pending', ?, ?, ?) RETURNING {MESSAGE_COLS}"
    ))
    .bind(me.id)
    .bind(friend_id)
    .bind(params.format)
    .bind(body.len() as i64)
    .bind(now())
    .bind(params.client_id.as_deref())
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(d) if d.is_unique_violation() => {
            AppError::Conflict("That pic was already sent.".into())
        }
        e => e.into(),
    })?;
    let path = snap_path(&state, message.id);
    let tmp = path.with_extension("tmp");
    tokio::fs::write(&tmp, &body)
        .await
        .map_err(|e| AppError::Internal(format!("writing pic: {e}")))?;
    tokio::fs::rename(&tmp, &path)
        .await
        .map_err(|e| AppError::Internal(format!("saving pic: {e}")))?;
    if let Err(e) = tx.commit().await {
        let _ = tokio::fs::remove_file(&path).await; // no file for a message that doesn't exist
        return Err(e.into());
    }
    tracing::info!(
        message_id = message.id,
        from = me.id,
        to = friend_id,
        bytes = body.len(),
        format = params.format,
        "pic sent"
    );

    state.hub.send_both(
        me.id,
        friend_id,
        &Event::Message {
            message: message.clone(),
        },
    );
    crate::push::notify(
        &state,
        friend_id,
        crate::push::Note {
            title: crate::people::name_for(&state.db, friend_id, me.id).await?,
            body: if params.format == version::VIDEO_FORMAT {
                "Sent you a video"
            } else {
                "Sent you a pic"
            }
            .into(),
            tag: format!("dm-{}", me.id),
            url: format!("/#chat={}", me.id),
        },
    );
    Ok(Json(message))
}

/// After an admin reset code (D14): pics waiting for `user` were sealed to
/// their old key and can never be opened, so they expire now (as they would
/// after 30 days), their files go, and both people hear. Returns how many.
pub async fn expire_waiting_for(state: &SharedState, user: i64) -> sqlx::Result<usize> {
    let waiting: Vec<i64> = sqlx::query_scalar(
        "SELECT id FROM messages WHERE recipient_id = ? AND kind = 'snap' AND snap_state = 'pending'",
    )
    .bind(user)
    .fetch_all(&state.db)
    .await?;
    let mut expired = 0;
    for id in waiting {
        if let Some(message) = finish(state, id, "expired").await? {
            notify(state, message);
            expired += 1;
        }
    }
    Ok(expired)
}

fn notify(state: &SharedState, message: Message) {
    state.hub.send_both(
        message.sender_id,
        message.recipient_id,
        &Event::MessageUpdated { message },
    );
}

/// A pic that was fetched but never confirmed shown counts as opened after this
/// long: long enough to retry a slow or dropped open, short enough that
/// fetching isn't a way around view-once.
pub const OPEN_GRACE_SECS: i64 = 15 * 60;

/// `GET /api/snaps/{id}`: the recipient fetches the sealed pic. Fetching
/// doesn't open it: the app confirms with `POST /snaps/{id}/opened` once the
/// pic is on screen, so a dropped connection or a slow decode doesn't lose
/// it. Until then it can be fetched again (the first fetch is recorded, and
/// after `OPEN_GRACE_SECS` it counts as opened anyway).
pub async fn view(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Response> {
    // Only the recipient learns anything about it.
    let m = match db::get_message(&state.db, id).await? {
        Some(m) if m.recipient_id == me.id && m.kind == "snap" => m,
        _ => {
            tracing::debug!(message_id = id, user_id = me.id, "pic not available");
            return Err(AppError::not_found("Pic not found."));
        }
    };
    let gone = || AppError::Gone("This pic was already opened or has expired.".into());
    if m.snap_state.as_deref() != Some("pending") {
        return Err(gone());
    }
    if m.created_at + state.config.snap_ttl.as_secs() as i64 <= now() {
        if let Some(message) = finish(&state, id, "expired").await? {
            notify(&state, message);
        }
        return Err(gone());
    }
    let data = match tokio::fs::read(snap_path(&state, id)).await {
        Ok(d) => d,
        Err(e) => {
            tracing::warn!(message_id = id, error = %e, "pic file missing");
            if let Some(message) = finish(&state, id, "expired").await? {
                notify(&state, message);
            }
            return Err(gone());
        }
    };
    sqlx::query("UPDATE messages SET snap_fetched_at = COALESCE(snap_fetched_at, ?) WHERE id = ?")
        .bind(now())
        .bind(id)
        .execute(&state.db)
        .await?;
    tracing::debug!(message_id = id, user_id = me.id, "pic fetched");

    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, private, max-age=0"),
    );
    headers.insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    Ok((headers, data).into_response())
}

/// `POST /api/snaps/{id}/opened`: the recipient's app has shown the pic, so
/// now it's opened and discarded. Saying it twice is fine (a retry after a
/// dropped response).
pub async fn opened(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<serde_json::Value>> {
    let m = match db::get_message(&state.db, id).await? {
        Some(m) if m.recipient_id == me.id && m.kind == "snap" => m,
        _ => return Err(AppError::not_found("Pic not found.")),
    };
    match m.snap_state.as_deref() {
        Some("opened") => return Ok(Json(serde_json::json!({ "ok": true }))),
        Some("pending") => {}
        _ => return Err(AppError::Gone("This pic has expired.".into())),
    }
    if let Some(message) = finish(&state, id, "opened").await? {
        tracing::info!(
            message_id = id,
            from = m.sender_id,
            to = me.id,
            "pic opened"
        );
        notify(&state, message);
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}

/// At startup: a pending pic whose file is gone can never be opened (it was
/// held in memory by a release before 0.13.0, or the disk lost it), so mark it
/// expired. Files with no pending pic (a crash mid-upload) are discarded.
pub async fn reconcile(db: &SqlitePool, pic_dir: &std::path::Path) -> anyhow::Result<(u64, u64)> {
    let dir = dir(pic_dir);
    tokio::fs::create_dir_all(&dir).await?;
    let pending: Vec<i64> = sqlx::query_scalar(
        "SELECT id FROM messages WHERE kind = 'snap' AND snap_state = 'pending'",
    )
    .fetch_all(db)
    .await?;
    let mut lost = 0;
    for id in &pending {
        if !tokio::fs::try_exists(dir.join(format!("{id}.bin"))).await? {
            lost += sqlx::query(
                "UPDATE messages SET snap_state = 'expired' WHERE id = ? AND snap_state = 'pending'",
            )
            .bind(id)
            .execute(db)
            .await?
            .rows_affected();
        }
    }
    let mut strays = 0;
    let mut entries = tokio::fs::read_dir(&dir).await?;
    while let Some(entry) = entries.next_entry().await? {
        let name = entry.file_name().to_string_lossy().into_owned();
        let keep = name
            .strip_suffix(".bin")
            .and_then(|id| id.parse::<i64>().ok())
            .is_some_and(|id| pending.contains(&id));
        if !keep {
            tokio::fs::remove_file(entry.path()).await?;
            strays += 1;
        }
    }
    Ok((lost, strays))
}

/// Every minute: expire pics nobody opened in time, and tell both people.
pub fn spawn_sweeper(state: SharedState) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            if let Err(e) = sweep(&state).await {
                tracing::warn!(error = ?e, "pic sweep failed");
            }
        }
    });
}

async fn sweep(state: &SharedState) -> sqlx::Result<()> {
    let cutoff = now() - state.config.snap_ttl.as_secs() as i64;
    let due: Vec<i64> = sqlx::query_scalar(
        "SELECT id FROM messages WHERE kind = 'snap' AND snap_state = 'pending' AND created_at <= ?",
    )
    .bind(cutoff)
    .fetch_all(&state.db)
    .await?;
    if !due.is_empty() {
        tracing::info!(count = due.len(), "pics expired unopened");
    }
    for id in due {
        if let Some(message) = finish(state, id, "expired").await? {
            notify(state, message);
        }
    }
    // Fetched long ago and never confirmed (an older app, an abandoned open):
    // that counts as opened.
    let fetched: Vec<i64> = sqlx::query_scalar(
        "SELECT id FROM messages WHERE kind = 'snap' AND snap_state = 'pending'
           AND snap_fetched_at IS NOT NULL AND snap_fetched_at <= ?",
    )
    .bind(now() - OPEN_GRACE_SECS)
    .fetch_all(&state.db)
    .await?;
    for id in fetched {
        if let Some(message) = finish(state, id, "opened").await? {
            tracing::info!(message_id = id, "pic opened (fetched, not confirmed)");
            notify(state, message);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[tokio::test]
    async fn reconcile_expires_lost_pics_and_removes_strays() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben")] {
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
        for id in [10, 11, 12] {
            let state = if id == 12 { "opened" } else { "pending" };
            sqlx::query(
                "INSERT INTO messages (id, sender_id, recipient_id, kind, snap_state, snap_bytes, created_at)
                 VALUES (?, 1, 2, 'snap', ?, 5, 0)",
            )
            .bind(id)
            .bind(state)
            .execute(&db)
            .await
            .unwrap();
        }
        let root = std::env::temp_dir().join(format!("fade-snaps-{}", std::process::id()));
        let d = dir(&root);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("10.bin"), b"held").unwrap(); // 10 survives
        std::fs::write(d.join("12.bin"), b"stray").unwrap(); // already opened
        std::fs::write(d.join("99.tmp"), b"half").unwrap(); // crashed upload
                                                            // 11 has no file: it was lost.

        assert_eq!(reconcile(&db, &root).await.unwrap(), (1, 2));
        let states: Vec<(i64, String)> =
            sqlx::query_as("SELECT id, snap_state FROM messages ORDER BY id")
                .fetch_all(&db)
                .await
                .unwrap();
        assert_eq!(
            states,
            vec![
                (10, "pending".into()),
                (11, "expired".into()),
                (12, "opened".into())
            ]
        );
        assert!(
            d.join("10.bin").exists() && !d.join("12.bin").exists() && !d.join("99.tmp").exists()
        );
        assert_eq!(usage(&db).await.unwrap(), (1, 5));
        std::fs::remove_dir_all(&root).unwrap();
    }
}
