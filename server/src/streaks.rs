//! Streaks (F15): how many days in a row you and a friend have both sent
//! each other a pic. Worked out from when direct pics were sent (metadata the
//! server already has; nothing about what they show), in the viewer's own
//! time zone, which the app passes as `?tz=<minutes east of UTC>`. Group pics
//! don't count. The apps show a streak from 3 days.

use std::collections::{BTreeSet, HashMap};

use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use crate::db::now;

/// "About to run out": less than this left of today, and today hasn't counted yet.
const EXPIRING_MINUTES: i64 = 6 * 60;

#[derive(Deserialize, Default)]
pub struct Tz {
    /// Minutes east of UTC (JavaScript's `-new Date().getTimezoneOffset()`).
    tz: Option<i64>,
}

impl Tz {
    /// Clamped to real time zones (UTC-14 to UTC+14); none means UTC.
    pub fn offset_minutes(&self) -> i64 {
        self.tz.unwrap_or(0).clamp(-14 * 60, 14 * 60)
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Serialize)]
pub struct Streak {
    /// Days in a row up to today (or up to yesterday, if today hasn't counted yet).
    pub current: i64,
    /// Today hasn't counted yet, and it's nearly over.
    pub expiring: bool,
    /// The longest run ever.
    pub longest: i64,
}

/// `both`: the local days on which both people sent each other a pic.
pub fn compute(both: &BTreeSet<i64>, today: i64, minutes_left_today: i64) -> Streak {
    let run_back = |from: i64| (0..).take_while(|k| both.contains(&(from - k))).count() as i64;
    let (current, expiring) = if both.contains(&today) {
        (run_back(today), false)
    } else {
        let alive = run_back(today - 1);
        (alive, alive > 0 && minutes_left_today < EXPIRING_MINUTES)
    };
    let mut longest = 0;
    let mut run = 0;
    let mut prev: Option<i64> = None;
    for &d in both {
        run = if prev == Some(d - 1) { run + 1 } else { 1 };
        longest = longest.max(run);
        prev = Some(d);
    }
    Streak {
        current,
        expiring,
        longest,
    }
}

/// Today's local day number, and the minutes left in it.
fn today(offset_minutes: i64) -> (i64, i64) {
    let local = now() + offset_minutes * 60;
    let day = local.div_euclid(86_400);
    (day, (86_400 - local.rem_euclid(86_400)) / 60)
}

/// Every friend's streak with `me`, by friend id (only those with any pics both ways).
pub async fn for_friends(
    db: &SqlitePool,
    me: i64,
    offset_minutes: i64,
) -> sqlx::Result<HashMap<i64, Streak>> {
    let rows: Vec<(i64, bool, i64)> = sqlx::query_as(
        "SELECT CASE WHEN sender_id = ?1 THEN recipient_id ELSE sender_id END AS friend,
                sender_id = ?1 AS mine,
                (created_at + ?2) / 86400 AS day
         FROM messages
         WHERE kind = 'snap' AND (sender_id = ?1 OR recipient_id = ?1)
         GROUP BY friend, mine, day",
    )
    .bind(me)
    .bind(offset_minutes * 60)
    .fetch_all(db)
    .await?;
    let mut days: HashMap<i64, (BTreeSet<i64>, BTreeSet<i64>)> = HashMap::new();
    for (friend, mine, day) in rows {
        let entry = days.entry(friend).or_default();
        if mine {
            entry.0.insert(day);
        } else {
            entry.1.insert(day);
        }
    }
    let (today, left) = today(offset_minutes);
    Ok(days
        .into_iter()
        .map(|(friend, (mine, theirs))| {
            let both: BTreeSet<i64> = mine.intersection(&theirs).copied().collect();
            (friend, compute(&both, today, left))
        })
        .filter(|(_, s)| s.longest > 0)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    fn days(d: &[i64]) -> BTreeSet<i64> {
        d.iter().copied().collect()
    }

    #[test]
    fn a_streak_counts_days_in_a_row() {
        let today = 100;
        // Today counted: 98, 99, 100.
        assert_eq!(
            compute(&days(&[98, 99, 100]), today, 600),
            Streak {
                current: 3,
                expiring: false,
                longest: 3
            }
        );
        // Today not yet: still alive through yesterday, and not running out with 10 hours left.
        assert_eq!(
            compute(&days(&[97, 98, 99]), today, 600),
            Streak {
                current: 3,
                expiring: false,
                longest: 3
            }
        );
        // ...but with 2 hours left, it's about to.
        assert!(compute(&days(&[97, 98, 99]), today, 120).expiring);
        // A missed day ends it; the longest run is remembered.
        assert_eq!(
            compute(&days(&[90, 91, 92, 93, 97, 98]), today, 600),
            Streak {
                current: 0,
                expiring: false,
                longest: 4
            }
        );
        assert_eq!(compute(&days(&[]), today, 10), Streak::default());
        assert!(
            !compute(&days(&[50]), today, 10).expiring,
            "nothing alive, nothing expiring"
        );
    }

    #[test]
    fn time_zones_are_clamped() {
        assert_eq!(Tz { tz: Some(-300) }.offset_minutes(), -300);
        assert_eq!(Tz { tz: Some(99_999) }.offset_minutes(), 840);
        assert_eq!(Tz { tz: None }.offset_minutes(), 0);
    }

    #[tokio::test]
    async fn both_people_must_send_on_the_same_local_day() {
        let db = temp_db().await;
        for (id, name) in [(1, "ana"), (2, "ben"), (3, "cal")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
                .bind(id).bind(name).execute(&db).await.unwrap();
        }
        let (today, _) = today(0);
        let at = |day: i64, hour: i64| day * 86_400 + hour * 3600;
        let snap = |from: i64, to: i64, t: i64| {
            let db = db.clone();
            async move {
                sqlx::query("INSERT INTO messages (sender_id, recipient_id, kind, ciphertext, created_at, snap_state) VALUES (?, ?, 'snap', NULL, ?, 'opened')")
                    .bind(from).bind(to).bind(t).execute(&db).await.unwrap();
            }
        };
        // Ana and Ben, both ways, today and the two days before: a 3-day streak.
        for d in [today - 2, today - 1, today] {
            snap(1, 2, at(d, 9)).await;
            snap(2, 1, at(d, 10)).await;
        }
        // Ana and Cal: only Ana sends. No streak.
        for d in [today - 1, today] {
            snap(1, 3, at(d, 9)).await;
        }
        let s = for_friends(&db, 1, 0).await.unwrap();
        assert_eq!(s.get(&2).map(|s| s.current), Some(3));
        assert!(!s.contains_key(&3), "one-sided pics aren't a streak");
        // Ben sees the same streak from his side.
        assert_eq!(
            for_friends(&db, 2, 0)
                .await
                .unwrap()
                .get(&1)
                .map(|s| s.current),
            Some(3)
        );
    }
}
