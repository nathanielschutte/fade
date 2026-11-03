//! Test data for the lists every app reads again and again (the chat list,
//! a chat, groups, profiles, the friend map): a small mix that each one is
//! checked against its old self with, so the faster queries return exactly
//! what the old ones did, and a large set to time them on (`timing`).

use sqlx::SqlitePool;

use crate::db::now;

pub const DAY: i64 = 86_400;

pub const ANA: i64 = 1;
pub const BEN: i64 = 2;
pub const CAL: i64 = 3;
/// Turned off by an Admin.
pub const DEE: i64 = 4;
/// A friend with no messages.
pub const EVE: i64 = 5;
/// Ana's friend once, not now; still Ben's.
pub const FAY: i64 = 6;
pub const GUS: i64 = 7;
/// Team Napsack.
pub const TEAM: i64 = 8;
pub const HAL: i64 = 9;
pub const IVY: i64 = 10;
/// Doesn't share activity.
pub const JO: i64 = 11;
/// Deleted their account.
pub const ZED: i64 = 12;
pub const PEOPLE: [i64; 12] = [ANA, BEN, CAL, DEE, EVE, FAY, GUS, TEAM, HAL, IVY, JO, ZED];

/// Ana (owner), Ben, Cal, Hal, and Zed until he left: plain and sealed
/// texts, an edit, pics of each format, reactions.
pub const TRIP: i64 = 20;
/// Ben's; Ana joined late, and its newest message is a sealed pic.
pub const LATE: i64 = 21;
/// Ana left it.
pub const GONE: i64 = 22;
/// A favorite of Ana's, and muted.
pub const QUIET: i64 = 23;
/// Ana sees nothing in these yet (two, so their order in the list is tested).
pub const BLANK_A: i64 = 24;
pub const BLANK_B: i64 = 25;
pub const GROUPS: [i64; 6] = [TRIP, LATE, GONE, QUIET, BLANK_A, BLANK_B];

/// Time zones to check streaks in, minutes east of UTC: at any time of day,
/// some of these are late enough for a streak to be about to run out.
pub const ZONES: [i64; 10] = [-720, -540, -360, -180, 0, 180, 360, 540, 720, 840];

async fn run(db: &SqlitePool, sql: &str, binds: &[i64]) -> i64 {
    let mut q = sqlx::query(sql);
    for b in binds {
        q = q.bind(b);
    }
    q.execute(db).await.unwrap().last_insert_rowid()
}

/// A text from `from` to `to`, read or not; its id.
async fn text(db: &SqlitePool, from: i64, to: i64, at: i64, read: bool) -> i64 {
    sqlx::query(
        "INSERT INTO messages (sender_id, recipient_id, kind, ciphertext, format, created_at, read_at)
         VALUES (?, ?, 'text', 'sealed text ' || ?3, 2, ?3, ?4)",
    )
    .bind(from)
    .bind(to)
    .bind(at)
    .bind(read.then_some(at + 30))
    .execute(db)
    .await
    .unwrap()
    .last_insert_rowid()
}

/// A pic from `from` to `to`: "pending", "opened", or "expired".
async fn pic(db: &SqlitePool, from: i64, to: i64, at: i64, state: &str) -> i64 {
    sqlx::query(
        "INSERT INTO messages (sender_id, recipient_id, kind, format, snap_state, created_at, read_at, snap_bytes)
         VALUES (?, ?, 'snap', 2, ?, ?, ?, 900)",
    )
    .bind(from)
    .bind(to)
    .bind(state)
    .bind(at)
    .bind((state != "pending").then_some(at + 60))
    .execute(db)
    .await
    .unwrap()
    .last_insert_rowid()
}

/// Pics both ways between `a` and `b` on each of these UTC days.
async fn pics_both_ways(db: &SqlitePool, a: i64, b: i64, days: impl Iterator<Item = i64>) {
    for day in days {
        pic(db, a, b, day * DAY + 11 * 3600, "opened").await;
        pic(db, b, a, day * DAY + 12 * 3600, "opened").await;
    }
}

/// A group message; its id.
#[allow(clippy::too_many_arguments)]
async fn post(
    db: &SqlitePool,
    id: i64,
    group: i64,
    from: i64,
    kind: &str,
    body: &str,
    format: i64,
    at: i64,
    pic: Option<i64>,
) -> i64 {
    sqlx::query(
        "INSERT INTO group_messages (id, group_id, sender_id, kind, body, format, created_at, pic_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(group)
    .bind(from)
    .bind(kind)
    .bind(body)
    .bind(format)
    .bind(at)
    .bind(pic)
    .execute(db)
    .await
    .unwrap();
    id
}

/// Seals message `id` for `members`, with keys for `keyed` (who may be fewer).
async fn seal(db: &SqlitePool, id: i64, members: &[i64], keyed: &[i64]) {
    sqlx::query("UPDATE group_messages SET client_id = 'cid' || id, recipients = ? WHERE id = ?")
        .bind(serde_json::to_string(members).unwrap())
        .bind(id)
        .execute(db)
        .await
        .unwrap();
    for user in keyed {
        sqlx::query("INSERT INTO group_message_keys (message_id, user_id, wrapped) VALUES (?1, ?2, 'wrap ' || ?1 || ' for ' || ?2)")
            .bind(id)
            .bind(user)
            .execute(db)
            .await
            .unwrap();
    }
}

/// A group pic's row: format 0 (seen by the server) or a sealed one.
async fn group_pic(db: &SqlitePool, id: i64, group: i64, from: i64, format: i64, at: i64) {
    sqlx::query(
        "INSERT INTO group_pics (id, group_id, sender_id, bytes, mime, caption, created_at, expires_at, format)
         VALUES (?, ?, ?, 4000, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(group)
    .bind(from)
    .bind(if format == 0 { "image/jpeg" } else { "application/octet-stream" })
    .bind((format == 0).then_some("sunset"))
    .bind(at)
    .bind(at + 30 * DAY)
    .bind(format)
    .execute(db)
    .await
    .unwrap();
}

/// The mix (see the constants above), around the time now.
pub async fn mix(db: &SqlitePool) {
    let t = now();
    let today = t.div_euclid(DAY);
    for id in PEOPLE {
        let name = [
            "ana", "Ben", "cal", "dee", "eve", "fay", "gus", "napsack", "hal", "ivy", "jo", "zed",
        ][id as usize - 1];
        sqlx::query(
            "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at, last_seen_at)
             VALUES (?1, ?2, 'h', 'public key ' || ?1, 'w', ?3, ?4)",
        )
        .bind(id)
        .bind(name)
        .bind(t - 400 * DAY + id)
        .bind(t - 100 * id)
        .execute(db)
        .await
        .unwrap();
    }
    // An admin's reset code gave Ana a new key 40 days ago: what came before can't be unread.
    run(
        db,
        "UPDATE users SET key_reset_at = ? WHERE id = 1",
        &[t - 40 * DAY],
    )
    .await;
    run(
        db,
        "UPDATE users SET share_activity = 0 WHERE id = ?",
        &[JO],
    )
    .await;
    run(
        db,
        "INSERT INTO system_accounts (user_id, kind, created_at) VALUES (?, 'team', 0)",
        &[TEAM],
    )
    .await;
    run(db, "INSERT INTO deactivations (user_id, reason, deactivated_by, deactivated_at) VALUES (?, 'spam', 1, ?)", &[DEE, t - DAY]).await;
    run(
        db,
        "UPDATE users SET username = 'deleted:12' WHERE id = ?",
        &[ZED],
    )
    .await;
    run(
        db,
        "INSERT INTO deleted_accounts (user_id, deleted_at) VALUES (?, ?)",
        &[ZED, t - DAY],
    )
    .await;

    for (a, b) in [
        (ANA, BEN),
        (ANA, CAL),
        (ANA, DEE),
        (ANA, EVE),
        (ANA, IVY),
        (ANA, JO),
        (BEN, CAL),
        (BEN, FAY),
        (BEN, GUS),
        (BEN, HAL),
        (CAL, HAL),
        (GUS, HAL),
    ] {
        run(
            db,
            "INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (?, ?, ?)",
            &[a, b, t - 300 * DAY + a * 10 + b],
        )
        .await;
    }
    run(db, "INSERT INTO friendships (user_lo, user_hi, created_at, ended_at, ended_by) VALUES (1, 6, ?, ?, 1)", &[t - 300 * DAY, t - 100 * DAY]).await;

    // Names, pictures, birthdays, renames: the newest row wins.
    for (user, by, name) in [
        (BEN, BEN, Some("Benny B")),
        (BEN, ANA, Some("Big B")),
        (CAL, CAL, Some("Cal")),
        (CAL, CAL, None),
        (ANA, ANA, Some("Ana")),
    ] {
        sqlx::query(
            "INSERT INTO user_names (user_id, set_by, name, created_at) VALUES (?, ?, ?, 0)",
        )
        .bind(user)
        .bind(by)
        .bind(name)
        .execute(db)
        .await
        .unwrap();
    }
    for (user, image) in [
        (BEN, Some(&b"one"[..])),
        (BEN, Some(b"two")),
        (CAL, Some(b"cal")),
        (CAL, None),
    ] {
        sqlx::query("INSERT INTO user_avatars (user_id, image, mime, created_at) VALUES (?, ?, 'image/jpeg', 0)")
            .bind(user).bind(image).execute(db).await.unwrap();
    }
    run(
        db,
        "INSERT INTO user_birthdays (user_id, month, day, created_at) VALUES (?, 3, 14, 0)",
        &[BEN],
    )
    .await;
    run(db, "INSERT INTO user_birthdays (user_id, month, day, year, created_at) VALUES (?, 12, 1, 1990, 0)", &[IVY]).await;
    for (user, name, until) in [
        (BEN, "benjamin", t - 2 * DAY),
        (CAL, "calvin", t - 300 * DAY),
        (CAL, "cally", t - 60 * DAY),
        (ANA, "anna", t - 10 * DAY),
    ] {
        sqlx::query("INSERT INTO past_usernames (user_id, username, until) VALUES (?, ?, ?)")
            .bind(user)
            .bind(name)
            .bind(until)
            .execute(db)
            .await
            .unwrap();
    }

    // Ana and Ben: a long chat, some of it unread each way, with an edit and reactions.
    let mut ana_ben = vec![];
    for i in 0..30 {
        let (from, to) = if i % 2 == 0 { (ANA, BEN) } else { (BEN, ANA) };
        ana_ben.push(text(db, from, to, t - (35 - i) * DAY, i < 26).await);
    }
    text(db, BEN, ANA, t - 45 * DAY, false).await; // before Ana's new key: not unread
    pic(db, BEN, ANA, t - 50 * DAY, "expired").await;
    // A pic streak through today; Ben's pic today is still unopened.
    for day in [today - 2, today - 1, today] {
        pic(db, ANA, BEN, day * DAY + 9 * 3600, "opened").await;
        pic(
            db,
            BEN,
            ANA,
            day * DAY + 10 * 3600,
            if day == today { "pending" } else { "opened" },
        )
        .await;
    }
    let edited = ana_ben[28];
    for (n, ct) in ["first edit", "second edit"].iter().enumerate() {
        sqlx::query("INSERT INTO message_edits (message_id, ciphertext, format, created_at) VALUES (?, ?, 2, ?)")
            .bind(edited).bind(ct).bind(t - 6 * DAY + n as i64).execute(db).await.unwrap();
    }
    for (message, from, ct) in [
        (ana_ben[29], BEN, Some("r1")),
        (ana_ben[29], ANA, Some("r2")),
        (ana_ben[29], ANA, Some("r3")),
        (ana_ben[27], ANA, Some("r4")),
        (ana_ben[27], ANA, None),
    ] {
        sqlx::query("INSERT INTO reactions (message_id, sender_id, ciphertext, format, created_at) VALUES (?, ?, ?, 2, 0)")
            .bind(message).bind(from).bind(ct).execute(db).await.unwrap();
    }

    // Ana and Cal: a 70-day streak up to yesterday, longer than the chat
    // list reads; Cal hasn't opened Ana's newest pic.
    pics_both_ways(db, ANA, CAL, today - 70..today).await;
    text(db, CAL, ANA, t - 3 * DAY, true).await;
    pic(db, ANA, CAL, t - 3600, "pending").await;
    // Ben and Cal: exactly as long as the chat list reads. Ben and Hal: a day less.
    pics_both_ways(db, BEN, CAL, today - 62..today).await;
    pics_both_ways(db, BEN, HAL, today - 61..today).await;
    pics_both_ways(db, CAL, HAL, today - 1..=today).await;
    // Fay: a five-day streak long ago, from before the friendship ended.
    pics_both_ways(db, ANA, FAY, today - 200..today - 195).await;

    text(db, DEE, ANA, t - 9 * DAY, true).await;
    text(db, ANA, DEE, t - 8 * DAY, false).await;
    let ivy_last = {
        text(db, ANA, IVY, t - 7 * DAY, true).await;
        text(db, IVY, ANA, t - 6 * DAY, false).await
    };
    let jo_old = text(db, JO, ANA, t - 20 * DAY, false).await;
    text(db, JO, ANA, t - 5 * DAY, false).await;
    for day in [today - 1, today] {
        pic(db, ANA, JO, day * DAY + 8 * 3600, "opened").await; // one way only
    }
    text(db, TEAM, ANA, t - 4 * DAY, false).await;
    for i in 0..5 {
        text(db, BEN, GUS, t - (10 - i) * DAY, true).await;
    }

    // Ana's marks: Ben a favorite (Cal no longer); Ivy hidden with nothing
    // newer since, Jo hidden but written to since; Ivy muted for a day, Cal's
    // mute over, Ben muted and unmuted.
    for (friend, kind, value, upto) in [
        (BEN, "favorite", 1, None),
        (CAL, "favorite", 1, None),
        (CAL, "favorite", 0, None),
        (IVY, "hidden", 1, Some(ivy_last)),
        (JO, "hidden", 1, Some(jo_old)),
    ] {
        sqlx::query("INSERT INTO chat_marks (user_id, friend_id, kind, value, upto_id, created_at) VALUES (1, ?, ?, ?, ?, 0)")
            .bind(friend).bind(kind).bind(value).bind(upto).execute(db).await.unwrap();
    }
    for (friend, value, until) in [
        (IVY, 1, Some(t + DAY)),
        (CAL, 1, Some(t - DAY)),
        (BEN, 1, None),
        (BEN, 0, None),
    ] {
        sqlx::query("INSERT INTO chat_mutes (user_id, friend_id, value, until_at, created_at) VALUES (1, ?, ?, ?, 0)")
            .bind(friend).bind(value).bind(until).execute(db).await.unwrap();
    }

    // Groups.
    for (id, name, owner) in [
        (TRIP, "trip", ANA),
        (LATE, "late", BEN),
        (GONE, "gone", BEN),
        (QUIET, "quiet", BEN),
        (BLANK_A, "a", BEN),
        (BLANK_B, "b", BEN),
    ] {
        sqlx::query("INSERT INTO groups (id, name, created_by, created_at) VALUES (?, ?, ?, ?)")
            .bind(id)
            .bind(name)
            .bind(owner)
            .bind(t - 30 * DAY)
            .execute(db)
            .await
            .unwrap();
    }
    // (group, user, role, visible_after_id, last_read_id, left)
    for (group, user, role, after, read, left) in [
        (TRIP, ANA, "owner", 0, 104, false),
        (TRIP, BEN, "member", 0, 111, false),
        (TRIP, CAL, "member", 0, 0, false),
        (TRIP, HAL, "member", 0, 108, false),
        (TRIP, ZED, "member", 0, 0, true),
        (LATE, BEN, "owner", 0, 153, false),
        (LATE, ANA, "member", 151, 151, false),
        (LATE, CAL, "member", 0, 0, false),
        (GONE, BEN, "owner", 0, 0, false),
        (GONE, ANA, "member", 0, 0, true),
        (QUIET, BEN, "owner", 0, 0, false),
        (QUIET, ANA, "member", 0, 0, false),
        (BLANK_A, BEN, "owner", 0, 0, false),
        (BLANK_A, ANA, "member", 999, 0, false),
        (BLANK_B, BEN, "owner", 0, 0, false),
        (BLANK_B, ANA, "member", 999, 0, false),
    ] {
        sqlx::query(
            "INSERT INTO group_members (group_id, user_id, role, joined_at, visible_after_id, last_read_id, left_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(group).bind(user).bind(role).bind(t - 30 * DAY).bind(after).bind(read)
        .bind(left.then_some(t - DAY))
        .execute(db).await.unwrap();
    }
    let g = |n: i64| t - 20 * DAY + n * 3600;
    let trip = [ANA, BEN, CAL, HAL];
    post(
        db,
        100,
        TRIP,
        ANA,
        "event",
        r#"{"type":"created","name":"trip"}"#,
        0,
        g(0),
        None,
    )
    .await;
    post(db, 101, TRIP, BEN, "text", "hi", 0, g(1), None).await;
    post(
        db,
        102,
        TRIP,
        ZED,
        "text",
        "from someone since deleted",
        0,
        g(2),
        None,
    )
    .await;
    post(db, 103, TRIP, CAL, "text", "a reply", 0, g(3), None).await;
    run(
        db,
        "UPDATE group_messages SET reply_to = 101 WHERE id = 103",
        &[],
    )
    .await;
    post(
        db,
        104,
        TRIP,
        ANA,
        "event",
        r#"{"type":"encrypted"}"#,
        0,
        g(4),
        None,
    )
    .await;
    post(db, 105, TRIP, ANA, "text", "sealed 105", 3, g(5), None).await;
    seal(db, 105, &trip, &trip).await;
    post(db, 106, TRIP, BEN, "text", "sealed 106", 3, g(6), None).await;
    seal(db, 106, &trip, &[ANA, BEN, CAL]).await; // no key for Hal
    post(db, 107, TRIP, ANA, "text", "sealed 107", 3, g(7), None).await;
    seal(db, 107, &trip, &trip).await;
    for (edit, content) in [(500, "edit 500"), (501, "edit 501")] {
        sqlx::query("INSERT INTO group_message_edits (id, message_id, content, client_id, created_at) VALUES (?1, 107, ?2, 'e' || ?1, ?3)")
            .bind(edit).bind(content).bind(g(8)).execute(db).await.unwrap();
    }
    for user in [ANA, BEN, CAL] {
        run(db, "INSERT INTO group_edit_keys (edit_id, user_id, wrapped) VALUES (501, ?, 'edit wrap ' || ?1)", &[user]).await;
    }
    group_pic(db, 300, TRIP, BEN, 0, g(9)).await;
    post(db, 108, TRIP, BEN, "text", "", 0, g(9), Some(300)).await;
    // Cal and Ana opened it in the same second; Hal later.
    for (user, at) in [(CAL, g(10)), (ANA, g(10)), (HAL, g(11))] {
        run(
            db,
            "INSERT INTO group_pic_views (pic_id, user_id, viewed_at) VALUES (300, ?, ?)",
            &[user, at],
        )
        .await;
    }
    group_pic(db, 301, TRIP, CAL, 3, g(12)).await;
    post(db, 109, TRIP, CAL, "text", "", 3, g(12), Some(301)).await;
    seal(db, 109, &trip, &trip).await;
    group_pic(db, 302, TRIP, HAL, 7, g(13)).await;
    run(
        db,
        "UPDATE group_pics SET discarded_at = ?, discard_reason = 'expired' WHERE id = 302",
        &[g(14)],
    )
    .await;
    post(db, 110, TRIP, HAL, "text", "", 7, g(13), Some(302)).await;
    seal(db, 110, &trip, &trip).await;
    post(
        db,
        111,
        TRIP,
        ANA,
        "text",
        "plain again, from an old app",
        0,
        g(15),
        None,
    )
    .await;
    for (message, user, emoji) in [
        (101, ANA, Some("😂")),
        (101, ANA, Some("❤️")),
        (101, BEN, Some("👍")),
        (105, CAL, Some("😮")),
        (105, CAL, None),
        (105, HAL, Some("😢")),
        (108, ANA, Some("👍")),
    ] {
        sqlx::query("INSERT INTO group_reactions (message_id, user_id, emoji, created_at) VALUES (?, ?, ?, 0)")
            .bind(message).bind(user).bind(emoji).execute(db).await.unwrap();
    }
    for by in [ANA, BEN] {
        run(db, "INSERT INTO group_avatars (group_id, set_by, image, mime, created_at) VALUES (?, ?, x'00', 'image/jpeg', 0)", &[TRIP, by]).await;
    }

    post(
        db,
        150,
        LATE,
        BEN,
        "event",
        r#"{"type":"created","name":"late"}"#,
        0,
        g(20),
        None,
    )
    .await;
    post(db, 151, LATE, BEN, "text", "before Ana", 0, g(21), None).await;
    post(
        db,
        152,
        LATE,
        BEN,
        "event",
        r#"{"type":"added","target":1,"target_name":"ana"}"#,
        0,
        g(22),
        None,
    )
    .await;
    group_pic(db, 303, LATE, CAL, 3, g(23)).await;
    post(db, 153, LATE, CAL, "text", "", 3, g(23), Some(303)).await;
    seal(db, 153, &[ANA, BEN, CAL], &[ANA, BEN, CAL]).await;
    run(
        db,
        "INSERT INTO group_pic_views (pic_id, user_id, viewed_at) VALUES (303, ?, ?)",
        &[BEN, g(24)],
    )
    .await;

    post(
        db,
        160,
        GONE,
        BEN,
        "event",
        r#"{"type":"created","name":"gone"}"#,
        0,
        g(30),
        None,
    )
    .await;
    post(db, 161, GONE, BEN, "text", "after Ana left", 0, g(31), None).await;
    post(
        db,
        170,
        QUIET,
        BEN,
        "event",
        r#"{"type":"created","name":"quiet"}"#,
        0,
        g(40),
        None,
    )
    .await;
    post(db, 171, QUIET, BEN, "text", "shh", 0, g(41), None).await;
    run(db, "INSERT INTO chat_marks (user_id, group_id, kind, value, created_at) VALUES (1, ?, 'favorite', 1, 0)", &[QUIET]).await;
    run(
        db,
        "INSERT INTO chat_mutes (user_id, group_id, value, created_at) VALUES (1, ?, 1, 0)",
        &[QUIET],
    )
    .await;
    post(
        db,
        180,
        BLANK_A,
        BEN,
        "event",
        r#"{"type":"created","name":"a"}"#,
        0,
        g(50),
        None,
    )
    .await;
    post(
        db,
        181,
        BLANK_B,
        BEN,
        "event",
        r#"{"type":"created","name":"b"}"#,
        0,
        g(51),
        None,
    )
    .await;
}

/// A large set to time the lists on: `users` people, each friends with
/// `friends` of them (an even number), `messages` direct messages between
/// friends over two years (three in ten pics; the last two days unread or
/// unopened), `close` of them in one long chat between users 1 and 2, with
/// edits and reactions; `groups` groups of 8 to 32, with `group_messages`
/// messages among them (mostly sealed, each with its members' keys), pics,
/// and reactions. User 1 is in about half the groups and has 90-day pic
/// streaks with three friends.
#[allow(clippy::too_many_arguments)]
pub async fn large(
    db: &SqlitePool,
    users: i64,
    friends: i64,
    messages: i64,
    close: i64,
    groups: i64,
    group_messages: i64,
) {
    let t = now();
    let half = friends / 2;
    let span = 730 * DAY;
    let spread = messages - close;
    let step = span / spread;
    let start = t - span;
    let recent = t - 2 * DAY;
    let mut tx = crate::db::write_tx(db).await.unwrap();
    let with = |sql: &'static str, binds: Vec<i64>| {
        let mut q = sqlx::query(sql);
        for b in binds {
            q = q.bind(b);
        }
        q
    };
    with(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?1)
         INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at, last_seen_at)
         SELECT i, 'user' || i, 'h', 'public key ' || i, 'w', ?2, ?3 - i FROM n",
        vec![users, start - DAY, t],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    // Each person and the `half` after them, around a circle: `friends` each.
    with(
        "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < ?1 * ?2 - 1),
           p AS (SELECT i / ?2 + 1 AS a, (i / ?2 + i % ?2 + 1) % ?1 + 1 AS b FROM n)
         INSERT OR IGNORE INTO friendships (user_lo, user_hi, created_at)
         SELECT MIN(a, b), MAX(a, b), ?3 FROM p",
        vec![users, half, start - DAY],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    // Message i goes between one of those pairs, spread evenly over them.
    with(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?1),
           p AS (SELECT i, (i * 7919) % (?2 * ?3) AS k, ?4 + i * ?5 AS at, (i * 13) % 10 < 3 AS pic FROM n),
           q AS (SELECT i, k / ?3 + 1 AS a, (k / ?3 + k % ?3 + 1) % ?2 + 1 AS b, at, pic FROM p)
         INSERT INTO messages (sender_id, recipient_id, kind, ciphertext, format, snap_state, created_at, read_at, snap_bytes)
         SELECT CASE WHEN i % 2 = 0 THEN a ELSE b END, CASE WHEN i % 2 = 0 THEN b ELSE a END,
                CASE WHEN pic THEN 'snap' ELSE 'text' END,
                CASE WHEN pic THEN NULL ELSE hex(zeroblob(150)) END, 2,
                CASE WHEN NOT pic THEN NULL WHEN at > ?6 THEN 'pending' WHEN i % 5 = 0 THEN 'expired' ELSE 'opened' END,
                at, CASE WHEN at > ?6 THEN NULL ELSE at + 60 END, CASE WHEN pic THEN 90000 END
         FROM q",
        vec![spread, users, half, start, step, recent],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    // The long chat, between users 1 and 2, interleaved with the rest.
    with(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?1),
           p AS (SELECT i, ?2 + i * ?3 AS at, (i * 13) % 10 < 3 AS pic FROM n)
         INSERT INTO messages (sender_id, recipient_id, kind, ciphertext, format, snap_state, created_at, read_at, snap_bytes)
         SELECT 1 + i % 2, 2 - i % 2, CASE WHEN pic THEN 'snap' ELSE 'text' END,
                CASE WHEN pic THEN NULL ELSE hex(zeroblob(150)) END, 2,
                CASE WHEN NOT pic THEN NULL WHEN at > ?4 THEN 'pending' ELSE 'opened' END,
                at, CASE WHEN at > ?4 THEN NULL ELSE at + 60 END, CASE WHEN pic THEN 90000 END
         FROM p",
        vec![close, start, span / close.max(1), recent],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    // 90-day streaks between user 1 and three friends, up to today.
    with(
        "WITH RECURSIVE d(day) AS (SELECT ?1 - 89 UNION ALL SELECT day + 1 FROM d WHERE day < ?1),
           f(id) AS (VALUES (2), (3), (4))
         INSERT INTO messages (sender_id, recipient_id, kind, format, snap_state, created_at, read_at, snap_bytes)
         SELECT CASE WHEN w = 0 THEN 1 ELSE f.id END, CASE WHEN w = 0 THEN f.id ELSE 1 END, 'snap', 2, 'opened',
                d.day * 86400 + 3600 + w * 600, d.day * 86400 + 3700 + w * 600, 90000
         FROM d, f, (SELECT 0 AS w UNION ALL SELECT 1)",
        vec![t.div_euclid(DAY)],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    for sql in [
        "INSERT INTO message_edits (message_id, ciphertext, format, created_at)
         SELECT id, 'edited', 2, created_at + 5 FROM messages WHERE kind = 'text' AND id % 100 = 7",
        "INSERT INTO reactions (message_id, sender_id, ciphertext, format, created_at)
         SELECT id, recipient_id, 'reaction', 2, created_at + 9 FROM messages WHERE id % 50 = 3",
        "INSERT INTO past_usernames (user_id, username, until)
         SELECT id, 'was' || id, strftime('%s', 'now') - id * 86400 FROM users WHERE id <= 10",
        "INSERT INTO user_names (user_id, set_by, name, created_at) SELECT id, id, 'Name ' || id, 0 FROM users WHERE id % 2 = 0",
        "INSERT INTO user_avatars (user_id, image, mime, created_at) SELECT id, x'00', 'image/jpeg', 0 FROM users WHERE id % 3 = 0",
    ] {
        sqlx::query(sql).execute(&mut *tx).await.unwrap();
    }
    // Groups: group g has 8 to 32 members around the circle from g * 7;
    // user 1 is added to every other one.
    with(
        "WITH RECURSIVE g(id) AS (SELECT 1 UNION ALL SELECT id + 1 FROM g WHERE id < ?1)
         INSERT INTO groups (id, name, created_by, created_at) SELECT id, 'group ' || id, 1, ?2 FROM g",
        vec![groups, start],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    with(
        "WITH RECURSIVE g(id) AS (SELECT 1 UNION ALL SELECT id + 1 FROM g WHERE id < ?1),
           j(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM j WHERE n < 31)
         INSERT OR IGNORE INTO group_members (group_id, user_id, role, joined_at)
         SELECT g.id, (g.id * 7 + j.n) % ?2 + 1, 'member', ?3 FROM g, j WHERE j.n < 8 + g.id % 25",
        vec![groups, users, start],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    with(
        "INSERT OR IGNORE INTO group_members (group_id, user_id, role, joined_at)
         SELECT id, 1, 'member', ?1 FROM groups WHERE id % 2 = 0",
        vec![start],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    // Group messages: from a member (the first at or after a number that
    // goes around), seven in ten sealed, one in twenty a pic.
    with(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?1),
           g AS (SELECT i, i % ?2 + 1 AS gid, (i * 31) % ?5 + 1 AS pivot FROM n)
         INSERT INTO group_messages (id, group_id, sender_id, kind, body, format, created_at)
         SELECT i, gid,
                COALESCE((SELECT MIN(m.user_id) FROM group_members m WHERE m.group_id = gid AND m.user_id >= pivot),
                         (SELECT MIN(m.user_id) FROM group_members m WHERE m.group_id = gid)),
                'text', CASE WHEN (i * 17) % 10 < 7 THEN hex(zeroblob(120)) ELSE 'plain text' END,
                CASE WHEN (i * 17) % 10 < 7 THEN 3 ELSE 0 END, ?3 + i * ?4
         FROM g",
        vec![group_messages, groups, start, span / group_messages, users],
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    for sql in [
        "INSERT INTO group_pics (id, group_id, sender_id, bytes, mime, created_at, expires_at, format, discarded_at, discard_reason)
         SELECT id, group_id, sender_id, 90000, CASE WHEN format = 0 THEN 'image/jpeg' ELSE 'application/octet-stream' END,
                created_at, created_at + 30 * 86400, format, created_at + 86400, 'opened'
         FROM group_messages WHERE id % 20 = 0",
        "UPDATE group_messages SET pic_id = id, body = '' WHERE id % 20 = 0",
        "INSERT INTO group_pic_views (pic_id, user_id, viewed_at)
         SELECT p.id, m.user_id, p.created_at + 600 FROM group_pics p JOIN group_members m ON m.group_id = p.group_id
         WHERE m.user_id != p.sender_id",
        "UPDATE group_messages SET client_id = 'cid' || id,
                recipients = (SELECT json_group_array(user_id) FROM group_members m WHERE m.group_id = group_messages.group_id)
         WHERE format = 3",
        "INSERT INTO group_message_keys (message_id, user_id, wrapped)
         SELECT gm.id, m.user_id, 'wrapped key' FROM group_messages gm JOIN group_members m ON m.group_id = gm.group_id
         WHERE gm.format = 3",
        "INSERT INTO group_message_edits (id, message_id, content, client_id, created_at)
         SELECT id, id, 'edited', 'e' || id, created_at + 5 FROM group_messages WHERE format = 3 AND id % 100 = 1",
        "INSERT INTO group_edit_keys (edit_id, user_id, wrapped)
         SELECT e.id, m.user_id, 'wrapped edit key' FROM group_message_edits e
         JOIN group_messages gm ON gm.id = e.message_id JOIN group_members m ON m.group_id = gm.group_id",
        "INSERT INTO group_reactions (message_id, user_id, emoji, created_at)
         SELECT id, sender_id, '👍', created_at + 9 FROM group_messages WHERE id % 33 = 0",
        "UPDATE group_members SET last_read_id = (SELECT MAX(id) - 3 FROM group_messages gm WHERE gm.group_id = group_members.group_id)",
    ] {
        sqlx::query(sql).execute(&mut *tx).await.unwrap();
    }
    tx.commit().await.unwrap();
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;

    /// The indexes migration 0028 adds, by name.
    const NEW_INDEXES: [&str; 4] = [
        "messages_recipient",
        "messages_waiting",
        "messages_pics",
        "messages_unopened_pics",
    ];

    /// The fastest and the median of `runs` runs of `f`, and what it last
    /// returned. The fastest says most about the work itself on a busy machine.
    async fn time<T, F: std::future::Future<Output = T>>(
        runs: usize,
        mut f: impl FnMut() -> F,
    ) -> (Took, T) {
        let mut took = Vec::with_capacity(runs);
        let mut out = f().await; // once to warm the cache
        for _ in 0..runs {
            let start = Instant::now();
            out = f().await;
            took.push(start.elapsed());
        }
        took.sort();
        ((took[0], took[runs / 2]), out)
    }

    /// (fastest, median)
    type Took = (Duration, Duration);

    fn ms(d: Duration) -> f64 {
        d.as_secs_f64() * 1000.0
    }

    fn json<T: serde::Serialize>(v: &T) -> String {
        serde_json::to_string(v).unwrap()
    }

    /// Each list, timed before migration 0028 (its indexes dropped, the old
    /// queries) and after, on about 100 people with 60 friends each and
    /// 200,000 messages (20,000 in user 1's chat with user 2); both must
    /// answer the same. Slow, so not part of the suite:
    /// `cargo test --release timing -- --ignored --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn timing() {
        let db = crate::db::tests::temp_db().await;
        let seeding = Instant::now();
        large(&db, 100, 60, 200_000, 20_000, 40, 20_000).await;
        let counts: (i64, i64, i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM messages), (SELECT COUNT(*) FROM friendships),
                    (SELECT COUNT(*) FROM group_messages), (SELECT COUNT(*) FROM group_message_keys)",
        )
        .fetch_one(&db)
        .await
        .unwrap();
        println!(
            "seeded {} messages, {} friendships, {} group messages, {} group keys in {:?}",
            counts.0,
            counts.1,
            counts.2,
            counts.3,
            seeding.elapsed()
        );
        let me = 1;
        let friend: i64 = 2;
        let big_group: i64 = sqlx::query_scalar(
            "SELECT group_id FROM group_members WHERE user_id = 1 GROUP BY group_id
             ORDER BY (SELECT COUNT(*) FROM group_members x WHERE x.group_id = group_members.group_id) DESC LIMIT 1",
        )
        .fetch_one(&db)
        .await
        .unwrap();
        let admins = crate::roles::Admins::new(vec![], None);
        let runs = 15;
        let mut rows: Vec<(&str, Took, Took)> = vec![];
        // The chat with `friend` read, so timing "mark it read" changes nothing.
        sqlx::query(crate::chats::tests::OLD_MARK_READ)
            .bind(now())
            .bind(friend)
            .bind(me)
            .execute(&db)
            .await
            .unwrap();

        for index in NEW_INDEXES {
            let drop = ["DROP INDEX ", index].concat(); // a throwaway database
            sqlx::query(&drop).execute(&db).await.unwrap();
        }
        let (b_chats, old_chats) = time(runs, || {
            crate::friends::tests::old_chats(&db, me, 0, |_| false)
        })
        .await;
        let (b_groups, old_groups) =
            time(runs, || crate::groups::tests::old::groups_for(&db, me)).await;
        let (b_own, old_own) = time(runs, || {
            crate::profiles::tests::old_profile_for(&db, &admins, me, me, 0)
        })
        .await;
        let (b_theirs, old_theirs) = time(runs, || {
            crate::profiles::tests::old_profile_for(&db, &admins, me, friend, 0)
        })
        .await;
        let (b_map, old_map) = time(runs, || crate::graph::tests::old_map(&db, me, true)).await;
        let (b_page, old_page) = time(runs, || {
            crate::chats::tests::old_page_of(&db, me, friend, i64::MAX, 50)
        })
        .await;
        let (b_group_page, old_group_page) = time(runs, || {
            crate::groups::tests::old::page_of(&db, me, big_group, 0, i64::MAX, 50)
        })
        .await;
        let read = |sql: &'static str| {
            let db = db.clone();
            async move {
                // A chat already read: nothing changes, only the search costs.
                sqlx::query(sql)
                    .bind(0)
                    .bind(friend)
                    .bind(me)
                    .execute(&db)
                    .await
                    .unwrap()
                    .rows_affected()
            }
        };
        let (b_read, _) = time(runs, || read(crate::chats::tests::OLD_MARK_READ)).await;
        let (b_badge, old_badge) = time(runs, || crate::apns::waiting_chats(&db, me)).await;
        let (b_usage, old_usage) = time(runs, || crate::snaps::usage(&db)).await;
        let (b_stats, old_stats) =
            time(runs, || crate::profiles::tests::old_my_stats(&db, me)).await;
        let (b_streaks, old_streaks) =
            time(runs, || crate::streaks::tests::old_for_friends(&db, me, 0)).await;

        sqlx::raw_sql(include_str!("../migrations/0028_reading_fast.sql"))
            .execute(&db)
            .await
            .unwrap();
        let (a_chats, new_chats) =
            time(runs, || crate::friends::chats_for(&db, me, 0, |_| false)).await;
        let (a_groups, new_groups) = time(runs, || crate::groups::groups_for(&db, me)).await;
        let (a_own, new_own) = time(runs, || {
            crate::profiles::profile_for(&db, &admins, me, me, 0)
        })
        .await;
        let (a_theirs, new_theirs) = time(runs, || {
            crate::profiles::profile_for(&db, &admins, me, friend, 0)
        })
        .await;
        let (a_map, new_map) = time(runs, || crate::graph::map_for(&db, me, true, |_| {})).await;
        let (a_page, new_page) = time(runs, || {
            crate::chats::page_of(&db, me, friend, i64::MAX, 50)
        })
        .await;
        let (a_group_page, new_group_page) = time(runs, || {
            crate::groups::page_of(&db, me, big_group, 0, i64::MAX, 50)
        })
        .await;
        let (a_read, _) = time(runs, || read(crate::chats::tests::NEW_MARK_READ)).await;
        let (a_badge, new_badge) = time(runs, || crate::apns::waiting_chats(&db, me)).await;
        let (a_usage, new_usage) = time(runs, || crate::snaps::usage(&db)).await;
        let (a_stats, new_stats) = time(runs, || crate::profiles::my_stats(&db, me)).await;
        let (a_streaks, new_streaks) = time(runs, || crate::streaks::for_friends(&db, me, 0)).await;

        assert_eq!(new_stats.unwrap(), old_stats.unwrap());
        assert_eq!(new_streaks.unwrap(), old_streaks.unwrap());
        assert_eq!(json(&new_chats.unwrap()), json(&old_chats));
        assert_eq!(json(&new_groups.unwrap()), json(&old_groups));
        let profile = |p: crate::error::AppResult<crate::profiles::Profile>| json(&p.unwrap());
        assert_eq!(profile(new_own), profile(old_own));
        assert_eq!(profile(new_theirs), profile(old_theirs));
        assert_eq!(json(&new_map.unwrap()), json(&old_map));
        assert_eq!(json(&new_page.unwrap()), json(&old_page));
        assert_eq!(json(&new_group_page.unwrap()), json(&old_group_page));
        assert_eq!(new_badge.unwrap(), old_badge.unwrap());
        assert_eq!(new_usage.unwrap(), old_usage.unwrap());

        rows.extend([
            ("chat list (GET /api/friends)", b_chats, a_chats),
            ("groups list (GET /api/groups)", b_groups, a_groups),
            ("own profile", b_own, a_own),
            ("a friend's profile", b_theirs, a_theirs),
            ("friend map, with chats", b_map, a_map),
            ("a chat's newest 50", b_page, a_page),
            ("a group's newest 50", b_group_page, a_group_page),
            ("marking a read chat read", b_read, a_read),
            ("iPhone badge count", b_badge, a_badge),
            ("pic disk check", b_usage, a_usage),
            ("  own profile's counts", b_stats, a_stats),
            ("  own profile's streaks", b_streaks, a_streaks),
        ]);
        println!(
            "{runs} runs each, user 1 (60 friends, a 20,000-message chat with user 2; group {big_group} has the most members)"
        );
        println!(
            "{:<32} {:>21} {:>21} {:>8}",
            "ms: fastest (median)", "before", "after", "faster"
        );
        for (what, (b_min, b_mid), (a_min, a_mid)) in rows {
            println!(
                "{what:<32} {:>10.2} ({:>8.2}) {:>10.2} ({:>8.2}) {:>7.1}x",
                ms(b_min),
                ms(b_mid),
                ms(a_min),
                ms(a_mid),
                ms(b_min) / ms(a_min).max(1e-6)
            );
        }
    }
}
