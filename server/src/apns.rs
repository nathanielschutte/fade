//! Notifications on iPhones, through Apple's push service (APNs), beside Web
//! Push for browsers (push.rs): `push::notify` sends each note to both. The
//! app registers its device token for the session that's signed in.
//!
//! What Apple sees: the note itself, who it's from and never what ("Ana",
//! "New message"), since APNs carries it as written (Nate, 2026-11-02: plain
//! first; encrypted notifications, opened on the phone by a notification
//! service extension, come later, plan-ios.md section 11). Which chat it's
//! from goes as an opaque id, as Web Push's topic does.
//!
//! Apple takes a token for each request: an ES256 JWT signed with the team's
//! APNs key (`FADE_APNS_*`, set by Terraform), made fresh every 40 minutes
//! (Apple refuses one older than an hour, or new ones more often than every 20).
//!
//! The number on the app's icon is the chats waiting (`waiting_chats`). Every
//! notification carries it, and when it changes without one (read on the
//! web, a pic opened, a chat muted, a group left, a friend removed, turned
//! off, or deleted) the person's iPhones get the new number on its own, with
//! no alert and no sound (`badge_changed`). Two changes only time makes wait
//! for the next notification or the app opening: a timed mute running out,
//! and an old chat's unread texts coming back with a friendship resumed.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use axum::{extract::State, http::HeaderMap, Json};
use base64::{
    engine::general_purpose::{STANDARD as B64, URL_SAFE_NO_PAD as B64URL},
    Engine,
};
use p256::{
    ecdsa::{signature::Signer, Signature, SigningKey},
    pkcs8::DecodePrivateKey,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{
    auth::{bearer_token, hash_token, AuthUser},
    db::now,
    error::{AppError, AppResult},
    marks::{HIDDEN_UPTO, MUTED_FRIEND, MUTED_GROUP},
    people::SINCE_MY_KEY,
    push::Note,
    SharedState,
};

/// Apple's two push servers, fixed here: a request only says which one
/// (Xcode builds' tokens are the sandbox's; TestFlight and the App Store's
/// are production's).
const PRODUCTION: &str = "https://api.push.apple.com";
const SANDBOX: &str = "https://api.sandbox.push.apple.com";
/// Devices per person with notifications on. Past this, the oldest ends.
const MAX_DEVICES: i64 = 10;
/// Apple keeps an undelivered notification this long (seconds).
const EXPIRES_IN: i64 = 86400;
/// A fresh JWT this often.
const TOKEN_LIFETIME: i64 = 40 * 60;
/// A badge update waits this long, so a burst of changes (reading one chat
/// after another) makes one update: at most one per person this often.
const BADGE_DELAY: Duration = Duration::from_secs(1);

pub struct Apns {
    key: SigningKey,
    key_id: String,
    team_id: String,
    /// The app's bundle id, the `apns-topic` of every request.
    topic: String,
    token: std::sync::Mutex<Option<(i64, String)>>,
    /// The badge each person's iPhones were last given, by a notification or
    /// a badge update, so an update goes only when the number changes. In
    /// memory: after a restart, the first change goes either way.
    badges: std::sync::Mutex<HashMap<i64, i64>>,
    /// People with a badge update waiting to go (one each at most).
    updating: std::sync::Mutex<HashSet<i64>>,
}

impl Apns {
    /// From `FADE_APNS_KEY` (the .p8 file Apple gives, base64-encoded so it
    /// fits on one line), `FADE_APNS_KEY_ID`, `FADE_APPLE_TEAM_ID`, and
    /// `FADE_IOS_BUNDLE_ID`. None when there's no key: iPhones get no
    /// notifications, and everything else works as before.
    pub fn from_env() -> anyhow::Result<Option<Self>> {
        let var = |k: &str| {
            std::env::var(k)
                .ok()
                .map(|v| v.trim().to_owned())
                .filter(|v| !v.is_empty())
        };
        let Some(key) = var("FADE_APNS_KEY") else {
            return Ok(None);
        };
        let pem =
            String::from_utf8(B64.decode(key.as_bytes()).map_err(|_| {
                anyhow::anyhow!("FADE_APNS_KEY must be the .p8 file, base64-encoded")
            })?)?;
        let (Some(key_id), Some(team_id)) = (var("FADE_APNS_KEY_ID"), var("FADE_APPLE_TEAM_ID"))
        else {
            anyhow::bail!("FADE_APNS_KEY needs FADE_APNS_KEY_ID and FADE_APPLE_TEAM_ID too");
        };
        let topic = var("FADE_IOS_BUNDLE_ID").unwrap_or_else(|| "com.getattr.napsack".into());
        Ok(Some(Self::new(&pem, key_id, team_id, topic)?))
    }

    fn new(pem: &str, key_id: String, team_id: String, topic: String) -> anyhow::Result<Self> {
        let key = SigningKey::from_pkcs8_pem(pem)
            .map_err(|_| anyhow::anyhow!("the APNs key isn't a P-256 private key (.p8)"))?;
        Ok(Self {
            key,
            key_id,
            team_id,
            topic,
            token: std::sync::Mutex::new(None),
            badges: Default::default(),
            updating: Default::default(),
        })
    }

    /// Whether `badge` is news to `user`'s iPhones.
    fn badge_differs(&self, user: i64, badge: i64) -> bool {
        self.badges
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&user)
            != Some(&badge)
    }

    /// Apple took `badge` for `user`'s iPhones.
    fn gave_badge(&self, user: i64, badge: i64) {
        self.badges
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(user, badge);
    }

    /// `bearer <JWT>`: the cached token while it's fresh, else a new one.
    fn authorization(&self, at: i64) -> String {
        let mut cached = self.token.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((made, token)) = cached.as_ref() {
            if at - made < TOKEN_LIFETIME {
                return format!("bearer {token}");
            }
        }
        let header = B64URL.encode(json!({ "alg": "ES256", "kid": self.key_id }).to_string());
        let claims = B64URL.encode(json!({ "iss": self.team_id, "iat": at }).to_string());
        let input = format!("{header}.{claims}");
        let sig: Signature = self.key.sign(input.as_bytes());
        let token = format!("{input}.{}", B64URL.encode(sig.to_bytes()));
        *cached = Some((at, token.clone()));
        format!("bearer {token}")
    }

    /// Apple said the token is old or wrong: make a new one next time.
    fn forget_token(&self) {
        *self.token.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

// ---------- devices ----------

/// Lowercase hex, as the app sends it. Apple's tokens are 32 bytes today;
/// it says not to rely on that, so anything from 16 to 100 bytes is taken.
fn valid_token(token: &str) -> bool {
    (32..=200).contains(&token.len())
        && token.len().is_multiple_of(2)
        && token
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Where a device's notifications go: one of Apple's two servers, or (only
/// when `FADE_PUSH_ALLOW_LOCAL` is set, for the test suite) a local receiver.
fn server_for(environment: &str, allow_local: bool) -> Option<String> {
    match environment {
        "production" => Some(PRODUCTION.into()),
        "sandbox" => Some(SANDBOX.into()),
        local if allow_local => {
            let url = reqwest::Url::parse(local).ok()?;
            (url.scheme() == "http" && url.host_str() == Some("127.0.0.1") && url.path() == "/")
                .then(|| local.trim_end_matches('/').to_owned())
        }
        _ => None,
    }
}

#[derive(Deserialize)]
pub struct Register {
    token: String,
    environment: String,
}

/// `POST /api/push/apns`: this iPhone wants notifications, for this session.
/// The app sends it on every launch; the same token again (after signing in
/// again) replaces it.
pub async fn register(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    headers: HeaderMap,
    Json(req): Json<Register>,
) -> AppResult<Json<Value>> {
    if !valid_token(&req.token) {
        return Err(AppError::bad("That notification token was malformed."));
    }
    if server_for(&req.environment, state.config.push_allow_local).is_none() {
        tracing::info!(user_id = me.id, "apns device refused: unknown environment");
        return Err(AppError::bad(
            "Notifications need \"production\" or \"sandbox\".",
        ));
    }
    let session = bearer_token(&headers)
        .map(hash_token)
        .ok_or(AppError::Unauthorized)?;
    let at = now();
    let mut tx = crate::db::write_tx(&state.db).await?;
    let unchanged: Option<i64> = sqlx::query_scalar(
        "SELECT id FROM apns_devices
         WHERE user_id = ? AND session_hash = ? AND token = ? AND environment = ? AND ended_at IS NULL",
    )
    .bind(me.id)
    .bind(&session)
    .bind(&req.token)
    .bind(&req.environment)
    .fetch_optional(&mut *tx)
    .await?;
    if unchanged.is_some() {
        tracing::debug!(user_id = me.id, "apns device unchanged");
        return Ok(Json(json!({ "ok": true })));
    }
    // A token belongs to one install: whoever had it before (another account
    // signed in on this phone, or this one's last session) stops getting them.
    sqlx::query(
        "UPDATE apns_devices SET ended_at = ?, end_reason = 'replaced'
         WHERE token = ? AND ended_at IS NULL",
    )
    .bind(at)
    .bind(&req.token)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO apns_devices (user_id, session_hash, token, environment, created_at)
         VALUES (?, ?, ?, ?, ?)",
    )
    .bind(me.id)
    .bind(&session)
    .bind(&req.token)
    .bind(&req.environment)
    .bind(at)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE apns_devices SET ended_at = ?, end_reason = 'replaced'
         WHERE user_id = ? AND ended_at IS NULL AND id NOT IN (
           SELECT id FROM apns_devices WHERE user_id = ? AND ended_at IS NULL
           ORDER BY id DESC LIMIT ?)",
    )
    .bind(at)
    .bind(me.id)
    .bind(me.id)
    .bind(MAX_DEVICES)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    tracing::info!(user_id = me.id, environment = ?req.environment, "iphone notifications turned on");
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct Unregister {
    token: String,
}

/// `POST /api/push/apns/remove`: turned off on this iPhone.
pub async fn unregister(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<Unregister>,
) -> AppResult<Json<Value>> {
    let ended = sqlx::query(
        "UPDATE apns_devices SET ended_at = ?, end_reason = 'turned_off'
         WHERE user_id = ? AND token = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(me.id)
    .bind(&req.token)
    .execute(&state.db)
    .await?
    .rows_affected();
    tracing::info!(user_id = me.id, ended, "iphone notifications turned off");
    Ok(Json(json!({ "ended": ended })))
}

/// Signing out ends that session's notifications (push::end_for_session).
pub async fn end_for_session(db: &SqlitePool, session_hash: &str) -> sqlx::Result<()> {
    sqlx::query(
        "UPDATE apns_devices SET ended_at = ?, end_reason = 'signed_out'
         WHERE session_hash = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(session_hash)
    .execute(db)
    .await?;
    Ok(())
}

// ---------- sending ----------

/// What the app's icon shows: the chats with a dot in the chat list, muted
/// and hidden ones not counted, decided as the apps decide the dot
/// (Chats.swift, `Reader.status`; app.js, `chatStatus` and `groupStatus`). A
/// direct chat waits when its newest message is theirs and an unread text or
/// an unopened pic (a turned-off account's chat doesn't); a group waits with
/// an unread text, or when its newest message is someone else's pic you
/// haven't opened. Nothing from before an admin reset code counts (D14). One
/// thing only the app knows, a friend's changed safety code, takes that
/// chat's dot away there and not here.
pub async fn waiting_chats(db: &SqlitePool, user: i64) -> sqlx::Result<i64> {
    let mutes: Vec<Option<i64>> = sqlx::query_scalar(&format!(
        "SELECT {MUTED_FRIEND} FROM users u
          WHERE (u.id IN (SELECT CASE WHEN f.user_lo = ?1 THEN f.user_hi ELSE f.user_lo END
                            FROM friendships f WHERE (f.user_lo = ?1 OR f.user_hi = ?1) AND f.ended_at IS NULL)
                 OR EXISTS (SELECT 1 FROM system_accounts s WHERE s.user_id = u.id))
            AND NOT EXISTS (SELECT 1 FROM deactivations d WHERE d.user_id = u.id AND d.reactivated_at IS NULL)
            AND EXISTS (SELECT 1 FROM messages m
                         WHERE m.id = (SELECT MAX(x.id) FROM messages x
                                        WHERE (x.sender_id = ?1 AND x.recipient_id = u.id)
                                           OR (x.sender_id = u.id AND x.recipient_id = ?1))
                           AND m.sender_id = u.id
                           AND ((m.kind = 'text' AND m.read_at IS NULL) OR (m.kind = 'snap' AND m.snap_state = 'pending'))
                           AND m.created_at > {SINCE_MY_KEY}
                           AND NOT COALESCE({HIDDEN_UPTO} >= m.id, 0))
         UNION ALL
         SELECT {MUTED_GROUP} FROM group_members mem JOIN groups g ON g.id = mem.group_id
          WHERE mem.user_id = ?1 AND mem.left_at IS NULL
            AND (EXISTS (SELECT 1 FROM group_messages x
                          WHERE x.group_id = g.id AND x.id > mem.last_read_id AND x.kind = 'text'
                            AND x.sender_id != ?1 AND x.id > mem.visible_after_id
                            AND x.created_at > {SINCE_MY_KEY})
                 OR EXISTS (SELECT 1 FROM group_messages x JOIN group_pics p ON p.id = x.pic_id
                             WHERE x.id = (SELECT MAX(y.id) FROM group_messages y
                                            WHERE y.group_id = g.id AND y.id > mem.visible_after_id)
                               AND x.sender_id != ?1 AND p.discard_reason IS NULL
                               AND NOT EXISTS (SELECT 1 FROM group_pic_views v WHERE v.pic_id = p.id AND v.user_id = ?1)))"
    ))
    .bind(user)
    .fetch_all(db)
    .await?;
    let at = now();
    Ok(mutes
        .into_iter()
        .filter(|&raw| !crate::marks::muted(raw, at).0)
        .count() as i64)
}

/// The notification as Apple delivers it: the alert, the badge, and where
/// tapping it goes (`url`, as the web's), grouped and collapsed per chat by
/// an id keyed with the device's own token, so Apple can't tell chats apart
/// across devices.
fn payload(note: &Note, badge: i64, thread: &str) -> Value {
    json!({
        "aps": {
            "alert": { "title": note.title, "body": note.body },
            "sound": "default",
            "badge": badge,
            "thread-id": thread,
        },
        "url": note.url,
    })
}

/// A badge update: only the number. Nothing shows or sounds, and there's
/// nothing to tap.
fn badge_payload(badge: i64) -> Value {
    json!({ "aps": { "badge": badge } })
}

fn collapse_id(tag: &str, token: &str) -> String {
    crate::push::topic(tag, token.as_bytes())
}

/// (id, token, environment) of each iPhone `user` turned notifications on
/// in, for a session that's still signed in.
async fn devices(state: &SharedState, user: i64) -> sqlx::Result<Vec<(i64, String, String)>> {
    sqlx::query_as(
        "SELECT d.id, d.token, d.environment FROM apns_devices d
         JOIN sessions s ON s.token_hash = d.session_hash
         WHERE d.user_id = ? AND d.ended_at IS NULL AND s.revoked_at IS NULL AND s.expires_at > ?",
    )
    .bind(user)
    .bind(now())
    .fetch_all(&state.db)
    .await
}

/// One request to Apple, for one device.
struct Push {
    body: Value,
    /// When Apple stops trying (Unix seconds); 0 is now or never.
    expiration: i64,
    collapse: Option<String>,
}

/// Sends `push` to one device; true if Apple took it. A device Apple says is
/// gone ends here.
async fn send(
    state: &SharedState,
    apns: &Apns,
    user: i64,
    (id, token, environment): &(i64, String, String),
    push: Push,
) -> anyhow::Result<bool> {
    let Some(server) = server_for(environment, state.config.push_allow_local) else {
        return Ok(false);
    };
    let mut request = state
        .http
        .post(format!("{server}/3/device/{token}"))
        .header("authorization", apns.authorization(now()))
        .header("apns-topic", &apns.topic)
        // Notifications and badge updates alike: "alert" is Apple's type for
        // anything that shows, sounds, or badges. Both go at once (10), so an
        // older badge can't arrive after a newer notification and undo its number.
        .header("apns-push-type", "alert")
        .header("apns-priority", "10")
        .header("apns-expiration", push.expiration.to_string());
    if let Some(collapse) = push.collapse {
        request = request.header("apns-collapse-id", collapse);
    }
    match request.json(&push.body).send().await {
        Ok(r) if r.status().is_success() => Ok(true),
        Ok(r) => {
            let status = r.status().as_u16();
            // Apple says why: {"reason":"BadDeviceToken"}. It names the problem, never the message.
            let reason: String = r
                .json::<Value>()
                .await
                .ok()
                .and_then(|v| v["reason"].as_str().map(|s| s.chars().take(60).collect()))
                .unwrap_or_default();
            if status == 410 || (status == 400 && reason == "BadDeviceToken") {
                // The app was removed, or the token isn't for this server.
                sqlx::query(
                    "UPDATE apns_devices SET ended_at = ?, end_reason = 'gone'
                     WHERE id = ? AND ended_at IS NULL",
                )
                .bind(now())
                .bind(id)
                .execute(&state.db)
                .await?;
                tracing::info!(user_id = user, device_id = id, reason = ?reason, "apns device gone");
                return Ok(false);
            }
            if status == 403 {
                apns.forget_token();
            }
            tracing::warn!(user_id = user, device_id = id, status, reason = ?reason, "apns refused");
            Ok(false)
        }
        Err(e) => {
            tracing::warn!(user_id = user, device_id = id, error = %e, "apns send failed");
            Ok(false)
        }
    }
}

/// Sends `note` to every iPhone `user` turned notifications on in.
pub async fn deliver(state: &SharedState, user: i64, note: &Note) -> anyhow::Result<()> {
    let Some(apns) = &state.apns else {
        return Ok(());
    };
    let devices = devices(state, user).await?;
    if devices.is_empty() {
        return Ok(());
    }
    let badge = waiting_chats(&state.db, user).await?;
    let mut took = false;
    for device in &devices {
        let collapse = collapse_id(&note.tag, &device.1);
        let push = Push {
            body: payload(note, badge, &collapse),
            expiration: now() + EXPIRES_IN,
            collapse: Some(collapse),
        };
        if send(state, apns, user, device, push).await? {
            tracing::debug!(user_id = user, device_id = device.0, "apns sent");
            took = true;
        }
    }
    if took {
        apns.gave_badge(user, badge);
    }
    Ok(())
}

/// The number on `user`'s icon may have changed with no notification to carry
/// it: they read a chat or opened a pic (on the web, say), muted or hid a
/// chat, a message came while napsack was on their screen elsewhere, a group
/// event came, they left or were removed from a group, or a friend was
/// removed, turned off or on, or deleted their account. Their
/// iPhones get the new number on its own, with no alert and no sound: a moment
/// later (BADGE_DELAY), so a burst of changes makes one update, and only if it
/// isn't the number they were last given. Returns at once.
pub fn badge_changed(state: &SharedState, user: i64) {
    let Some(apns) = &state.apns else {
        return;
    };
    if !apns
        .updating
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(user)
    {
        return; // one is on its way, and counts this change too
    }
    let state = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(BADGE_DELAY).await;
        if let Some(apns) = &state.apns {
            // From here on, a new change waits for its own update.
            apns.updating
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&user);
        }
        if let Err(e) = update_badge(&state, user).await {
            tracing::warn!(user_id = user, error = %e, "apns badge update failed");
        }
    });
}

async fn update_badge(state: &SharedState, user: i64) -> anyhow::Result<()> {
    let Some(apns) = &state.apns else {
        return Ok(());
    };
    let devices = devices(state, user).await?;
    if devices.is_empty() {
        return Ok(());
    }
    let badge = waiting_chats(&state.db, user).await?;
    if !apns.badge_differs(user, badge) {
        return Ok(());
    }
    let mut took = false;
    for device in &devices {
        // Now or never: Apple keeps only one push per app for a phone that's
        // off, and a kept badge could take the place of a notification.
        let push = Push {
            body: badge_payload(badge),
            expiration: 0,
            collapse: None,
        };
        if send(state, apns, user, device, push).await? {
            tracing::debug!(
                user_id = user,
                device_id = device.0,
                badge,
                "apns badge sent"
            );
            took = true;
        }
    }
    if took {
        apns.gave_badge(user, badge);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::{
        ecdsa::{signature::Verifier, VerifyingKey},
        elliptic_curve::rand_core::OsRng,
        pkcs8::{EncodePrivateKey, LineEnding},
        SecretKey,
    };

    fn test_key() -> (String, VerifyingKey) {
        let secret = SecretKey::random(&mut OsRng);
        let pem = secret.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
        (pem, *SigningKey::from(&secret).verifying_key())
    }

    #[test]
    fn jwt_is_signed_by_the_team_key_and_reused_for_40_minutes() {
        let (pem, public) = test_key();
        let apns = Apns::new(&pem, "KEY123".into(), "TEAM456".into(), "com.x".into()).unwrap();
        let first = apns.authorization(1000);
        let token = first.strip_prefix("bearer ").unwrap();
        let mut parts = token.split('.');
        let (h, c, s) = (
            parts.next().unwrap(),
            parts.next().unwrap(),
            parts.next().unwrap(),
        );
        let header: Value = serde_json::from_slice(&B64URL.decode(h).unwrap()).unwrap();
        assert_eq!(header, json!({ "alg": "ES256", "kid": "KEY123" }));
        let claims: Value = serde_json::from_slice(&B64URL.decode(c).unwrap()).unwrap();
        assert_eq!(claims, json!({ "iss": "TEAM456", "iat": 1000 }));
        let sig = Signature::from_slice(&B64URL.decode(s).unwrap()).unwrap();
        assert!(public.verify(format!("{h}.{c}").as_bytes(), &sig).is_ok());

        assert_eq!(
            apns.authorization(1000 + TOKEN_LIFETIME - 1),
            first,
            "still fresh"
        );
        let later = apns.authorization(1000 + TOKEN_LIFETIME);
        assert_ne!(later, first, "a new one after 40 minutes");
        assert_eq!(apns.authorization(1000 + TOKEN_LIFETIME + 1), later);
        apns.forget_token();
        assert_ne!(
            apns.authorization(1000 + TOKEN_LIFETIME + 1),
            later,
            "and after a refusal"
        );
    }

    #[test]
    fn a_bad_key_is_refused_at_start() {
        assert!(Apns::new("not a key", "K".into(), "T".into(), "t".into()).is_err());
    }

    #[test]
    fn only_apples_servers_unless_testing() {
        assert_eq!(server_for("production", false).as_deref(), Some(PRODUCTION));
        assert_eq!(server_for("sandbox", false).as_deref(), Some(SANDBOX));
        for bad in [
            "",
            "Production",
            "https://evil.example",
            "http://127.0.0.1:9",
        ] {
            assert_eq!(server_for(bad, false), None, "{bad}");
        }
        assert_eq!(
            server_for("http://127.0.0.1:9", true).as_deref(),
            Some("http://127.0.0.1:9")
        );
        for bad in [
            "http://10.0.0.1:9",
            "https://127.0.0.1:9",
            "http://127.0.0.1:9/elsewhere",
            "http://169.254.169.254",
        ] {
            assert_eq!(server_for(bad, true), None, "{bad}");
        }
    }

    #[test]
    fn tokens_are_hex() {
        assert!(valid_token(&"ab".repeat(32)));
        assert!(
            !valid_token(&"AB".repeat(32)),
            "lowercase, as the app sends"
        );
        assert!(!valid_token("abc"));
        assert!(!valid_token(&"zz".repeat(32)));
        assert!(!valid_token(&"ab".repeat(32).replace('a', "/")));
        assert!(!valid_token(&"ab".repeat(101)));
    }

    #[test]
    fn the_chat_is_opaque_and_stable_per_device() {
        let (a, b) = ("ab".repeat(32), "cd".repeat(32));
        assert_eq!(collapse_id("dm-7", &a), collapse_id("dm-7", &a));
        assert_ne!(collapse_id("dm-7", &a), collapse_id("dm-7", &b));
        assert_ne!(collapse_id("dm-7", &a), collapse_id("dm-8", &a));
        assert!(collapse_id("dm-7", &a).len() <= 64);
        let p = payload(
            &Note {
                title: "Ana".into(),
                body: "New message".into(),
                tag: "dm-7".into(),
                url: "/#chat=7".into(),
            },
            3,
            "x",
        );
        assert_eq!(p["aps"]["alert"]["body"], "New message");
        assert_eq!(p["aps"]["thread-id"], "x");
        assert_eq!(p["aps"]["badge"], 3);
        assert_eq!(p["url"], "/#chat=7");
    }

    #[test]
    fn a_badge_update_is_only_the_number_and_goes_on_a_change() {
        assert_eq!(badge_payload(0), json!({ "aps": { "badge": 0 } }));
        assert_eq!(badge_payload(4), json!({ "aps": { "badge": 4 } }));
        let (pem, _) = test_key();
        let apns = Apns::new(&pem, "K".into(), "T".into(), "t".into()).unwrap();
        assert!(apns.badge_differs(7, 0), "nothing given yet: it goes");
        apns.gave_badge(7, 2);
        assert!(!apns.badge_differs(7, 2), "the same number again doesn't");
        assert!(apns.badge_differs(7, 1));
        assert!(apns.badge_differs(8, 2), "each person's own");
    }

    /// The icon counts the chats with a dot, as the apps draw them: one per
    /// chat however many messages, the newest message deciding a direct chat.
    #[tokio::test]
    async fn waiting_chats_counts_the_chats_with_a_dot() {
        let db = crate::db::tests::temp_db().await;
        let run = |sql: &'static str| sqlx::raw_sql(sql).execute(&db);
        // 1 is me; 2 ana, 3 ben, 5 dee (turned off), 6 eve: friends; 4 cat isn't; 7 is Team Napsack.
        run("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES
               (1, 'me', 'h', 'k', 'w', 1), (2, 'ana', 'h', 'k', 'w', 1), (3, 'ben', 'h', 'k', 'w', 1),
               (4, 'cat', 'h', 'k', 'w', 1), (5, 'dee', 'h', 'k', 'w', 1), (6, 'eve', 'h', 'k', 'w', 1),
               (7, 'team', 'h', 'k', 'w', 1);
             INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (1, 2, 1), (1, 3, 1), (1, 5, 1), (1, 6, 1);
             INSERT INTO system_accounts (user_id, kind, created_at) VALUES (7, 'team', 1);
             INSERT INTO deactivations (user_id, deactivated_by, deactivated_at) VALUES (5, 1, 1);
             INSERT INTO messages (id, sender_id, recipient_id, kind, ciphertext, created_at) VALUES
               (1, 2, 1, 'text', 'c', 1), (2, 2, 1, 'text', 'c', 1), (3, 2, 1, 'text', 'c', 1),
               (4, 3, 1, 'text', 'c', 1), (5, 1, 3, 'text', 'c', 1),
               (6, 4, 1, 'text', 'c', 1), (7, 5, 1, 'text', 'c', 1), (8, 7, 1, 'text', 'c', 1);
             INSERT INTO messages (id, sender_id, recipient_id, kind, snap_state, created_at) VALUES (9, 6, 1, 'snap', 'pending', 1);
             INSERT INTO messages (id, sender_id, recipient_id, kind, ciphertext, created_at, read_at) VALUES (10, 6, 1, 'text', 'c', 1, 2);")
            .await
            .unwrap();
        let count = || waiting_chats(&db, 1);
        // Ana's three texts are one chat; ben's newest is my answer; cat isn't a
        // friend; dee's account is off; eve's newest is a read text (her pic
        // before it doesn't show in the list); Team Napsack counts.
        assert_eq!(count().await.unwrap(), 2, "ana and Team Napsack");

        run("INSERT INTO chat_marks (user_id, friend_id, kind, value, upto_id, created_at) VALUES (1, 2, 'hidden', 1, 3, 1)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 1, "a hidden chat isn't counted");
        run("INSERT INTO messages (id, sender_id, recipient_id, kind, ciphertext, created_at) VALUES (11, 2, 1, 'text', 'c', 1)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 2, "a new message brings it back");
        run("INSERT INTO chat_mutes (user_id, friend_id, value, created_at) VALUES (1, 7, 1, 1)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 1, "a muted chat isn't counted");
        run("INSERT INTO messages (id, sender_id, recipient_id, kind, snap_state, created_at) VALUES (12, 3, 1, 'snap', 'pending', 1)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 2, "an unopened pic from ben");
        run("UPDATE messages SET snap_state = 'opened' WHERE id = 12")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 1, "opened");

        // A group: unread texts from others count, then its newest pic until I open it.
        run("INSERT INTO groups (id, name, created_by, created_at) VALUES (20, 'g', 2, 1);
             INSERT INTO group_members (group_id, user_id, role, joined_at) VALUES (20, 2, 'owner', 1), (20, 1, 'member', 1);
             INSERT INTO group_messages (id, group_id, sender_id, kind, body, created_at) VALUES (30, 20, 1, 'text', 'mine', 1)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 1, "my own message doesn't wait");
        run("INSERT INTO group_messages (id, group_id, sender_id, kind, body, created_at) VALUES (31, 20, 2, 'text', 'hi', 1)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 2, "ana's group text");
        run("INSERT INTO group_pics (id, group_id, sender_id, bytes, mime, created_at, expires_at) VALUES (40, 20, 2, 9, 'image/jpeg', 1, 9999999999);
             INSERT INTO group_messages (id, group_id, sender_id, kind, body, created_at, pic_id) VALUES (32, 20, 2, 'text', '', 1, 40);
             UPDATE group_members SET last_read_id = 32 WHERE group_id = 20 AND user_id = 1")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 2, "read, but her pic is unopened");
        run("INSERT INTO group_pic_views (pic_id, user_id, viewed_at) VALUES (40, 1, 2)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 1, "opened");
        run("INSERT INTO group_messages (id, group_id, sender_id, kind, body, created_at) VALUES (33, 20, 2, 'text', 'more', 1)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 2);
        run("INSERT INTO chat_mutes (user_id, group_id, value, created_at) VALUES (1, 20, 1, 1)")
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), 1, "a muted group isn't counted");
        run(
            "INSERT INTO chat_mutes (user_id, group_id, value, created_at) VALUES (1, 20, 0, 2);
             UPDATE group_members SET left_at = 3 WHERE group_id = 20 AND user_id = 1",
        )
        .await
        .unwrap();
        assert_eq!(count().await.unwrap(), 1, "a group I left isn't counted");
        run("UPDATE users SET key_reset_at = 1 WHERE id = 1")
            .await
            .unwrap();
        assert_eq!(
            count().await.unwrap(),
            0,
            "nothing from before an admin reset code (D14)"
        );
    }
}
