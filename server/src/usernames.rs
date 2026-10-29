//! Usernames that changed (plan X30). The rename itself is in account.rs,
//! next to the password change it works like: the username salts the
//! password, so the app locks the private key again under the new name.
//!
//! Every old username is kept in `past_usernames`, reserved for its owner
//! forever: nobody else can sign up with it or take it in a rename, and it
//! still finds them (a friend request to an old name reaches the person, and
//! an Admin listed under an old name is still an Admin). A rename is allowed
//! once every 7 days, except for Admins.

use sqlx::SqlitePool;

/// The least time between renames, for everyone but Admins.
pub const RENAME_EVERY_SECS: i64 = 7 * 86_400;
/// Friends see "was @old" this long after a rename.
pub const SHOW_RENAME_SECS: i64 = 30 * 86_400;

/// Who once had `name` (any case), if anyone.
pub async fn past_holder(db: &SqlitePool, name: &str) -> sqlx::Result<Option<i64>> {
    sqlx::query_scalar("SELECT user_id FROM past_usernames WHERE username = ?")
        .bind(name.trim())
        .fetch_optional(db)
        .await
}

/// Someone's earlier usernames, newest first, with when each stopped.
pub async fn past_of(db: &SqlitePool, user: i64) -> sqlx::Result<Vec<(String, i64)>> {
    sqlx::query_as("SELECT username, until FROM past_usernames WHERE user_id = ? ORDER BY id DESC")
        .bind(user)
        .fetch_all(db)
        .await
}

/// When `user` last renamed, if ever.
pub async fn last_rename(db: &SqlitePool, user: i64) -> sqlx::Result<Option<i64>> {
    sqlx::query_scalar("SELECT MAX(until) FROM past_usernames WHERE user_id = ?")
        .bind(user)
        .fetch_one(db)
        .await
}

/// Is `name` free for `user`: nobody else has it now, or ever had it? Their
/// own old names are theirs to go back to.
pub async fn available_to(db: &SqlitePool, user: i64, name: &str) -> sqlx::Result<bool> {
    let taken: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM users WHERE username = ?1 AND id != ?2)
             OR EXISTS (SELECT 1 FROM past_usernames WHERE username = ?1 AND user_id != ?2)",
    )
    .bind(name)
    .bind(user)
    .fetch_one(db)
    .await?;
    Ok(!taken)
}

/// Is `user` (now `username`) an Admin? Admins are listed by username in
/// settings, so an old name still counts: nobody else can ever hold it.
pub async fn is_listed_admin(
    db: &SqlitePool,
    admins: &crate::roles::Admins,
    user: i64,
    username: &str,
) -> sqlx::Result<bool> {
    if admins.contains(username) {
        return Ok(true);
    }
    Ok(past_of(db, user)
        .await?
        .iter()
        .any(|(name, _)| admins.contains(name)))
}

/// Everyone who is an Admin by a name they have now or had before.
pub async fn admin_ids(
    db: &SqlitePool,
    admins: &crate::roles::Admins,
) -> sqlx::Result<std::collections::HashSet<i64>> {
    let names: Vec<(i64, String)> = sqlx::query_as(
        "SELECT id, username FROM users UNION ALL SELECT user_id, username FROM past_usernames",
    )
    .fetch_all(db)
    .await?;
    Ok(names
        .into_iter()
        .filter(|(_, name)| admins.contains(name))
        .map(|(id, _)| id)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[tokio::test]
    async fn old_names_stay_with_their_owner() {
        let db = temp_db().await;
        for (id, name) in [(1, "anna"), (2, "ben")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        sqlx::query("INSERT INTO past_usernames (user_id, username, until) VALUES (1, 'ana', 100)")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(past_holder(&db, "ANA").await.unwrap(), Some(1), "any case");
        assert_eq!(past_holder(&db, "cal").await.unwrap(), None);
        assert!(
            !available_to(&db, 2, "ana").await.unwrap(),
            "nobody else can take it"
        );
        assert!(
            available_to(&db, 1, "ana").await.unwrap(),
            "its owner can go back to it"
        );
        assert!(
            !available_to(&db, 1, "Ben").await.unwrap(),
            "or take someone's current name"
        );
        assert!(available_to(&db, 2, "cal").await.unwrap());
        assert_eq!(last_rename(&db, 1).await.unwrap(), Some(100));
        assert_eq!(last_rename(&db, 2).await.unwrap(), None);
        let admins = crate::roles::Admins::new(vec!["ana".into()], None);
        assert!(
            is_listed_admin(&db, &admins, 1, "anna").await.unwrap(),
            "an Admin renamed is still one"
        );
        assert!(!is_listed_admin(&db, &admins, 2, "ben").await.unwrap());
        assert_eq!(
            admin_ids(&db, &admins).await.unwrap(),
            [1].into_iter().collect()
        );
    }
}
