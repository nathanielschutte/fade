//! Team Napsack's scheduled messages (docs/implementation/team-napsack.md):
//! the occasions in `server/occasions.toml`, sent by `team::send`.
//!
//! Two kinds: driven by data (someone's birthday, from their profile) and by
//! the calendar (a date every year, or one date). Each has its recipients:
//! everyone, the birthday person, their friends, or named people, optionally
//! narrowed to a few usernames for testing.
//!
//! Every few minutes the loop checks what's due today (UTC) from its hour on,
//! and sends each message once: a row in `occasion_sends` (unique per
//! occasion, occurrence, and person) is claimed before it goes. A day missed
//! entirely (the server down all day) isn't made up later.

use std::collections::BTreeSet;

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::AuthUser,
    db::now,
    error::{AppError, AppResult},
    roles::Role,
    SharedState,
};

/// The schedule, compiled in: edit the file and release to change it.
const SCHEDULE: &str = include_str!("../occasions.toml");
const CHECK_EVERY: std::time::Duration = std::time::Duration::from_secs(5 * 60);
const MAX_TEXT_CHARS: usize = 1000;

#[derive(Deserialize)]
struct File {
    #[serde(default)]
    occasion: Vec<Raw>,
}

#[derive(Deserialize, Clone)]
struct Raw {
    id: String,
    when: String,
    #[serde(default = "default_hour")]
    hour: u32,
    to: To,
    #[serde(default)]
    only: Option<Vec<String>>,
    text: String,
}

fn default_hour() -> u32 {
    15 // 10 in the morning in the US Central time zone
}

#[derive(Deserialize, Clone, Debug, PartialEq)]
#[serde(untagged)]
enum To {
    Kind(String),
    Users(Vec<String>),
}

#[derive(Clone, Debug, PartialEq)]
pub enum When {
    Birthday,
    Yearly { month: u32, day: u32 },
    Once { date: String },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Audience {
    Everyone,
    BirthdayPerson,
    BirthdayFriends,
    Users(Vec<String>),
}

#[derive(Clone, Debug)]
pub struct Occasion {
    pub id: String,
    pub when: When,
    pub hour: u32,
    pub to: Audience,
    pub only: Option<Vec<String>>,
    pub text: String,
}

/// Reads and checks the schedule: (good occasions, problems with the rest).
pub fn schedule() -> (Vec<Occasion>, Vec<String>) {
    parse(SCHEDULE)
}

fn parse(toml_text: &str) -> (Vec<Occasion>, Vec<String>) {
    let file: File = match toml::from_str(toml_text) {
        Ok(f) => f,
        Err(e) => return (Vec::new(), vec![format!("occasions.toml: {e}")]),
    };
    let mut good = Vec::new();
    let mut problems = Vec::new();
    let mut ids = BTreeSet::new();
    for raw in file.occasion {
        match check(&raw) {
            Ok(o) if ids.insert(o.id.clone()) => good.push(o),
            Ok(o) => problems.push(format!("{}: the same id twice", o.id)),
            Err(e) => problems.push(format!("{}: {e}", raw.id)),
        }
    }
    (good, problems)
}

fn check(raw: &Raw) -> Result<Occasion, String> {
    let id = raw.id.trim();
    if id.is_empty()
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err("ids are letters, digits, hyphens and underscores".into());
    }
    let when = match raw.when.trim().split_once(' ') {
        None if raw.when.trim() == "birthday" => When::Birthday,
        Some(("yearly", md)) => {
            let (m, d) = md
                .split_once('-')
                .ok_or("yearly takes MM-DD, like \"yearly 12-25\"")?;
            let (month, day) = (
                m.parse::<u32>().map_err(|_| "bad month")?,
                d.parse::<u32>().map_err(|_| "bad day")?,
            );
            if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
                return Err("yearly takes MM-DD, like \"yearly 12-25\"".into());
            }
            When::Yearly { month, day }
        }
        Some(("once", date)) => {
            let ok =
                date.len() == 10 && crate::aws::parse_iso(&format!("{date}T00:00:00Z")).is_some();
            if !ok {
                return Err("once takes YYYY-MM-DD, like \"once 2026-12-31\"".into());
            }
            When::Once {
                date: date.to_owned(),
            }
        }
        _ => return Err("when is \"birthday\", \"yearly MM-DD\", or \"once YYYY-MM-DD\"".into()),
    };
    let to = match &raw.to {
        To::Kind(k) => match k.as_str() {
            "everyone" => Audience::Everyone,
            "birthday person" => Audience::BirthdayPerson,
            "birthday friends" => Audience::BirthdayFriends,
            other => return Err(format!("to is \"everyone\", \"birthday person\", \"birthday friends\", or a list of usernames, not {other:?}")),
        },
        To::Users(list) if !list.is_empty() => Audience::Users(list.iter().map(|u| u.to_lowercase()).collect()),
        To::Users(_) => return Err("an empty list of recipients".into()),
    };
    let birthday_audience = matches!(to, Audience::BirthdayPerson | Audience::BirthdayFriends);
    if birthday_audience && when != When::Birthday {
        return Err("\"birthday person\" and \"birthday friends\" need when = \"birthday\"".into());
    }
    if raw.hour > 23 {
        return Err("hour is 0 to 23 (UTC)".into());
    }
    let text = raw.text.trim();
    if text.is_empty() || text.chars().count() > MAX_TEXT_CHARS {
        return Err(format!("text is 1 to {MAX_TEXT_CHARS} characters"));
    }
    crate::text::check_message(text).map_err(str::to_owned)?;
    let mut rest = text.to_owned();
    for known in ["{name}", "{birthday_name}"] {
        rest = rest.replace(known, "");
    }
    if rest.contains('{') || rest.contains('}') {
        return Err("text can use {name} and {birthday_name} only".into());
    }
    if text.contains("{birthday_name}") && when != When::Birthday {
        return Err("{birthday_name} needs when = \"birthday\"".into());
    }
    Ok(Occasion {
        id: id.to_owned(),
        when,
        hour: raw.hour,
        to,
        only: raw
            .only
            .as_ref()
            .map(|l| l.iter().map(|u| u.to_lowercase()).collect()),
        text: text.to_owned(),
    })
}

/// (UTC date "YYYY-MM-DD", month, day, hour) for a unix time.
fn today(t: i64) -> (String, u32, u32, u32) {
    let date = crate::aws::ymd(t);
    let month = date[5..7].parse().unwrap_or(0);
    let day = date[8..10].parse().unwrap_or(0);
    (date, month, day, (t.rem_euclid(86_400) / 3600) as u32)
}

/// One message to send: who to, which occurrence, and whose birthday (if any).
#[derive(Debug, PartialEq)]
pub struct Due {
    pub user: i64,
    pub occurrence: String,
    pub birthday_of: Option<i64>,
}

/// People who can get messages: on, and not a system account.
const ACTIVE: &str =
    "NOT EXISTS (SELECT 1 FROM deactivations d WHERE d.user_id = u.id AND d.reactivated_at IS NULL)
    AND NOT EXISTS (SELECT 1 FROM system_accounts s WHERE s.user_id = u.id)";

async fn active_people(db: &SqlitePool) -> sqlx::Result<Vec<(i64, String)>> {
    sqlx::query_as(&format!(
        "SELECT u.id, lower(u.username) FROM users u WHERE {ACTIVE}"
    ))
    .fetch_all(db)
    .await
}

/// Everyone whose (current) birthday is this month and day.
async fn birthdays_on(db: &SqlitePool, month: u32, day: u32) -> sqlx::Result<Vec<i64>> {
    sqlx::query_scalar(&format!(
        "SELECT u.id FROM users u
         JOIN user_birthdays b ON b.id = (SELECT MAX(id) FROM user_birthdays WHERE user_id = u.id)
         WHERE b.month = ? AND b.day = ? AND {ACTIVE}"
    ))
    .bind(month)
    .bind(day)
    .fetch_all(db)
    .await
}

/// Who gets `o` at time `t`, if it's due: nothing before its hour, or on another day.
pub async fn due(db: &SqlitePool, o: &Occasion, t: i64) -> sqlx::Result<Vec<Due>> {
    let (date, month, day, hour) = today(t);
    if hour < o.hour {
        return Ok(Vec::new());
    }
    let people = active_people(db).await?;
    let named = |list: &[String]| -> Vec<i64> {
        people
            .iter()
            .filter(|(_, u)| list.contains(u))
            .map(|(id, _)| *id)
            .collect()
    };
    let mut out = Vec::new();
    match &o.when {
        When::Birthday => {
            for b in birthdays_on(db, month, day).await? {
                let occurrence = format!("{date}:{b}");
                let to: Vec<i64> = match &o.to {
                    Audience::BirthdayPerson => vec![b],
                    Audience::BirthdayFriends => {
                        let friends = crate::roles::friend_ids(db, b).await?;
                        people
                            .iter()
                            .map(|(id, _)| *id)
                            .filter(|id| friends.contains(id))
                            .collect()
                    }
                    Audience::Everyone => people
                        .iter()
                        .map(|(id, _)| *id)
                        .filter(|id| *id != b)
                        .collect(),
                    Audience::Users(list) => named(list),
                };
                out.extend(to.into_iter().map(|user| Due {
                    user,
                    occurrence: occurrence.clone(),
                    birthday_of: Some(b),
                }));
            }
        }
        When::Yearly { month: m, day: d } if (*m, *d) == (month, day) => {
            out.extend(audience(&o.to, &people, named).into_iter().map(|user| Due {
                user,
                occurrence: date.clone(),
                birthday_of: None,
            }));
        }
        When::Once { date: d } if *d == date => {
            out.extend(audience(&o.to, &people, named).into_iter().map(|user| Due {
                user,
                occurrence: date.clone(),
                birthday_of: None,
            }));
        }
        _ => {}
    }
    if let Some(only) = &o.only {
        let allowed = named(only);
        out.retain(|d| allowed.contains(&d.user));
    }
    Ok(out)
}

fn audience(
    to: &Audience,
    people: &[(i64, String)],
    named: impl Fn(&[String]) -> Vec<i64>,
) -> Vec<i64> {
    match to {
        Audience::Users(list) => named(list),
        _ => people.iter().map(|(id, _)| *id).collect(),
    }
}

/// The text for one person, with {name} and {birthday_name} filled in as they'd see them.
async fn fill(db: &SqlitePool, o: &Occasion, d: &Due) -> sqlx::Result<String> {
    let mut text = o.text.replace(
        "{name}",
        &crate::people::name_for(db, d.user, d.user).await?,
    );
    if let Some(b) = d.birthday_of {
        text = text.replace(
            "{birthday_name}",
            &crate::people::name_for(db, d.user, b).await?,
        );
    }
    Ok(text)
}

/// Sends whatever is due now. Returns how many went.
async fn run_once(state: &SharedState, t: i64) -> anyhow::Result<usize> {
    let (occasions, problems) = schedule();
    for p in problems {
        tracing::error!(problem = %p, "occasions.toml has a problem; that occasion is skipped");
    }
    let mut sent = 0;
    for o in &occasions {
        for d in due(&state.db, o, t).await? {
            // Claim it first: the unique index makes this exactly once.
            let claimed = sqlx::query(
                "INSERT OR IGNORE INTO occasion_sends (occasion, occurrence, user_id, sent_at) VALUES (?, ?, ?, ?)",
            )
            .bind(&o.id)
            .bind(&d.occurrence)
            .bind(d.user)
            .bind(now())
            .execute(&state.db)
            .await?
            .rows_affected();
            if claimed == 0 {
                continue;
            }
            let text = fill(&state.db, o, &d).await?;
            match crate::team::send(state, d.user, &text).await {
                Ok(message_id) => {
                    sqlx::query(
                        "UPDATE occasion_sends SET message_id = ? WHERE occasion = ? AND occurrence = ? AND user_id = ?",
                    )
                    .bind(message_id)
                    .bind(&o.id)
                    .bind(&d.occurrence)
                    .bind(d.user)
                    .execute(&state.db)
                    .await?;
                    sent += 1;
                    tracing::info!(occasion = %o.id, user_id = d.user, message_id, "occasion sent");
                }
                Err(e) => {
                    tracing::error!(occasion = %o.id, user_id = d.user, error = %e, "sending an occasion failed")
                }
            }
        }
    }
    Ok(sent)
}

/// Starts the loop (and makes Team Napsack if it isn't there).
pub fn spawn(state: SharedState) {
    tokio::spawn(async move {
        if let Err(e) = crate::team::ensure(&state.db).await {
            tracing::error!(error = %e, "making the team napsack account failed; no occasions will be sent");
            return;
        }
        let (occasions, problems) = schedule();
        tracing::info!(
            occasions = occasions.len(),
            problems = problems.len(),
            "occasions loaded"
        );
        // A little after startup, then every few minutes.
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        let mut tick = tokio::time::interval(CHECK_EVERY);
        loop {
            tick.tick().await;
            if let Err(e) = run_once(&state, now()).await {
                tracing::error!(error = %e, "checking occasions failed");
            }
        }
    });
}

/// `GET /api/admin/occasions`: the schedule, any problems in it, and what's
/// been sent for each. Admins only. Read-only: the schedule is in code.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let (occasions, problems) = schedule();
    let t = now();
    let mut out = Vec::new();
    for o in &occasions {
        let (count, last): (i64, Option<i64>) = sqlx::query_as(
            "SELECT COUNT(message_id), MAX(sent_at) FROM occasion_sends WHERE occasion = ?",
        )
        .bind(&o.id)
        .fetch_one(&state.db)
        .await?;
        // Who it would reach today, if it were due all day (a dry run).
        let mut all_day = o.clone();
        all_day.hour = 0;
        let today = due(&state.db, &all_day, t).await?.len();
        out.push(json!({
            "id": o.id,
            "when": match &o.when {
                When::Birthday => "birthday".to_owned(),
                When::Yearly { month, day } => format!("yearly {month:02}-{day:02}"),
                When::Once { date } => format!("once {date}"),
            },
            "hour_utc": o.hour,
            "to": format!("{:?}", o.to),
            "only": o.only,
            "text": o.text,
            "sent": count,
            "last_sent_at": last,
            "recipients_today": today,
        }));
    }
    Ok(Json(
        json!({ "team_napsack": crate::team::id(&state.db).await?, "occasions": out, "problems": problems }),
    ))
}

/// `POST /api/admin/occasions/{id}/try`: sends that occasion's message to
/// you (the Admin asking), now, to see it as people will. It isn't recorded
/// as a send, so the real one still goes when it's due. Admins only.
pub async fn try_it(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let (occasions, _) = schedule();
    let o = occasions.into_iter().find(|o| o.id == id).ok_or_else(|| {
        AppError::not_found("There's no occasion with that id in occasions.toml.")
    })?;
    // As if it were your own birthday, for the birthday ones.
    let d = Due {
        user: me.id,
        occurrence: "try".into(),
        birthday_of: (o.when == When::Birthday).then_some(me.id),
    };
    let text = fill(&state.db, &o, &d).await?;
    let message_id = crate::team::send(&state, me.id, &text).await.map_err(|e| {
        tracing::warn!(admin_id = me.id, error = %e, "trying an occasion failed");
        AppError::bad(
            "Couldn't send it to you: your account's public key isn't one napsack can write to.",
        )
    })?;
    crate::admin_users::record(
        &state.db,
        me.id,
        "try_occasion",
        Some(me.id),
        json!({ "occasion": o.id }),
    )
    .await?;
    tracing::info!(admin_id = me.id, occasion = %o.id, message_id, "occasion tried");
    Ok(Json(json!({ "sent": true, "message_id": message_id })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[test]
    fn the_shipped_schedule_is_valid() {
        let (good, problems) = schedule();
        assert!(problems.is_empty(), "{problems:?}");
        assert!(!good.is_empty());
    }

    #[test]
    fn checks_catch_mistakes() {
        let bad = |when: &str, to: &str, text: &str| {
            let toml = format!(
                "[[occasion]]\nid = \"x\"\nwhen = \"{when}\"\nto = {to}\ntext = \"{text}\"\n"
            );
            let (good, problems) = parse(&toml);
            assert!(
                good.is_empty() && problems.len() == 1,
                "{when} {to} {text}: {problems:?}"
            );
        };
        bad("someday", "\"everyone\"", "hi");
        bad("yearly 13-01", "\"everyone\"", "hi");
        bad("once 2026-02-30x", "\"everyone\"", "hi");
        bad("yearly 12-25", "\"birthday person\"", "hi");
        bad("birthday", "\"strangers\"", "hi");
        bad("birthday", "[]", "hi");
        bad("yearly 12-25", "\"everyone\"", "hi {birthday_name}");
        bad("yearly 12-25", "\"everyone\"", "hi {nmae}");
        bad("yearly 12-25", "\"everyone\"", "");
        let (good, _) = parse("[[occasion]]\nid = \"ok\"\nwhen = \"birthday\"\nto = \"birthday friends\"\nonly = [\"Nate\"]\ntext = \"It's {birthday_name}'s birthday, {name}!\"\n");
        assert_eq!(good[0].to, Audience::BirthdayFriends);
        assert_eq!(good[0].only.as_deref(), Some(&["nate".to_owned()][..]));
        assert_eq!(good[0].hour, 15);
    }

    async fn person(db: &SqlitePool, id: i64, name: &str) {
        sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', 0)")
            .bind(id).bind(name).execute(db).await.unwrap();
    }

    #[tokio::test]
    async fn who_gets_what_and_when() {
        let db = temp_db().await;
        for (id, name) in [(1, "nate"), (2, "ana"), (3, "ben"), (4, "cal")] {
            person(&db, id, name).await;
        }
        // Ana's birthday is Oct 24; she's friends with Nate and Ben. Cal is turned off.
        sqlx::query(
            "INSERT INTO user_birthdays (user_id, month, day, created_at) VALUES (2, 10, 24, 0)",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (1, 2, 0), (2, 3, 0)",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO deactivations (user_id, deactivated_by, deactivated_at) VALUES (4, 1, 0)",
        )
        .execute(&db)
        .await
        .unwrap();
        let t = crate::aws::parse_iso("2026-10-24T16:00:00Z").unwrap();
        let occasion = |when: When, to: Audience, only: Option<Vec<String>>| Occasion {
            id: "x".into(),
            when,
            hour: 15,
            to,
            only,
            text: "hi".into(),
        };
        let users = |v: Vec<Due>| v.into_iter().map(|d| d.user).collect::<Vec<_>>();

        let b = occasion(When::Birthday, Audience::BirthdayPerson, None);
        let due_now = due(&db, &b, t).await.unwrap();
        assert_eq!(
            due_now,
            vec![Due {
                user: 2,
                occurrence: "2026-10-24:2".into(),
                birthday_of: Some(2)
            }]
        );
        assert!(
            due(&db, &b, t - 3 * 3600).await.unwrap().is_empty(),
            "not before its hour"
        );
        assert!(
            due(&db, &b, t + 86_400).await.unwrap().is_empty(),
            "not the next day"
        );
        let mut friends = users(
            due(
                &db,
                &occasion(When::Birthday, Audience::BirthdayFriends, None),
                t,
            )
            .await
            .unwrap(),
        );
        friends.sort();
        assert_eq!(friends, vec![1, 3]);
        assert_eq!(
            users(
                due(
                    &db,
                    &occasion(
                        When::Birthday,
                        Audience::BirthdayFriends,
                        Some(vec!["nate".into()])
                    ),
                    t
                )
                .await
                .unwrap()
            ),
            vec![1]
        );

        let mut all = users(
            due(
                &db,
                &occasion(
                    When::Yearly { month: 10, day: 24 },
                    Audience::Everyone,
                    None,
                ),
                t,
            )
            .await
            .unwrap(),
        );
        all.sort();
        assert_eq!(all, vec![1, 2, 3], "everyone who's on");
        assert!(due(
            &db,
            &occasion(
                When::Yearly { month: 12, day: 25 },
                Audience::Everyone,
                None
            ),
            t
        )
        .await
        .unwrap()
        .is_empty());
        assert_eq!(
            users(
                due(
                    &db,
                    &occasion(
                        When::Once {
                            date: "2026-10-24".into()
                        },
                        Audience::Users(vec!["nate".into()]),
                        None
                    ),
                    t
                )
                .await
                .unwrap()
            ),
            vec![1]
        );
        assert!(due(
            &db,
            &occasion(
                When::Once {
                    date: "2027-10-24".into()
                },
                Audience::Everyone,
                None
            ),
            t
        )
        .await
        .unwrap()
        .is_empty());
    }
}
