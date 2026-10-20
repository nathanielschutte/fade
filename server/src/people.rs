//! Display names, private nicknames, and profile pictures (migration 0008).
//!
//! Visible to friends only, enforced here (not end-to-end encrypted). Each
//! person sets their own display name and picture; anyone can also give a
//! friend a nickname that only they see. Clients show, in order: your
//! nickname for them, their display name, their username. Usernames stay the
//! identity (safety codes, sign-in, adding friends), so clients show them
//! alongside names wherever identity matters.
//!
//! Everything is append-only: the newest row wins, and clearing a name or
//! removing a picture adds a row with no value.

use axum::{
    body::Bytes,
    extract::{Path, State},
    response::Response,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    db::{self, now},
    error::{AppError, AppResult},
    group_pics::{image_response, sniff_image},
    ws::Event,
    SharedState,
};

pub const MAX_NAME_CHARS: usize = 30;
/// Clients send about 256px; this is the cap before re-encoding.
pub const AVATAR_MAX_BYTES: usize = 128 * 1024;

/// `u`'s own display name. Needs `users u` in scope.
pub const DISPLAY_NAME: &str = "(SELECT n.name FROM user_names n
     WHERE n.set_by = u.id AND n.user_id = u.id ORDER BY n.id DESC LIMIT 1)";
/// The nickname the viewer, bound as `?1`, gave `u`.
pub const NICKNAME: &str = "(SELECT n.name FROM user_names n
     WHERE n.set_by = ?1 AND n.user_id = u.id ORDER BY n.id DESC LIMIT 1)";
/// `u`'s current profile picture, if they have one.
pub const AVATAR_ID: &str = "(SELECT CASE WHEN a.image IS NULL THEN NULL ELSE a.id END
     FROM user_avatars a WHERE a.user_id = u.id ORDER BY a.id DESC LIMIT 1)";

/// (display name, current picture) for `user`.
pub async fn own_profile(
    db: &SqlitePool,
    user: i64,
) -> sqlx::Result<(Option<String>, Option<i64>)> {
    sqlx::query_as(&format!(
        "SELECT {DISPLAY_NAME}, {AVATAR_ID} FROM users u WHERE u.id = ?"
    ))
    .bind(user)
    .fetch_one(db)
    .await
}

/// What `viewer` calls `user`: their nickname for them, else `user`'s display
/// name, else the username. Used where the server itself names someone
/// (notifications), so it matches what the app shows.
pub async fn name_for(db: &SqlitePool, viewer: i64, user: i64) -> sqlx::Result<String> {
    sqlx::query_scalar(&format!(
        "SELECT COALESCE({NICKNAME}, {DISPLAY_NAME}, u.username) FROM users u WHERE u.id = ?2"
    ))
    .bind(viewer)
    .bind(user)
    .fetch_one(db)
    .await
}

/// The nickname `viewer` gave `user`.
pub async fn nickname(db: &SqlitePool, viewer: i64, user: i64) -> sqlx::Result<Option<String>> {
    sqlx::query_scalar(&format!("SELECT {NICKNAME} FROM users u WHERE u.id = ?2"))
        .bind(viewer)
        .bind(user)
        .fetch_one(db)
        .await
}

/// Trims and collapses spaces. `None` (or blank) clears the name.
fn clean_name(raw: Option<&str>) -> AppResult<Option<String>> {
    let raw = raw.unwrap_or("");
    crate::text::check_name(raw).map_err(AppError::bad)?;
    let name = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Ok(None);
    }
    if name.chars().count() > MAX_NAME_CHARS {
        return Err(AppError::bad(format!(
            "Names can be at most {MAX_NAME_CHARS} characters."
        )));
    }
    Ok(Some(name))
}

async fn record_name(
    db: &SqlitePool,
    set_by: i64,
    user: i64,
    name: Option<&str>,
) -> sqlx::Result<()> {
    sqlx::query("INSERT INTO user_names (user_id, set_by, name, created_at) VALUES (?, ?, ?, ?)")
        .bind(user)
        .bind(set_by)
        .bind(name)
        .bind(now())
        .execute(db)
        .await?;
    Ok(())
}

/// Tells you (other tabs) and every friend to refetch names and pictures.
async fn tell_friends(state: &SharedState, me: i64) -> AppResult<()> {
    let mut ids: Vec<i64> = crate::profiles::friends_of(&state.db, me)
        .await?
        .into_iter()
        .map(|f| f.id)
        .collect();
    ids.push(me);
    state.hub.send_many(&ids, &Event::FriendsChanged);
    Ok(())
}

#[derive(Deserialize)]
pub struct SetName {
    name: Option<String>,
}

/// `PUT /api/me/name`: your display name, for your friends. Blank clears it.
pub async fn set_display_name(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<SetName>,
) -> AppResult<Json<Value>> {
    let name = clean_name(req.name.as_deref())?;
    record_name(&state.db, me.id, me.id, name.as_deref()).await?;
    tracing::info!(
        user_id = me.id,
        cleared = name.is_none(),
        "display name set"
    );
    tell_friends(&state, me.id).await?;
    Ok(Json(json!({ "display_name": name })))
}

/// `PUT /api/friends/{id}/nickname`: a name for a friend that only you see.
pub async fn set_nickname(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(friend): Path<i64>,
    Json(req): Json<SetName>,
) -> AppResult<Json<Value>> {
    if !db::are_friends(&state.db, me.id, friend).await? {
        return Err(AppError::not_found("You can only nickname your friends."));
    }
    let name = clean_name(req.name.as_deref())?;
    record_name(&state.db, me.id, friend, name.as_deref()).await?;
    tracing::info!(
        user_id = me.id,
        friend_id = friend,
        cleared = name.is_none(),
        "nickname set"
    );
    state.hub.send(me.id, &Event::FriendsChanged); // only you see it
    Ok(Json(json!({ "nickname": name })))
}

/// `POST /api/me/avatar`: raw small image body. Rebuilt by images::clean.
pub async fn set_avatar(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    body: Bytes,
) -> AppResult<Json<Value>> {
    if body.len() < 64 || body.len() > AVATAR_MAX_BYTES {
        return Err(AppError::bad("Profile pictures must be under 128 KB."));
    }
    crate::guard::check_upload_room(&state)?;
    sniff_image(&body)
        .ok_or_else(|| AppError::bad("Profile pictures must be JPEG, PNG, or WebP images."))?;
    if !state.image_upload_limit.allow(&me.id.to_string()) {
        return Err(AppError::TooManyRequests(
            "You're changing pictures too fast. Wait a minute.".into(),
        ));
    }
    let image = crate::images::clean(body, 512).await?;
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO user_avatars (user_id, image, mime, created_at) VALUES (?, ?, 'image/jpeg', ?) RETURNING id",
    )
    .bind(me.id)
    .bind(image.as_slice())
    .bind(now())
    .fetch_one(&state.db)
    .await?;
    tracing::info!(
        user_id = me.id,
        avatar_id = id,
        bytes = image.len(),
        "profile picture set"
    );
    tell_friends(&state, me.id).await?;
    Ok(Json(json!({ "avatar_id": id })))
}

/// `DELETE /api/me/avatar`: stop showing a picture. Adds an empty row; the
/// old pictures stay in the database.
pub async fn clear_avatar(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    sqlx::query(
        "INSERT INTO user_avatars (user_id, image, mime, created_at) VALUES (?, NULL, NULL, ?)",
    )
    .bind(me.id)
    .bind(now())
    .execute(&state.db)
    .await?;
    tracing::info!(user_id = me.id, "profile picture removed");
    tell_friends(&state, me.id).await?;
    Ok(Json(json!({ "avatar_id": null })))
}

/// `GET /api/users/{id}/avatar/{avatar_id}`: you and your friends, and only
/// the current picture (a removed or replaced one isn't served).
pub async fn get_avatar(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path((user, avatar)): Path<(i64, i64)>,
) -> AppResult<Response> {
    let not_found = || AppError::not_found("No such picture.");
    if user != me.id && !db::are_friends(&state.db, me.id, user).await? {
        return Err(not_found());
    }
    if own_profile(&state.db, user).await?.1 != Some(avatar) {
        return Err(not_found());
    }
    let (image, mime): (Vec<u8>, String) =
        sqlx::query_as("SELECT image, mime FROM user_avatars WHERE id = ? AND user_id = ?")
            .bind(avatar)
            .bind(user)
            .fetch_optional(&state.db)
            .await?
            .ok_or_else(not_found)?;
    Ok(image_response(&mime, image))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    async fn user(db: &SqlitePool, id: i64, name: &str) {
        sqlx::query(
            "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at)
             VALUES (?, ?, 'h', 'k', 'w', 0)",
        )
        .bind(id)
        .bind(name)
        .execute(db)
        .await
        .unwrap();
    }

    #[test]
    fn names_are_cleaned_and_checked() {
        assert_eq!(
            clean_name(Some("  Ana   B ")).unwrap().as_deref(),
            Some("Ana B")
        );
        assert_eq!(clean_name(Some("   ")).unwrap(), None);
        assert_eq!(clean_name(None).unwrap(), None);
        assert_eq!(
            clean_name(Some("🌿 Ägäis")).unwrap().as_deref(),
            Some("🌿 Ägäis")
        );
        assert!(clean_name(Some(&"x".repeat(31))).is_err());
        assert!(clean_name(Some("evil\u{202E}gpj")).is_err());
        assert!(clean_name(Some("two\nlines")).is_err());
    }

    #[tokio::test]
    async fn newest_row_wins_and_nicknames_are_private() {
        let db = temp_db().await;
        user(&db, 1, "ana").await;
        user(&db, 2, "ben").await;
        user(&db, 3, "cal").await;
        assert_eq!(own_profile(&db, 2).await.unwrap(), (None, None));

        record_name(&db, 2, 2, Some("Benny")).await.unwrap();
        record_name(&db, 1, 2, Some("Big B")).await.unwrap();
        assert_eq!(
            own_profile(&db, 2).await.unwrap().0.as_deref(),
            Some("Benny")
        );
        assert_eq!(nickname(&db, 1, 2).await.unwrap().as_deref(), Some("Big B"));
        assert_eq!(nickname(&db, 3, 2).await.unwrap(), None); // ana's nickname is hers alone

        assert_eq!(name_for(&db, 1, 2).await.unwrap(), "Big B");
        assert_eq!(name_for(&db, 3, 2).await.unwrap(), "Benny");
        assert_eq!(name_for(&db, 2, 3).await.unwrap(), "cal");
        record_name(&db, 2, 2, None).await.unwrap();
        assert_eq!(own_profile(&db, 2).await.unwrap().0, None);

        for image in [Some(&b"one"[..]), Some(b"two"), None] {
            sqlx::query("INSERT INTO user_avatars (user_id, image, created_at) VALUES (2, ?, 0)")
                .bind(image)
                .execute(&db)
                .await
                .unwrap();
        }
        assert_eq!(own_profile(&db, 2).await.unwrap().1, None); // removed
        let kept: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_avatars")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(kept, 3, "every picture is kept");
    }
}
