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

/// The chat list works streaks out from this many days of pics, so it reads
/// about the same however long people have been sending them. A streak that
/// runs back past them is worked out again from all of that friend's pics.
const RECENT_DAYS: i64 = 62;

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

/// A streak as the chat list shows it: how long it is now, and whether it's
/// about to run out. (Not the longest ever: that takes every pic ever sent.)
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Running {
    pub current: i64,
    pub expiring: bool,
}

/// Pics between `?1` and each person in the JSON list `?4`, sent at or after
/// `?3` (Unix seconds), as (person, 1 if `?1` sent it, local day); `?2` is
/// the time zone in seconds. Each person is two searches of messages_pics,
/// which holds only pics, by pair and time.
const DAYS_WITH: &str = "SELECT p.recipient_id, 1, (p.created_at + ?2) / 86400 FROM messages p
      WHERE p.kind = 'snap' AND p.sender_id = ?1 AND p.created_at >= ?3
        AND p.recipient_id IN (SELECT value FROM json_each(?4))
     UNION ALL
     SELECT p.sender_id, 0, (p.created_at + ?2) / 86400 FROM messages p
      WHERE p.kind = 'snap' AND p.recipient_id = ?1 AND p.created_at >= ?3 AND p.sender_id != ?1
        AND p.sender_id IN (SELECT value FROM json_each(?4))";

/// The same over all time, with everyone `?1` has sent a pic to (nobody else
/// can have a streak with them).
const DAYS_WITH_ANYONE: &str = "SELECT p.recipient_id, 1, (p.created_at + ?2) / 86400 FROM messages p
      WHERE p.kind = 'snap' AND p.sender_id = ?1
     UNION ALL
     SELECT p.sender_id, 0, (p.created_at + ?2) / 86400 FROM messages p
      WHERE p.kind = 'snap' AND p.recipient_id = ?1 AND p.sender_id != ?1
        AND p.sender_id IN (SELECT q.recipient_id FROM messages q WHERE q.kind = 'snap' AND q.sender_id = ?1)";

/// By person: (the days `me` sent them a pic, the days they sent `me` one).
type Days = HashMap<i64, (BTreeSet<i64>, BTreeSet<i64>)>;

fn by_person(rows: Vec<(i64, bool, i64)>) -> Days {
    let mut days = Days::new();
    for (friend, mine, day) in rows {
        let entry = days.entry(friend).or_default();
        if mine {
            entry.0.insert(day);
        } else {
            entry.1.insert(day);
        }
    }
    days
}

fn both((mine, theirs): &(BTreeSet<i64>, BTreeSet<i64>)) -> BTreeSet<i64> {
    mine.intersection(theirs).copied().collect()
}

async fn days_with(
    db: &SqlitePool,
    me: i64,
    offset_minutes: i64,
    people: &[i64],
    since: i64,
) -> sqlx::Result<Days> {
    let rows = sqlx::query_as(DAYS_WITH)
        .bind(me)
        .bind(offset_minutes * 60)
        .bind(since)
        .bind(crate::db::json_ids(people))
        .fetch_all(db)
        .await?;
    Ok(by_person(rows))
}

/// Every friend's streak with `me`, by friend id (only those with any pics
/// both ways): your own profile's longest.
pub async fn for_friends(
    db: &SqlitePool,
    me: i64,
    offset_minutes: i64,
) -> sqlx::Result<HashMap<i64, Streak>> {
    let (today, left) = today(offset_minutes);
    everyone(db, me, offset_minutes, today, left).await
}

async fn everyone(
    db: &SqlitePool,
    me: i64,
    offset_minutes: i64,
    today: i64,
    left: i64,
) -> sqlx::Result<HashMap<i64, Streak>> {
    let rows = sqlx::query_as(DAYS_WITH_ANYONE)
        .bind(me)
        .bind(offset_minutes * 60)
        .fetch_all(db)
        .await?;
    Ok(by_person(rows)
        .into_iter()
        .map(|(friend, days)| (friend, compute(&both(&days), today, left)))
        .filter(|(_, s)| s.longest > 0)
        .collect())
}

/// `me`'s streak with one friend, over all time: their profile.
pub async fn with(
    db: &SqlitePool,
    me: i64,
    friend: i64,
    offset_minutes: i64,
) -> sqlx::Result<Streak> {
    let (today, left) = today(offset_minutes);
    pair(db, me, friend, offset_minutes, today, left).await
}

async fn pair(
    db: &SqlitePool,
    me: i64,
    friend: i64,
    offset_minutes: i64,
    today: i64,
    left: i64,
) -> sqlx::Result<Streak> {
    let days = days_with(db, me, offset_minutes, &[friend], i64::MIN).await?;
    Ok(days
        .get(&friend)
        .map(|days| compute(&both(days), today, left))
        .unwrap_or_default())
}

/// The chat list's streaks with `people`, worked out from the last
/// RECENT_DAYS days of pics: the same as from all of them, since a run that
/// reaches back to the first of those days is worked out again from all of
/// that friend's pics.
pub async fn for_chats(
    db: &SqlitePool,
    me: i64,
    people: &[i64],
    offset_minutes: i64,
) -> sqlx::Result<HashMap<i64, Running>> {
    let (today, left) = today(offset_minutes);
    running(db, me, people, offset_minutes, today, left).await
}

async fn running(
    db: &SqlitePool,
    me: i64,
    people: &[i64],
    offset_minutes: i64,
    today: i64,
    left: i64,
) -> sqlx::Result<HashMap<i64, Running>> {
    if people.is_empty() {
        return Ok(HashMap::new());
    }
    let first = today - RECENT_DAYS;
    // The first second of that local day (local time is UTC plus the offset).
    let since = first * 86_400 - offset_minutes * 60;
    let mut out = HashMap::new();
    for (friend, days) in days_with(db, me, offset_minutes, people, since).await? {
        let both = both(&days);
        let mut s = compute(&both, today, left);
        let last = if both.contains(&today) {
            today
        } else {
            today - 1
        };
        if s.current > 0 && last - s.current < first {
            s = pair(db, me, friend, offset_minutes, today, left).await?;
        }
        out.insert(
            friend,
            Running {
                current: s.current,
                expiring: s.expiring,
            },
        );
    }
    Ok(out)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::db::tests::{assert_searches, temp_db};
    use crate::testdata::{self, ANA, BEN, CAL, FAY, HAL, JO, PEOPLE, ZONES};

    /// `for_friends` as it was before migration 0028, one query over every
    /// message (its time made a parameter): what the new ones must match.
    pub(crate) async fn old_for_friends_at(
        db: &SqlitePool,
        me: i64,
        offset_minutes: i64,
        today: i64,
        left: i64,
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
        Ok(days
            .into_iter()
            .map(|(friend, (mine, theirs))| {
                let both: BTreeSet<i64> = mine.intersection(&theirs).copied().collect();
                (friend, compute(&both, today, left))
            })
            .filter(|(_, s)| s.longest > 0)
            .collect())
    }

    pub(crate) async fn old_for_friends(
        db: &SqlitePool,
        me: i64,
        offset_minutes: i64,
    ) -> sqlx::Result<HashMap<i64, Streak>> {
        let (today, left) = today(offset_minutes);
        old_for_friends_at(db, me, offset_minutes, today, left).await
    }

    /// Everyone in the mix, in every time zone, on several days and at times
    /// of day either side of "about to run out": the same streaks as from
    /// one read of every message, everyone's, one friend's, and the chat
    /// list's from recent days only.
    #[tokio::test]
    async fn streaks_are_what_they_were() {
        let db = temp_db().await;
        testdata::mix(&db).await;
        let mut checked = 0;
        let mut seen = (0, 0, 0); // running now, about to run out, worked out again from all pics
        for tz in ZONES {
            let (real_today, _) = today(tz);
            for today in [real_today - 1, real_today, real_today + 1] {
                for left in [5, 359, 360, 1000] {
                    // Everyone who has sent or been sent a pic.
                    for me in [ANA, BEN, CAL, FAY, HAL, JO] {
                        let old = old_for_friends_at(&db, me, tz, today, left).await.unwrap();
                        assert_eq!(everyone(&db, me, tz, today, left).await.unwrap(), old);
                        let people: Vec<i64> = PEOPLE.into_iter().filter(|&p| p != me).collect();
                        let chats = running(&db, me, &people, tz, today, left).await.unwrap();
                        for friend in people {
                            let was = old.get(&friend).copied().unwrap_or_default();
                            if left == 359 || (left == 360 && was != Streak::default()) {
                                let pair = pair(&db, me, friend, tz, today, left).await.unwrap();
                                assert_eq!(
                                    pair, was,
                                    "{me} with {friend}, tz {tz}, day {today}, {left} left"
                                );
                            }
                            let chat = chats.get(&friend).copied().unwrap_or_default();
                            assert_eq!(
                                (chat.current, chat.expiring),
                                (was.current, was.expiring),
                                "{me}'s chat with {friend}, tz {tz}, day {today}, {left} left"
                            );
                            seen.0 += (was.current > 0) as i64;
                            seen.1 += was.expiring as i64;
                            seen.2 += (was.current >= RECENT_DAYS) as i64;
                            checked += 1;
                        }
                    }
                }
            }
        }
        assert!(
            checked > 1000 && seen.0 > 0 && seen.1 > 0 && seen.2 > 0,
            "{checked} {seen:?}"
        );

        // What the mix is meant to have, by hand (UTC, ten hours left today).
        let (today, _) = today(0);
        let ana = old_for_friends_at(&db, ANA, 0, today, 600).await.unwrap();
        assert_eq!((ana[&BEN].current, ana[&BEN].longest), (3, 3));
        assert_eq!(
            (ana[&CAL].current, ana[&CAL].longest),
            (70, 70),
            "longer than the chat list reads"
        );
        assert_eq!(
            (ana[&FAY].current, ana[&FAY].longest),
            (0, 5),
            "long ago, with an ex-friend"
        );
        assert!(!ana.contains_key(&JO), "one way only");
        let ben = old_for_friends_at(&db, BEN, 0, today, 600).await.unwrap();
        assert_eq!(
            (ben[&CAL].current, ben[&HAL].current),
            (62, 61),
            "at the edge of what it reads"
        );
        let chats = running(&db, BEN, &[CAL, HAL], 0, today, 600).await.unwrap();
        assert_eq!((chats[&CAL].current, chats[&HAL].current), (62, 61));
    }

    /// Streaks read the pics index (messages_pics), never every message.
    #[tokio::test]
    async fn streaks_search_the_pics_index() {
        let db = temp_db().await;
        for sql in [DAYS_WITH, DAYS_WITH_ANYONE] {
            assert_searches(&db, sql, &[], &["p", "q"]).await;
            let plan = crate::db::tests::plan(&db, sql).await;
            assert!(
                plan.iter().all(|step| !step.starts_with("SEARCH p ")
                    || step.contains("COVERING INDEX messages_pics ")),
                "{plan:#?}"
            );
        }
    }

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
