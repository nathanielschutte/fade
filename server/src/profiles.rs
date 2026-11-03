//! Profiles: your own (friends list and your stats), or a friend's (what you
//! share with them). Anyone else gets a 404. Only counts and dates: the server
//! can't see message content.

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::Serialize;
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    birthdays::Birthday,
    db::{self, pair},
    error::{AppError, AppResult},
    streaks::{Streak, Tz},
    SharedState,
};

#[derive(Debug, Serialize, FromRow, PartialEq)]
pub struct FriendEntry {
    pub id: i64,
    pub username: String,
    /// When the friendship started (Unix seconds).
    pub since: i64,
}

#[derive(Debug, Serialize, Default, PartialEq)]
pub struct MyStats {
    pub texts_sent: i64,
    pub texts_received: i64,
    pub pics_sent: i64,
    pub pics_received: i64,
    /// Pics you sent that the recipient opened.
    pub pics_opened: i64,
}

#[derive(Debug, Serialize, Default, PartialEq)]
pub struct Together {
    pub texts: i64,
    pub pics: i64,
    pub first_message_at: Option<i64>,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Profile {
    Me {
        id: i64,
        username: String,
        display_name: Option<String>,
        avatar_id: Option<i64>,
        joined_at: i64,
        /// Optional; friends see it too (birthdays.rs).
        birthday: Option<Birthday>,
        friends: Vec<FriendEntry>,
        stats: MyStats,
        /// Your longest pic streak with anyone (streaks.rs).
        longest_streak: i64,
        /// Usernames you had before, newest first (usernames.rs).
        past_usernames: Vec<String>,
        /// When you can change your username again, if not now (once a
        /// week; Admins any time).
        next_rename_at: Option<i64>,
    },
    Friend {
        id: i64,
        username: String,
        display_name: Option<String>,
        /// What you call them; only you see it.
        nickname: Option<String>,
        avatar_id: Option<i64>,
        joined_at: i64,
        birthday: Option<Birthday>,
        friends_since: i64,
        friend_count: i64,
        mutual_friends: Vec<FriendEntry>,
        together: Together,
        /// Your pic streak together: now, whether it's about to run out, and the longest.
        streak: Streak,
        /// Usernames they had before, newest first: old names still lead to them.
        past_usernames: Vec<String>,
    },
}

/// The other side of each of `user`'s friendships, as a subquery with one `?`.
const FRIENDS_OF: &str = "SELECT CASE WHEN f.user_lo = ?1 THEN f.user_hi ELSE f.user_lo END
     FROM friendships f WHERE (f.user_lo = ?1 OR f.user_hi = ?1) AND f.ended_at IS NULL";
/// The same, for the user bound as `?2`.
const FRIENDS_OF_2: &str = "SELECT CASE WHEN g.user_lo = ?2 THEN g.user_hi ELSE g.user_lo END
     FROM friendships g WHERE (g.user_lo = ?2 OR g.user_hi = ?2) AND g.ended_at IS NULL";

async fn joined(db: &SqlitePool, id: i64) -> sqlx::Result<Option<(String, i64)>> {
    sqlx::query_as("SELECT username, created_at FROM users WHERE id = ?")
        .bind(id)
        .fetch_optional(db)
        .await
}

pub async fn friends_of(db: &SqlitePool, user: i64) -> sqlx::Result<Vec<FriendEntry>> {
    sqlx::query_as(
        "SELECT u.id, u.username, f.created_at AS since
         FROM friendships f
         JOIN users u ON u.id = CASE WHEN f.user_lo = ?1 THEN f.user_hi ELSE f.user_lo END
         WHERE (f.user_lo = ?1 OR f.user_hi = ?1) AND f.ended_at IS NULL
         ORDER BY lower(u.username)",
    )
    .bind(user)
    .fetch_all(db)
    .await
}

/// What `?1` has sent and received, and how many of each were pics, and of
/// the pics they sent, how many were opened: each counted in an index
/// (messages_pair, messages_recipient, messages_pics), never reading the
/// messages themselves. Received pics are counted sender by sender (every
/// sender is a user), which messages_pics can do.
const MY_STATS: &str = "SELECT
        (SELECT COUNT(*) FROM messages WHERE sender_id = ?1),
        (SELECT COUNT(*) FROM messages WHERE recipient_id = ?1),
        (SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND sender_id = ?1),
        (SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND recipient_id = ?1
            AND sender_id IN (SELECT id FROM users)),
        (SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND sender_id = ?1 AND snap_state = 'opened')";

pub async fn my_stats(db: &SqlitePool, me: i64) -> sqlx::Result<MyStats> {
    let (sent, received, pics_sent, pics_received, pics_opened): (i64, i64, i64, i64, i64) =
        sqlx::query_as(MY_STATS).bind(me).fetch_one(db).await?;
    // A message is a text or a pic.
    Ok(MyStats {
        texts_sent: sent - pics_sent,
        texts_received: received - pics_received,
        pics_sent,
        pics_received,
        pics_opened,
    })
}

/// What two people (`?1` and `?2`, never the same) have sent each other: how
/// many messages, how many of them pics, and when the first was sent. Each
/// part is counted in an index each way (messages_pair, messages_pics,
/// messages_recipient), never reading the messages themselves.
const TOGETHER: &str = "SELECT
        (SELECT COUNT(*) FROM messages WHERE sender_id = ?1 AND recipient_id = ?2)
          + (SELECT COUNT(*) FROM messages WHERE sender_id = ?2 AND recipient_id = ?1),
        (SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND sender_id = ?1 AND recipient_id = ?2)
          + (SELECT COUNT(*) FROM messages WHERE kind = 'snap' AND sender_id = ?2 AND recipient_id = ?1),
        (SELECT MIN(first) FROM (
            SELECT MIN(created_at) AS first FROM messages WHERE recipient_id = ?2 AND sender_id = ?1
            UNION ALL
            SELECT MIN(created_at) FROM messages WHERE recipient_id = ?1 AND sender_id = ?2))";

pub async fn together(db: &SqlitePool, a: i64, b: i64) -> sqlx::Result<Together> {
    let (all, pics, first_message_at): (i64, i64, Option<i64>) = sqlx::query_as(TOGETHER)
        .bind(a)
        .bind(b)
        .fetch_one(db)
        .await?;
    // A message is a text or a pic.
    Ok(Together {
        texts: all - pics,
        pics,
        first_message_at,
    })
}

pub async fn mutual_friends(db: &SqlitePool, a: i64, b: i64) -> sqlx::Result<Vec<FriendEntry>> {
    // `since` is when *you* became friends with the mutual friend.
    sqlx::query_as(&format!(
        "SELECT u.id, u.username, f.created_at AS since
         FROM friendships f
         JOIN users u ON u.id = CASE WHEN f.user_lo = ?1 THEN f.user_hi ELSE f.user_lo END
         WHERE (f.user_lo = ?1 OR f.user_hi = ?1) AND f.ended_at IS NULL
           AND u.id IN ({FRIENDS_OF_2})
         ORDER BY lower(u.username)"
    ))
    .bind(a)
    .bind(b)
    .fetch_all(db)
    .await
}

/// `GET /api/users/{id}/profile`
pub async fn get(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
    Query(tz): Query<Tz>,
) -> AppResult<Json<Profile>> {
    let profile = profile_for(&state.db, &state.admins, me.id, id, tz.offset_minutes()).await?;
    Ok(Json(profile))
}

/// The profile `me` sees of `id`: their own, or a friend's.
pub(crate) async fn profile_for(
    db: &SqlitePool,
    admins: &crate::roles::Admins,
    me: i64,
    id: i64,
    offset_minutes: i64,
) -> AppResult<Profile> {
    if id == me {
        let (username, joined_at) = joined(db, me).await?.ok_or(AppError::Unauthorized)?;
        let (display_name, avatar_id) = crate::people::own_profile(db, me).await?;
        let admin = crate::usernames::is_listed_admin(db, admins, me, &username).await?;
        let next_rename_at = crate::usernames::last_rename(db, me)
            .await?
            .map(|last| last + crate::usernames::RENAME_EVERY_SECS)
            .filter(|at| !admin && *at > crate::db::now());
        let streaks = crate::streaks::for_friends(db, me, offset_minutes).await?;
        tracing::debug!(user_id = me, "viewed own profile");
        return Ok(Profile::Me {
            id: me,
            username,
            display_name,
            avatar_id,
            joined_at,
            birthday: crate::birthdays::current(db, me).await?,
            friends: friends_of(db, me).await?,
            stats: my_stats(db, me).await?,
            longest_streak: streaks.values().map(|s| s.longest).max().unwrap_or(0),
            past_usernames: past_names(db, me).await?,
            next_rename_at,
        });
    }

    // Only friends see each other's profiles; everyone else looks like nobody.
    if !db::are_friends(db, me, id).await.unwrap_or(false) {
        return Err(AppError::not_found("No profile to show."));
    }
    let (username, joined_at) = joined(db, id)
        .await?
        .ok_or_else(|| AppError::not_found("No profile to show."))?;
    let (lo, hi) = pair(me, id);
    let friends_since: i64 = sqlx::query_scalar(
        "SELECT created_at FROM friendships WHERE user_lo = ? AND user_hi = ? AND ended_at IS NULL",
    )
    .bind(lo)
    .bind(hi)
    .fetch_one(db)
    .await?;
    let friend_count: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) FROM ({FRIENDS_OF})"))
        .bind(id)
        .fetch_one(db)
        .await?;
    let (display_name, avatar_id) = crate::people::own_profile(db, id).await?;
    let nickname = crate::people::nickname(db, me, id).await?;
    tracing::debug!(user_id = me, friend_id = id, "viewed friend profile");
    Ok(Profile::Friend {
        id,
        username,
        display_name,
        nickname,
        avatar_id,
        joined_at,
        birthday: crate::birthdays::current(db, id).await?,
        friends_since,
        friend_count,
        mutual_friends: mutual_friends(db, me, id).await?,
        together: together(db, me, id).await?,
        streak: crate::streaks::with(db, me, id, offset_minutes).await?,
        past_usernames: past_names(db, id).await?,
    })
}

async fn past_names(db: &SqlitePool, user: i64) -> sqlx::Result<Vec<String>> {
    Ok(crate::usernames::past_of(db, user)
        .await?
        .into_iter()
        .map(|(name, _)| name)
        .collect())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::db::tests::{assert_searches, temp_db};
    use crate::testdata::{self, *};

    /// `my_stats` as it was before migration 0028, reading every message.
    pub(crate) async fn old_my_stats(db: &SqlitePool, me: i64) -> sqlx::Result<MyStats> {
        let row: (i64, i64, i64, i64, i64) = sqlx::query_as(
            "SELECT
                COALESCE(SUM(sender_id = ?1 AND kind = 'text'), 0),
                COALESCE(SUM(recipient_id = ?1 AND kind = 'text'), 0),
                COALESCE(SUM(sender_id = ?1 AND kind = 'snap'), 0),
                COALESCE(SUM(recipient_id = ?1 AND kind = 'snap'), 0),
                COALESCE(SUM(sender_id = ?1 AND kind = 'snap' AND snap_state = 'opened'), 0)
             FROM messages WHERE sender_id = ?1 OR recipient_id = ?1",
        )
        .bind(me)
        .fetch_one(db)
        .await?;
        Ok(MyStats {
            texts_sent: row.0,
            texts_received: row.1,
            pics_sent: row.2,
            pics_received: row.3,
            pics_opened: row.4,
        })
    }

    /// `together` as it was before migration 0028, reading the whole chat.
    async fn old_together(db: &SqlitePool, a: i64, b: i64) -> Together {
        let row: (i64, i64, Option<i64>) = sqlx::query_as(
            "SELECT COALESCE(SUM(kind = 'text'), 0), COALESCE(SUM(kind = 'snap'), 0), MIN(created_at)
             FROM messages
             WHERE (sender_id = ?1 AND recipient_id = ?2) OR (sender_id = ?2 AND recipient_id = ?1)",
        )
        .bind(a)
        .bind(b)
        .fetch_one(db)
        .await
        .unwrap();
        Together {
            texts: row.0,
            pics: row.1,
            first_message_at: row.2,
        }
    }

    /// The profile as it was built before migration 0028 (streaks from every
    /// pic, `together` from the whole chat): what `profile_for` must match.
    pub(crate) async fn old_profile_for(
        db: &SqlitePool,
        admins: &crate::roles::Admins,
        me: i64,
        id: i64,
        offset_minutes: i64,
    ) -> AppResult<Profile> {
        let streaks = crate::streaks::tests::old_for_friends(db, me, offset_minutes).await?;
        if id == me {
            let (username, joined_at) = joined(db, me).await?.ok_or(AppError::Unauthorized)?;
            let (display_name, avatar_id) = crate::people::own_profile(db, me).await?;
            let admin = crate::usernames::is_listed_admin(db, admins, me, &username).await?;
            let next_rename_at = crate::usernames::last_rename(db, me)
                .await?
                .map(|last| last + crate::usernames::RENAME_EVERY_SECS)
                .filter(|at| !admin && *at > crate::db::now());
            return Ok(Profile::Me {
                id: me,
                username,
                display_name,
                avatar_id,
                joined_at,
                birthday: crate::birthdays::current(db, me).await?,
                friends: friends_of(db, me).await?,
                stats: old_my_stats(db, me).await?,
                longest_streak: streaks.values().map(|s| s.longest).max().unwrap_or(0),
                past_usernames: past_names(db, me).await?,
                next_rename_at,
            });
        }
        if !db::are_friends(db, me, id).await? {
            return Err(AppError::not_found("No profile to show."));
        }
        let (username, joined_at) = joined(db, id)
            .await?
            .ok_or_else(|| AppError::not_found("No profile to show."))?;
        let (lo, hi) = pair(me, id);
        let friends_since: i64 = sqlx::query_scalar(
            "SELECT created_at FROM friendships WHERE user_lo = ? AND user_hi = ? AND ended_at IS NULL",
        )
        .bind(lo)
        .bind(hi)
        .fetch_one(db)
        .await?;
        let friend_count: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) FROM ({FRIENDS_OF})"))
            .bind(id)
            .fetch_one(db)
            .await?;
        let (display_name, avatar_id) = crate::people::own_profile(db, id).await?;
        let nickname = crate::people::nickname(db, me, id).await?;
        Ok(Profile::Friend {
            id,
            username,
            display_name,
            nickname,
            avatar_id,
            joined_at,
            birthday: crate::birthdays::current(db, id).await?,
            friends_since,
            friend_count,
            mutual_friends: mutual_friends(db, me, id).await?,
            together: old_together(db, me, id).await,
            streak: streaks.get(&id).copied().unwrap_or_default(),
            past_usernames: past_names(db, id).await?,
        })
    }

    /// What a profile request answers, as text: the JSON, or the error.
    fn answer(r: AppResult<Profile>) -> String {
        match r {
            Ok(p) => serde_json::to_string(&p).unwrap(),
            Err(e) => format!("{e:?}"),
        }
    }

    /// Every profile everyone in the mix can ask for (and some they can't),
    /// in two time zones: exactly what the old queries answered.
    #[tokio::test]
    async fn profiles_are_what_they_were() {
        let db = temp_db().await;
        testdata::mix(&db).await;
        let admins = crate::roles::Admins::new(vec!["cal".into()], None);
        for me in PEOPLE {
            for id in PEOPLE {
                for tz in [0, 600] {
                    let new = answer(profile_for(&db, &admins, me, id, tz).await);
                    let old = answer(old_profile_for(&db, &admins, me, id, tz).await);
                    assert_eq!(new, old, "{me} viewing {id}, tz {tz}");
                }
            }
        }
        // By hand: Ana and Ben's together, and a profile only friends see.
        assert_eq!(
            together(&db, ANA, BEN).await.unwrap(),
            Together {
                texts: 31,
                pics: 7,
                first_message_at: Some(now_of(&db).await - 50 * DAY)
            }
        );
        assert!(answer(profile_for(&db, &admins, ANA, GUS, 0).await).contains("No profile"));
        let me = answer(profile_for(&db, &admins, ANA, ANA, 0).await);
        assert!(
            me.contains("\"longest_streak\":70") && me.contains("\"past_usernames\":[\"anna\"]")
        );
    }

    /// When the mix was written: the first users row's sign-up, plus its offset.
    async fn now_of(db: &SqlitePool) -> i64 {
        let created: i64 = sqlx::query_scalar("SELECT created_at FROM users WHERE id = 1")
            .fetch_one(db)
            .await
            .unwrap();
        created + 400 * DAY - 1
    }

    /// Everyone's own counts, against the old query, and by hand for Ana.
    #[tokio::test]
    async fn counts_are_what_they_were() {
        let db = temp_db().await;
        testdata::mix(&db).await;
        for me in PEOPLE {
            assert_eq!(
                my_stats(&db, me).await.unwrap(),
                old_my_stats(&db, me).await.unwrap(),
                "{me}"
            );
        }
        let ana = my_stats(&db, ANA).await.unwrap();
        // To Ben 3, Cal 71, Fay 5, Jo 2; all opened but Cal's newest.
        assert_eq!((ana.pics_sent, ana.pics_opened), (81, 80));
    }

    /// Profiles count your messages and the chat's in indexes alone, never
    /// reading the messages themselves.
    #[tokio::test]
    async fn profiles_search_indexes() {
        let db = temp_db().await;
        for sql in [MY_STATS, TOGETHER] {
            assert_searches(&db, sql, &[], &[]).await;
            let plan = crate::db::tests::plan(&db, sql).await;
            assert!(
                plan.iter()
                    .all(|s| !s.starts_with("SEARCH messages ") || s.contains("COVERING INDEX")),
                "counted in indexes alone: {plan:#?}"
            );
        }
    }

    async fn user(db: &SqlitePool, id: i64, name: &str) {
        sqlx::query(
            "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at)
             VALUES (?, ?, 'h', 'k', 'w', ?)",
        )
        .bind(id)
        .bind(name)
        .bind(1000 + id)
        .execute(db)
        .await
        .unwrap();
    }

    async fn friends(db: &SqlitePool, a: i64, b: i64, at: i64) {
        let (lo, hi) = pair(a, b);
        sqlx::query("INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (?, ?, ?)")
            .bind(lo)
            .bind(hi)
            .bind(at)
            .execute(db)
            .await
            .unwrap();
    }

    async fn msg(db: &SqlitePool, from: i64, to: i64, kind: &str, state: Option<&str>, at: i64) {
        sqlx::query(
            "INSERT INTO messages (sender_id, recipient_id, kind, snap_state, created_at) VALUES (?, ?, ?, ?, ?)",
        )
        .bind(from)
        .bind(to)
        .bind(kind)
        .bind(state)
        .bind(at)
        .execute(db)
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn stats_friends_and_mutuals() {
        let db = temp_db().await;
        // 1=ana, 2=Ben, 3=cal, 4=dee. ana-Ben, ana-cal, Ben-cal, Ben-dee.
        for (id, name) in [(1, "ana"), (2, "Ben"), (3, "cal"), (4, "dee")] {
            user(&db, id, name).await;
        }
        friends(&db, 1, 2, 50).await;
        friends(&db, 1, 3, 60).await;
        friends(&db, 2, 3, 70).await;
        friends(&db, 2, 4, 80).await;
        msg(&db, 1, 2, "text", None, 100).await;
        msg(&db, 2, 1, "text", None, 101).await;
        msg(&db, 2, 1, "text", None, 102).await;
        msg(&db, 1, 2, "snap", Some("opened"), 103).await;
        msg(&db, 1, 3, "snap", Some("expired"), 104).await;
        msg(&db, 3, 1, "snap", Some("pending"), 105).await;
        msg(&db, 2, 4, "text", None, 106).await; // not ana's

        let names = |v: Vec<FriendEntry>| v.into_iter().map(|f| f.username).collect::<Vec<_>>();
        assert_eq!(names(friends_of(&db, 1).await.unwrap()), vec!["Ben", "cal"]);
        assert_eq!(
            my_stats(&db, 1).await.unwrap(),
            MyStats {
                texts_sent: 1,
                texts_received: 2,
                pics_sent: 2,
                pics_received: 1,
                pics_opened: 1
            }
        );
        assert_eq!(
            together(&db, 1, 2).await.unwrap(),
            Together {
                texts: 3,
                pics: 1,
                first_message_at: Some(100)
            }
        );
        assert_eq!(together(&db, 1, 4).await.unwrap(), Together::default());
        // ana and Ben share cal; dee is only Ben's friend.
        assert_eq!(names(mutual_friends(&db, 1, 2).await.unwrap()), vec!["cal"]);
        assert_eq!(names(mutual_friends(&db, 2, 1).await.unwrap()), vec!["cal"]);
        assert!(mutual_friends(&db, 3, 4)
            .await
            .unwrap()
            .iter()
            .any(|f| f.username == "Ben"));
        assert_eq!(my_stats(&db, 99).await.unwrap(), MyStats::default());

        // An ended friendship disappears from friends and mutuals, but the row stays.
        sqlx::query(
            "UPDATE friendships SET ended_at = 200, ended_by = 1 WHERE user_lo = 1 AND user_hi = 3",
        )
        .execute(&db)
        .await
        .unwrap();
        assert_eq!(names(friends_of(&db, 1).await.unwrap()), vec!["Ben"]);
        assert!(mutual_friends(&db, 1, 2).await.unwrap().is_empty());
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM friendships")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rows, 4);
    }
}
