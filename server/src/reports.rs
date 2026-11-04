//! Reports (F28; docs/design/report-and-block.md): anyone can report a
//! message sent to them, a message in a group's history they're part of, or
//! a person they know, and Admins work the reports on System › Reports.
//!
//! **No message content in a report, ever.** Messages are end-to-end
//! encrypted and stay that way: a report carries what the server already
//! knows (whose message, its id, what kind, when), never its text or picture.
//! The reporter's note is their own words, stored as plain text for Admins.
//!
//! Admins dismiss a report, or act on the reported person: warn them (a Team
//! Napsack message, team.rs), suspend them for 1, 7, or 30 days, or turn
//! their account off (a `deactivations` row with an end, or without). Each
//! tells them why, in the Admin's words, and points at the message by its id
//! so their own app can show it to them. Nobody is ever told who reported
//! whom; the reporter isn't told the outcome. Reports and outcomes are
//! append-only (Rule 1).

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    db::now,
    error::{AppError, AppResult},
    guard::{MAX_REPORTS_PER_DAY, MAX_REPORT_WORDS},
    roles::Role,
    SharedState,
};

/// What people pick from: Spam; Harassment or bullying; Nudity or sexual
/// content; Violence or threats; Hate; Something else.
pub const REASONS: &[&str] = &["spam", "harassment", "nudity", "violence", "hate", "other"];
/// How long an Admin can suspend someone for.
pub const SUSPENSION_DAYS: &[i64] = &[1, 7, 30];

fn not_a_message() -> AppError {
    AppError::not_found("That message isn't one you can report.")
}

fn not_a_person() -> AppError {
    AppError::not_found("That isn't someone you can report.")
}

// ---------- dates, in UTC (the server doesn't know anyone's time zone) ----------

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// (year, "3 Nov", "14:02") for a unix time.
fn parts(t: i64) -> (String, String, String) {
    let iso = crate::aws::iso(t);
    let month = iso[5..7].parse::<usize>().unwrap_or(1).clamp(1, 12);
    let day = iso[8..10].trim_start_matches('0');
    (
        iso[..4].to_owned(),
        format!("{day} {}", MONTHS[month - 1]),
        iso[11..16].to_owned(),
    )
}

/// "3 Nov", or "3 Nov 2025" in another year than this one.
pub fn day(t: i64) -> String {
    let (year, date, _) = parts(t);
    if year == parts(now()).0 {
        date
    } else {
        format!("{date} {year}")
    }
}

/// "10 Nov, 14:02 UTC" (with the year, in another year than this one).
pub fn moment(t: i64) -> String {
    let (_, _, clock) = parts(t);
    format!("{}, {clock} UTC", day(t))
}

// ---------- filing a report ----------

/// What a report is about, as the server found it.
#[derive(Debug, PartialEq)]
pub struct Target {
    pub kind: &'static str,
    pub reported: i64,
    pub message_id: Option<i64>,
    pub group_id: Option<i64>,
    /// "text", "pic", or "video".
    pub message_kind: Option<&'static str>,
    pub message_at: Option<i64>,
}

/// Checks `me` can see what they're reporting, and finds whose it is. A
/// message must have been sent to them, or be in a group's history that
/// includes them (as `groups::audience` decides); a person must be someone
/// they know (`blocks::known`). Anything else, including an id that doesn't
/// exist, gets the same answer, so a report can't find out what exists.
pub async fn target(
    db: &SqlitePool,
    me: i64,
    kind: &str,
    message_id: Option<i64>,
    group_id: Option<i64>,
    user_id: Option<i64>,
) -> AppResult<Target> {
    let found = match kind {
        "message" => {
            let id = message_id.ok_or_else(|| AppError::bad("Say which message."))?;
            let row: Option<(i64, String, i64, i64)> = sqlx::query_as(
                "SELECT sender_id, kind, format, created_at FROM messages WHERE id = ? AND recipient_id = ?",
            )
            .bind(id)
            .bind(me)
            .fetch_optional(db)
            .await?;
            let (sender, what, format, at) = row.ok_or_else(not_a_message)?;
            let message_kind = match (what.as_str(), format) {
                ("text", _) => "text",
                (_, crate::version::VIDEO_FORMAT) => "video",
                _ => "pic",
            };
            Target {
                kind: "message",
                reported: sender,
                message_id: Some(id),
                group_id: None,
                message_kind: Some(message_kind),
                message_at: Some(at),
            }
        }
        "group_message" => {
            let (Some(id), Some(group)) = (message_id, group_id) else {
                return Err(AppError::bad("Say which group and which message."));
            };
            // Something someone sent (not a group event), in my history of
            // the group: the same rule as groups::audience.
            let row: Option<(i64, Option<i64>, i64, i64)> = sqlx::query_as(
                "SELECT gm.sender_id, gm.pic_id, gm.format, gm.created_at FROM group_messages gm
                 WHERE gm.id = ?1 AND gm.group_id = ?2 AND gm.kind = 'text'
                   AND EXISTS (SELECT 1 FROM group_members m WHERE m.group_id = ?2 AND m.user_id = ?3
                                 AND m.left_at IS NULL AND m.visible_after_id < ?1)",
            )
            .bind(id)
            .bind(group)
            .bind(me)
            .fetch_optional(db)
            .await?;
            let (sender, pic, format, at) = row.ok_or_else(not_a_message)?;
            if sender == me {
                return Err(AppError::bad("That's your own message."));
            }
            let message_kind = match (pic, format) {
                (None, _) => "text",
                (Some(_), crate::groups::FORMAT_E2E_VIDEO) => "video",
                (Some(_), _) => "pic",
            };
            Target {
                kind: "group_message",
                reported: sender,
                message_id: Some(id),
                group_id: Some(group),
                message_kind: Some(message_kind),
                message_at: Some(at),
            }
        }
        "person" => {
            let them = user_id.ok_or_else(|| AppError::bad("Say who you're reporting."))?;
            if them == me {
                return Err(AppError::bad("That's you."));
            }
            if !crate::blocks::known(db, me, them).await? {
                return Err(not_a_person());
            }
            Target {
                kind: "person",
                reported: them,
                message_id: None,
                group_id: None,
                message_kind: None,
                message_at: None,
            }
        }
        _ => {
            return Err(AppError::bad(
                "Choose what you're reporting: a message, a group message, or a person.",
            ))
        }
    };
    if crate::team::is_system(db, found.reported).await? {
        return Err(AppError::bad(
            "That's from napsack itself, so there's nothing to report. You can mute its chat.",
        ));
    }
    Ok(found)
}

/// Someone's own words (a reporter's note, an Admin's words): one line, at
/// most MAX_REPORT_WORDS characters, checked like other stored text. Empty
/// is none.
fn words(s: Option<&str>, what: &str) -> AppResult<Option<String>> {
    let Some(s) = s.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    if s.chars().count() > MAX_REPORT_WORDS {
        return Err(AppError::bad(format!(
            "Keep {} under {MAX_REPORT_WORDS} characters.",
            what.to_lowercase()
        )));
    }
    if crate::text::check_name(s).is_err() {
        return Err(AppError::bad(format!(
            "{what} can't have line breaks, or invisible or direction-changing characters."
        )));
    }
    Ok(Some(s.to_owned()))
}

/// Stores the report, once: reporting the same message again (a retry, or
/// a second tap) finds the first, as does reporting a person again while
/// that report is still open. Returns (id, whether it was already there).
pub async fn file(
    db: &SqlitePool,
    me: i64,
    t: &Target,
    reason: &str,
    note: Option<&str>,
) -> AppResult<(i64, bool)> {
    let mut tx = crate::db::write_tx(db).await?;
    let earlier: Option<i64> = if t.kind == "person" {
        sqlx::query_scalar(
            "SELECT r.id FROM reports r WHERE r.reporter_id = ? AND r.reported_id = ? AND r.kind = 'person'
               AND NOT EXISTS (SELECT 1 FROM report_outcomes o WHERE o.report_id = r.id)",
        )
        .bind(me)
        .bind(t.reported)
        .fetch_optional(&mut *tx)
        .await?
    } else {
        sqlx::query_scalar(
            "SELECT id FROM reports WHERE reporter_id = ? AND kind = ? AND message_id = ?",
        )
        .bind(me)
        .bind(t.kind)
        .bind(t.message_id)
        .fetch_optional(&mut *tx)
        .await?
    };
    if let Some(id) = earlier {
        return Ok((id, true));
    }
    let today: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM reports WHERE reporter_id = ? AND created_at > ?")
            .bind(me)
            .bind(now() - 86_400)
            .fetch_one(&mut *tx)
            .await?;
    if today >= MAX_REPORTS_PER_DAY {
        return Err(AppError::TooManyRequests(
            "That's a lot of reports for one day. An Admin will see the ones you've sent; try again tomorrow."
                .into(),
        ));
    }
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO reports (reporter_id, reported_id, kind, message_id, group_id, message_kind,
            message_at, reason, note, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(me)
    .bind(t.reported)
    .bind(t.kind)
    .bind(t.message_id)
    .bind(t.group_id)
    .bind(t.message_kind)
    .bind(t.message_at)
    .bind(reason)
    .bind(note)
    .bind(now())
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok((id, false))
}

#[derive(Deserialize)]
pub struct NewReport {
    kind: String,
    message_id: Option<i64>,
    group_id: Option<i64>,
    user_id: Option<i64>,
    reason: String,
    note: Option<String>,
}

/// `POST /api/reports`: report a message or a person. → `{id, already}`.
pub async fn create(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<NewReport>,
) -> AppResult<Json<Value>> {
    if !REASONS.contains(&req.reason.as_str()) {
        return Err(AppError::bad("Choose a reason from the list."));
    }
    let note = words(req.note.as_deref(), "The note")?;
    let t = target(
        &state.db,
        me.id,
        &req.kind,
        req.message_id,
        req.group_id,
        req.user_id,
    )
    .await?;
    let (id, already) = file(&state.db, me.id, &t, &req.reason, note.as_deref()).await?;
    if !already {
        // Ids and the reason (one of a fixed list) only: never the note.
        tracing::info!(
            report_id = id,
            reporter_id = me.id,
            reported_id = t.reported,
            kind = t.kind,
            reason = %req.reason,
            "report made"
        );
        tell_support(&state, id).await;
    }
    Ok(Json(json!({ "id": id, "already": already })))
}

// ---------- the email ----------

/// The email to the support address for a new report: who reported whom and
/// a link to it on System › Reports. Nothing else: no reason, no note, never
/// content. (subject, body)
pub fn support_email(
    id: i64,
    kind: &str,
    reporter: &str,
    reported: &str,
    site: &str,
) -> (String, String) {
    let what = match kind {
        "person" => "a person",
        _ => "a message",
    };
    (
        format!("New report #{id}"),
        format!(
            "New report #{id}: {what}, reported by @{reporter} about @{reported}.\n\n{site}/admin#reports={id}"
        ),
    )
}

/// Who the email is from: `noreply@` the site's own name, the domain infra
/// verifies with SES (infra/email.tf).
fn sender(site: &str) -> String {
    let host = site.split("://").nth(1).unwrap_or(site);
    let host = host.split(['/', ':']).next().unwrap_or(host);
    format!("napsack <noreply@{host}>")
}

/// For each new report, the email to `FADE_REPORTS_EMAIL` through Amazon SES
/// (docs/design/report-and-block.md, The email), sent in the background so
/// the report doesn't wait on it. Without the setting, or off AWS
/// (development), nothing is sent; the report is on the Reports page either way.
async fn tell_support(state: &SharedState, id: i64) {
    let Some(to) = state.config.reports_email.clone() else {
        return;
    };
    let names: Option<(String, String, String)> = sqlx::query_as(
        "SELECT r.kind, a.username, b.username FROM reports r
         JOIN users a ON a.id = r.reporter_id JOIN users b ON b.id = r.reported_id WHERE r.id = ?",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let Some((kind, reporter, reported)) = names else {
        return;
    };
    let site = state.config.public_url.clone();
    let state = state.clone();
    tokio::spawn(async move {
        let Some(aws) = state.metrics.aws() else {
            tracing::info!(report_id = id, "report email not sent: not running on AWS");
            return;
        };
        let (subject, body) = support_email(id, &kind, &reporter, &reported, &site);
        match aws.ses_send(&sender(&site), &to, &subject, &body).await {
            Ok(()) => tracing::info!(report_id = id, "report emailed to support"),
            Err(e) => tracing::error!(report_id = id, error = %e, "report email not sent"),
        }
    });
}

// ---------- System › Reports (Admins only) ----------

#[derive(FromRow)]
struct ReportRow {
    id: i64,
    kind: String,
    reason: String,
    note: Option<String>,
    message_id: Option<i64>,
    message_kind: Option<String>,
    message_at: Option<i64>,
    group_id: Option<i64>,
    group_name: Option<String>,
    reporter_id: i64,
    reporter: String,
    reported_id: i64,
    reported: String,
    created_at: i64,
    others: i64,
    deactivated: bool,
    action: Option<String>,
    notice: Option<String>,
    outcome_note: Option<String>,
    until: Option<i64>,
    decided_by: Option<String>,
    decided_at: Option<i64>,
    told: Option<i64>,
}

/// Every report with who, about whom, what, and what was done about it.
/// (Reports of a deleted account are gone with it; an Admin who deleted
/// theirs since is "Deleted account".)
const REPORT_SELECT: &str = "SELECT r.id, r.kind, r.reason, r.note, r.message_id, r.message_kind,
        r.message_at, r.group_id, g.name AS group_name, r.reporter_id, a.username AS reporter,
        r.reported_id, b.username AS reported, r.created_at,
        (SELECT COUNT(*) FROM reports o WHERE o.reported_id = r.reported_id AND o.id != r.id) AS others,
        EXISTS(SELECT 1 FROM deactivations d WHERE d.user_id = r.reported_id AND d.reactivated_at IS NULL) AS deactivated,
        x.action, x.notice, x.note AS outcome_note, x.until,
        CASE WHEN EXISTS (SELECT 1 FROM deleted_accounts z WHERE z.user_id = x.admin_id)
             THEN 'Deleted account' ELSE adm.username END AS decided_by,
        x.created_at AS decided_at, x.message_id AS told
     FROM reports r JOIN users a ON a.id = r.reporter_id JOIN users b ON b.id = r.reported_id
     LEFT JOIN groups g ON g.id = r.group_id
     LEFT JOIN report_outcomes x ON x.report_id = r.id
     LEFT JOIN users adm ON adm.id = x.admin_id";

fn report_json(r: &ReportRow) -> Value {
    json!({
        "id": r.id,
        "created_at": r.created_at,
        "kind": r.kind,
        "reason": r.reason,
        "note": r.note,
        "reporter": { "id": r.reporter_id, "username": r.reporter },
        "reported": { "id": r.reported_id, "username": r.reported, "deactivated": r.deactivated },
        // Whose, which, what kind, when: never what it said.
        "message": r.message_id.map(|id| json!({ "id": id, "kind": r.message_kind, "sent_at": r.message_at })),
        "group": r.group_id.map(|id| json!({ "id": id, "name": r.group_name })),
        "others": r.others,
        "outcome": r.action.as_ref().map(|action| json!({
            "action": action, "by": r.decided_by, "at": r.decided_at, "notice": r.notice,
            "note": r.outcome_note, "until": r.until, "told": r.told.is_some(),
        })),
    })
}

/// `GET /api/admin/reports`: the open reports, newest first, then the ones
/// dealt with, newest first. Admins only.
pub async fn list(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let rows: Vec<ReportRow> = sqlx::query_as(&format!(
        "{REPORT_SELECT} ORDER BY x.id IS NOT NULL, r.created_at DESC, r.id DESC LIMIT 500"
    ))
    .fetch_all(&state.db)
    .await?;
    let open = rows.iter().filter(|r| r.action.is_none()).count();
    Ok(Json(json!({
        "open": open,
        "reports": rows.iter().map(report_json).collect::<Vec<_>>(),
    })))
}

async fn load(db: &SqlitePool, id: i64) -> AppResult<ReportRow> {
    sqlx::query_as(&format!("{REPORT_SELECT} WHERE r.id = ?"))
        .bind(id)
        .fetch_optional(db)
        .await?
        .ok_or_else(|| AppError::not_found("No such report."))
}

/// `GET /api/admin/reports/{id}`: one report, and the others about the same
/// person. Admins only.
pub async fn get(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let r = load(&state.db, id).await?;
    let others: Vec<(i64, i64, String, String, Option<String>)> = sqlx::query_as(
        "SELECT r.id, r.created_at, r.kind, r.reason, x.action FROM reports r
         LEFT JOIN report_outcomes x ON x.report_id = r.id
         WHERE r.reported_id = ? AND r.id != ? ORDER BY r.created_at DESC, r.id DESC LIMIT 100",
    )
    .bind(r.reported_id)
    .bind(id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(json!({
        "report": report_json(&r),
        "others": others.iter().map(|(id, at, kind, reason, action)| json!({
            "id": id, "created_at": at, "kind": kind, "reason": reason, "action": action,
        })).collect::<Vec<_>>(),
    })))
}

#[derive(Deserialize)]
pub struct Decision {
    /// "dismiss", "warn", "suspend", or "block".
    action: String,
    /// For "suspend": 1, 7, or 30.
    days: Option<i64>,
    /// The Admin's words: what the person is told (warn, suspend, block), or
    /// a note for Admins (dismiss).
    words: Option<String>,
}

/// What a decision does, checked and ready.
struct Ruling {
    action: &'static str,
    words: Option<String>,
    until: Option<i64>,
}

/// Records the outcome, and for a suspension or a block turns the account
/// off (with its end, if any, and the Admin's words), in one transaction.
/// A suspension replaces one already running; an account already turned off
/// for good is left to System › Users.
async fn apply(db: &SqlitePool, report: &ReportRow, admin: i64, ruling: &Ruling) -> AppResult<()> {
    let at = now();
    let mut tx = crate::db::write_tx(db).await?;
    let (notice, note) = if ruling.action == "dismissed" {
        (None, ruling.words.as_deref())
    } else {
        (ruling.words.as_deref(), None)
    };
    let inserted = sqlx::query(
        "INSERT INTO report_outcomes (report_id, action, admin_id, notice, note, until, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(report.id)
    .bind(ruling.action)
    .bind(admin)
    .bind(notice)
    .bind(note)
    .bind(ruling.until)
    .bind(at)
    .execute(&mut *tx)
    .await;
    match inserted {
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            return Err(AppError::Conflict(
                "That report has already been dealt with.".into(),
            ));
        }
        other => {
            other?;
        }
    }
    if matches!(ruling.action, "suspended" | "blocked") {
        let current: Option<(i64, Option<i64>)> = sqlx::query_as(
            "SELECT id, until FROM deactivations WHERE user_id = ? AND reactivated_at IS NULL",
        )
        .bind(report.reported_id)
        .fetch_optional(&mut *tx)
        .await?;
        match current {
            Some((_, None)) => {
                return Err(AppError::Conflict(
                    "That account is already turned off. Turn it back on in System › Users first, or dismiss the report."
                        .into(),
                ));
            }
            Some((id, Some(_))) => {
                // The new one takes over from a suspension under way.
                sqlx::query(
                    "UPDATE deactivations SET reactivated_by = ?, reactivated_at = ? WHERE id = ?",
                )
                .bind(admin)
                .bind(at)
                .bind(id)
                .execute(&mut *tx)
                .await?;
            }
            None => {}
        }
        sqlx::query(
            "INSERT INTO deactivations (user_id, reason, deactivated_by, deactivated_at, until, notice)
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(report.reported_id)
        .bind(format!("Report #{}", report.id))
        .bind(admin)
        .bind(at)
        .bind(ruling.until)
        .bind(notice)
        .execute(&mut *tx)
        .await?;
    }
    let mut detail = json!({ "report_id": report.id, "words_given": ruling.words.is_some() });
    if let Some(until) = ruling.until {
        detail["until"] = json!(until);
    }
    crate::admin_users::record(
        &mut *tx,
        admin,
        &format!("report_{}", ruling.action),
        Some(report.reported_id),
        detail,
    )
    .await?;
    tx.commit().await?;
    Ok(())
}

/// "a message you sent", "a pic you sent in Road trip on 3 Nov", or "you":
/// what the report was about, as the reported person sees it. A direct
/// message names neither whom it went to nor when: only they could have
/// reported it, and the reporter is never told (Nate, 2026-11-03).
fn about(r: &ReportRow) -> String {
    let noun = match r.message_kind.as_deref() {
        Some("pic") => "pic",
        Some("video") => "video",
        _ => "message",
    };
    // The day in UTC, and it says so: the server doesn't know their time zone.
    let on = r
        .message_at
        .map(|t| format!("{} (UTC)", day(t)))
        .unwrap_or_default();
    match r.kind.as_str() {
        "message" => format!("a {noun} you sent"),
        "group_message" => format!(
            "a {noun} you sent in {} on {on}",
            r.group_name.as_deref().unwrap_or("a group")
        ),
        _ => "you".to_owned(),
    }
}

/// Where the app opens that group at that message: `/#group=<id>&message=<id>`.
/// Never a direct chat's: it would say who reported it (`about`).
fn link(r: &ReportRow, site: &str) -> Option<String> {
    let id = r.message_id?;
    match r.kind.as_str() {
        "group_message" => Some(format!("{site}/#group={}&message={}", r.group_id?, id)),
        _ => None,
    }
}

/// What Team Napsack tells the reported person. It names a group message,
/// never who reported it, and never what it said: the server doesn't know.
fn telling(r: &ReportRow, ruling: &Ruling, site: &str) -> String {
    let words = ruling.words.as_deref().unwrap_or_default();
    let reviewed = format!("An Admin reviewed a report about {}: {words}", about(r));
    let mut text = match (ruling.action, ruling.until) {
        ("suspended", Some(until)) => {
            format!(
                "Your account is suspended until {}. {reviewed}",
                moment(until)
            )
        }
        ("blocked", _) => format!("Your account has been turned off. {reviewed}"),
        _ => reviewed,
    };
    if let Some(link) = link(r, site) {
        text.push_str(&format!("\n\nOpen it: {link}"));
    }
    text
}

/// `POST /api/admin/reports/{id}/outcome` `{action, days?, words?}`: what an
/// Admin does about a report, once. Admins only.
pub async fn decide(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Path(id): Path<i64>,
    Json(req): Json<Decision>,
) -> AppResult<Json<Value>> {
    crate::roles::require(&state, &me, Role::Admin).await?;
    let report = load(&state.db, id).await?;
    let action = match req.action.as_str() {
        "dismiss" => "dismissed",
        "warn" => "warned",
        "suspend" => "suspended",
        "block" => "blocked",
        _ => {
            return Err(AppError::bad(
                "Choose what to do: dismiss, warn, suspend, or block.",
            ))
        }
    };
    let words = words(req.words.as_deref(), "Your words")?;
    if action != "dismissed" && words.is_none() {
        return Err(AppError::bad(
            "Write what they'll be told: it's the reason they'll see.",
        ));
    }
    let until = if action == "suspended" {
        match req.days {
            Some(d) if SUSPENSION_DAYS.contains(&d) => Some(now() + d * 86_400),
            _ => return Err(AppError::bad("Suspend for 1, 7, or 30 days.")),
        }
    } else {
        None
    };
    if matches!(action, "suspended" | "blocked") {
        if report.reported_id == me.id {
            return Err(AppError::bad("You can't turn off your own account."));
        }
        if crate::usernames::is_listed_admin(
            &state.db,
            &state.admins,
            report.reported_id,
            &report.reported,
        )
        .await?
        {
            return Err(AppError::bad(
                "Admins come from settings: remove them from the admin list first.",
            ));
        }
    }
    let ruling = Ruling {
        action,
        words,
        until,
    };
    apply(&state.db, &report, me.id, &ruling).await?;

    let user = report.reported_id;
    if matches!(action, "suspended" | "blocked") {
        let ended = crate::account::end_sessions(&state, user, None).await?;
        crate::admin_users::tell_friends(&state, user).await?;
        tracing::info!(
            admin_id = me.id,
            user_id = user,
            sessions_ended = ended,
            until,
            "account turned off for a report"
        );
    }
    // Told by Team Napsack, end-to-end encrypted to them like any text, so
    // they read it when they're next in (after a suspension, or if turned back on).
    let mut told = None;
    if action != "dismissed" {
        let text = telling(&report, &ruling, &state.config.public_url);
        match crate::team::send(&state, user, &text).await {
            Ok(message) => {
                let mut tx = crate::db::write_tx(&state.db).await?;
                sqlx::query("UPDATE report_outcomes SET message_id = ? WHERE report_id = ? AND message_id IS NULL")
                    .bind(message)
                    .bind(id)
                    .execute(&mut *tx)
                    .await?;
                tx.commit().await?;
                told = Some(message);
            }
            Err(e) => {
                tracing::error!(report_id = id, user_id = user, error = %e, "the reported person wasn't told");
            }
        }
    }
    tracing::info!(
        admin_id = me.id,
        report_id = id,
        user_id = user,
        action,
        "report dealt with"
    );
    Ok(Json(json!({
        "action": action,
        "until": until,
        "told": told.is_some(),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    /// Ana (1) and Ben (2) are friends; Cat (3) is a stranger; Team Napsack
    /// is 9. Ben sent Ana a text (1) and a video (2); Ana sent Ben one (3).
    /// In the group "trip": Ana, Ben, and Cat, who joined after message 10.
    async fn seeded() -> SqlitePool {
        let db = temp_db().await;
        sqlx::raw_sql(
            "INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES
                (1, 'ana', 'h', 'k', 'w', 0), (2, 'ben', 'h', 'k', 'w', 0), (3, 'cat', 'h', 'k', 'w', 0),
                (9, 'napsack', 'h', 'k', '', 0);
             INSERT INTO system_accounts (user_id, kind, created_at) VALUES (9, 'team', 0);
             INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (1, 2, 0);
             INSERT INTO messages (id, sender_id, recipient_id, kind, ciphertext, snap_state, format, created_at) VALUES
                (1, 2, 1, 'text', 'c', NULL, 2, 100), (2, 2, 1, 'snap', NULL, 'opened', 4, 200),
                (3, 1, 2, 'text', 'c', NULL, 2, 300), (4, 9, 1, 'text', 'c', NULL, 2, 400);
             INSERT INTO groups (id, name, created_by, created_at) VALUES (1, 'trip', 1, 0), (2, 'other', 2, 0);
             INSERT INTO group_members (group_id, user_id, role, joined_at, visible_after_id) VALUES
                (1, 1, 'owner', 0, 0), (1, 2, 'member', 0, 0), (1, 3, 'member', 0, 10), (2, 2, 'owner', 0, 0);
             INSERT INTO group_messages (id, group_id, sender_id, kind, body, format, created_at) VALUES
                (5, 1, 2, 'text', '', 3, 500), (6, 1, 2, 'event', '{}', 0, 600), (12, 1, 1, 'text', '', 3, 700),
                (13, 2, 2, 'text', '', 3, 800);",
        )
        .execute(&db)
        .await
        .unwrap();
        db
    }

    fn is_404(r: AppResult<Target>, words: &str) -> bool {
        matches!(r, Err(AppError::NotFound(m)) if m == words)
    }

    #[tokio::test]
    async fn only_what_the_reporter_was_shown() {
        let db = seeded().await;
        let t = target(&db, 1, "message", Some(1), None, None)
            .await
            .unwrap();
        assert_eq!(
            (t.reported, t.message_kind, t.message_at),
            (2, Some("text"), Some(100))
        );
        let v = target(&db, 1, "message", Some(2), None, None)
            .await
            .unwrap();
        assert_eq!(v.message_kind, Some("video"));
        // Her own message, someone else's, and one that doesn't exist: one answer.
        let nope = "That message isn't one you can report.";
        for id in [3, 999] {
            assert!(
                is_404(target(&db, 1, "message", Some(id), None, None).await, nope),
                "{id}"
            );
        }
        assert!(is_404(
            target(&db, 3, "message", Some(1), None, None).await,
            nope
        ));
        // Team Napsack's own messages aren't for reporting.
        assert!(matches!(
            target(&db, 1, "message", Some(4), None, None).await,
            Err(AppError::BadRequest(_))
        ));

        // Groups: in her history, from someone else, not an event.
        let g = target(&db, 1, "group_message", Some(5), Some(1), None)
            .await
            .unwrap();
        assert_eq!((g.reported, g.group_id), (2, Some(1)));
        for (who, id, group) in [(3, 5, 1), (1, 6, 1), (1, 13, 2), (1, 5, 2), (1, 999, 1)] {
            assert!(
                is_404(
                    target(&db, who, "group_message", Some(id), Some(group), None).await,
                    nope
                ),
                "{who} {id} {group}"
            );
        }
        // Cat joined after 10: Ana's 12 is in her history.
        assert_eq!(
            target(&db, 3, "group_message", Some(12), Some(1), None)
                .await
                .unwrap()
                .reported,
            1
        );

        // People: someone she knows.
        assert_eq!(
            target(&db, 1, "person", None, None, Some(2))
                .await
                .unwrap()
                .reported,
            2
        );
        assert_eq!(
            target(&db, 1, "person", None, None, Some(3))
                .await
                .unwrap()
                .reported,
            3,
            "in a group"
        );
        let nobody = "That isn't someone you can report.";
        // Team Napsack, a stranger, and nobody at all: one answer.
        sqlx::query("UPDATE group_members SET left_at = 1 WHERE user_id = 3")
            .execute(&db)
            .await
            .unwrap();
        for (who, id) in [(2, 9), (2, 999), (2, 3), (3, 999)] {
            assert!(
                is_404(
                    target(&db, who, "person", None, None, Some(id)).await,
                    nobody
                ),
                "{who} {id}"
            );
        }
        assert!(matches!(
            target(&db, 1, "person", None, None, Some(1)).await,
            Err(AppError::BadRequest(_))
        ));
    }

    #[tokio::test]
    async fn once_per_message_and_capped_per_day() {
        let db = seeded().await;
        let t = target(&db, 1, "message", Some(1), None, None)
            .await
            .unwrap();
        let (first, again) = file(&db, 1, &t, "spam", Some("hi")).await.unwrap();
        assert!(!again);
        assert_eq!(file(&db, 1, &t, "hate", None).await.unwrap(), (first, true));
        // A person: again while it's open finds the first; once dealt with, a new one.
        let p = target(&db, 1, "person", None, None, Some(2)).await.unwrap();
        let (person, _) = file(&db, 1, &p, "other", None).await.unwrap();
        assert_eq!(
            file(&db, 1, &p, "other", None).await.unwrap(),
            (person, true)
        );
        sqlx::query("INSERT INTO report_outcomes (report_id, action, admin_id, created_at) VALUES (?, 'dismissed', 3, 0)")
            .bind(person)
            .execute(&db)
            .await
            .unwrap();
        assert!(!file(&db, 1, &p, "other", None).await.unwrap().1);

        // Twenty a day.
        sqlx::query(
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 30)
             INSERT INTO reports (reporter_id, reported_id, kind, reason, created_at)
             SELECT 3, 1, 'person', 'spam', ? FROM n",
        )
        .bind(now())
        .execute(&db)
        .await
        .unwrap();
        let cat = target(&db, 3, "group_message", Some(12), Some(1), None)
            .await
            .unwrap();
        assert!(matches!(
            file(&db, 3, &cat, "spam", None).await,
            Err(AppError::TooManyRequests(_))
        ));
    }

    #[test]
    fn words_are_one_line_and_checked() {
        assert_eq!(words(Some("  "), "The note").unwrap(), None);
        assert_eq!(
            words(Some(" kept sending these "), "The note")
                .unwrap()
                .as_deref(),
            Some("kept sending these")
        );
        for bad in [
            "two\nlines",
            "evil\u{202E}txt",
            &"x".repeat(MAX_REPORT_WORDS + 1),
        ] {
            assert!(words(Some(bad), "The note").is_err(), "{bad:?}");
        }
    }

    #[tokio::test]
    async fn outcomes_are_once_and_suspensions_turn_the_account_off_until_they_end() {
        let db = seeded().await;
        let t = target(&db, 1, "message", Some(1), None, None)
            .await
            .unwrap();
        let (id, _) = file(&db, 1, &t, "harassment", None).await.unwrap();
        let report = load(&db, id).await.unwrap();
        let week = now() + 7 * 86_400;
        let suspend = Ruling {
            action: "suspended",
            words: Some("Be kind.".into()),
            until: Some(week),
        };
        apply(&db, &report, 3, &suspend).await.unwrap();
        assert!(matches!(
            apply(&db, &report, 3, &suspend).await,
            Err(AppError::Conflict(_))
        ));
        let why = crate::admin_users::refusal(&db, 2).await.unwrap().unwrap();
        assert!(
            why.starts_with("This account is suspended until ") && why.ends_with(": Be kind."),
            "{why}"
        );

        // A block on another report replaces the suspension: off for good.
        let p = target(&db, 1, "person", None, None, Some(2)).await.unwrap();
        let (second, _) = file(&db, 1, &p, "spam", None).await.unwrap();
        let block = Ruling {
            action: "blocked",
            words: Some("Spam.".into()),
            until: None,
        };
        apply(&db, &load(&db, second).await.unwrap(), 3, &block)
            .await
            .unwrap();
        assert_eq!(
            crate::admin_users::refusal(&db, 2)
                .await
                .unwrap()
                .as_deref(),
            Some("This account has been turned off: Spam.")
        );
        let rows: Vec<(Option<i64>, Option<i64>)> = sqlx::query_as(
            "SELECT until, reactivated_at FROM deactivations WHERE user_id = 2 ORDER BY id",
        )
        .fetch_all(&db)
        .await
        .unwrap();
        assert_eq!(rows.len(), 2, "the suspension is kept, ended");
        assert!(rows[0].1.is_some() && rows[1] == (None, None), "{rows:?}");
        // A third report can't turn off an account that's already off for good.
        let g = target(&db, 1, "group_message", Some(5), Some(1), None)
            .await
            .unwrap();
        let (third, _) = file(&db, 1, &g, "spam", None).await.unwrap();
        assert!(matches!(
            apply(&db, &load(&db, third).await.unwrap(), 3, &suspend).await,
            Err(AppError::Conflict(_))
        ));
        // Nothing of that failed one stayed.
        let outcomes: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM report_outcomes")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(outcomes, 2);
        let actions: Vec<String> =
            sqlx::query_scalar("SELECT action FROM admin_actions ORDER BY id")
                .fetch_all(&db)
                .await
                .unwrap();
        assert_eq!(actions, ["report_suspended", "report_blocked"]);
        let listed = load(&db, id).await.unwrap();
        assert_eq!(listed.others, 2);
        assert!(listed.deactivated);
    }

    #[tokio::test]
    async fn a_suspension_ends_by_itself() {
        let db = seeded().await;
        sqlx::query(
            "INSERT INTO deactivations (user_id, deactivated_by, deactivated_at, until, notice) VALUES (2, 3, 0, ?, 'Be kind.')",
        )
        .bind(now() + 3600)
        .execute(&db)
        .await
        .unwrap();
        assert!(crate::admin_users::is_deactivated(&db, 2).await.unwrap());
        assert!(crate::admin_users::end_expired(&db)
            .await
            .unwrap()
            .is_empty());
        sqlx::query("UPDATE deactivations SET until = 50 WHERE user_id = 2")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(crate::admin_users::end_expired(&db).await.unwrap(), [2]);
        let (at, by): (Option<i64>, Option<i64>) =
            sqlx::query_as("SELECT reactivated_at, reactivated_by FROM deactivations")
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!((at, by), (Some(50), None), "ended at its end, by nobody");
        // Signing in doesn't wait for the sweep.
        sqlx::query(
            "INSERT INTO deactivations (user_id, deactivated_by, deactivated_at, until) VALUES (2, 3, 60, 70)",
        )
        .execute(&db)
        .await
        .unwrap();
        assert_eq!(crate::admin_users::refusal(&db, 2).await.unwrap(), None);
        assert!(!crate::admin_users::is_deactivated(&db, 2).await.unwrap());
    }

    #[tokio::test]
    async fn the_reported_person_is_told_which_message_never_by_whom_or_what() {
        let db = seeded().await;
        let dm = target(&db, 1, "message", Some(2), None, None)
            .await
            .unwrap();
        let (a, _) = file(&db, 1, &dm, "nudity", Some("not ok")).await.unwrap();
        let g = target(&db, 3, "group_message", Some(12), Some(1), None)
            .await
            .unwrap();
        let (b, _) = file(&db, 3, &g, "spam", None).await.unwrap();
        let warn = Ruling {
            action: "warned",
            words: Some("Please don't.".into()),
            until: None,
        };
        let text = telling(&load(&db, a).await.unwrap(), &warn, "https://napsack.io");
        assert!(
            text.starts_with("An Admin reviewed a report about a video you sent: Please don't."),
            "{text}"
        );
        assert!(
            !text.contains("ana") && !text.contains("#chat=") && !text.contains("1970"),
            "a direct message says neither whom, nor when, nor where: only they could have reported it. {text}"
        );
        assert!(!text.contains("not ok"), "never the note");
        let text = telling(&load(&db, b).await.unwrap(), &warn, "https://napsack.io");
        assert!(
            text.contains("a message you sent in trip on 1 Jan 1970 (UTC)"),
            "{text}"
        );
        assert!(
            text.ends_with("/#group=1&message=12") && !text.contains("cat"),
            "never who reported"
        );
        let suspended = telling(
            &load(&db, a).await.unwrap(),
            &Ruling {
                action: "suspended",
                words: Some("x".into()),
                until: Some(0),
            },
            "",
        );
        assert!(
            suspended
                .starts_with("Your account is suspended until 1 Jan 1970, 00:00 UTC. An Admin"),
            "{suspended}"
        );
    }

    #[test]
    fn dates_read_plainly() {
        // 2026-11-03 14:02 UTC; the year shows only when it isn't this one.
        let this_year = parts(now()).0 == "2026";
        let want = if this_year {
            "3 Nov, 14:02 UTC"
        } else {
            "3 Nov 2026, 14:02 UTC"
        };
        assert_eq!(moment(1_793_714_520), want);
        assert_eq!(day(0), "1 Jan 1970");
    }

    #[test]
    fn the_email_says_who_and_where_and_nothing_else() {
        let (subject, body) = support_email(42, "message", "ana", "ben", "https://napsack.io");
        assert_eq!(subject, "New report #42");
        assert_eq!(
            body,
            "New report #42: a message, reported by @ana about @ben.\n\nhttps://napsack.io/admin#reports=42"
        );
        assert_eq!(sender("https://napsack.io"), "napsack <noreply@napsack.io>");
        assert_eq!(
            sender("https://localhost:8080/"),
            "napsack <noreply@localhost>"
        );
    }
}
