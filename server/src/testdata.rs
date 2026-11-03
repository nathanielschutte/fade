//! Test data for the lists every app reads again and again (the chat list,
//! a chat, groups, profiles, the friend map): a small mix that each one is
//! checked against its old self with, so the faster queries return exactly
//! what the old ones did.

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
