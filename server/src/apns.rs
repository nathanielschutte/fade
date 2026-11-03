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

use std::sync::LazyLock;

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

pub struct Apns {
    key: SigningKey,
    key_id: String,
    team_id: String,
    /// The app's bundle id, the `apns-topic` of every request.
    topic: String,
    token: std::sync::Mutex<Option<(i64, String)>>,
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
        })
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

/// The chats with something waiting for `?1`, as tags: the people with an
/// unread text or unopened pic (read through messages_waiting, so the badge
/// never reads a whole chat's history), then the groups with an unread text.
static WAITING: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT 'dm-' || m.sender_id FROM messages m
              WHERE m.recipient_id = ?1
                AND ((m.kind = 'text' AND m.read_at IS NULL) OR (m.kind = 'snap' AND m.snap_state = 'pending'))
                AND m.created_at > {SINCE_MY_KEY}
                AND (EXISTS (SELECT 1 FROM friendships f WHERE f.ended_at IS NULL
                              AND ((f.user_lo = ?1 AND f.user_hi = m.sender_id) OR (f.user_hi = ?1 AND f.user_lo = m.sender_id)))
                     OR EXISTS (SELECT 1 FROM system_accounts s WHERE s.user_id = m.sender_id))
              GROUP BY m.sender_id
             UNION ALL
             SELECT 'group-' || g.group_id FROM group_members g
              WHERE g.user_id = ?1 AND g.left_at IS NULL
                AND EXISTS (SELECT 1 FROM group_messages gm
                             WHERE gm.group_id = g.group_id AND gm.id > g.last_read_id AND gm.kind = 'text'
                               AND gm.sender_id != ?1 AND gm.id > g.visible_after_id
                               AND gm.created_at > {SINCE_MY_KEY})"
    )
});

/// What the app's icon shows: chats with something waiting, muted ones not
/// counted, as the app's Chats tab counts them.
pub async fn waiting_chats(db: &SqlitePool, user: i64) -> sqlx::Result<i64> {
    let tags: Vec<String> = sqlx::query_scalar(&WAITING)
        .bind(user)
        .fetch_all(db)
        .await?;
    let mut count = 0;
    for tag in tags {
        if !crate::marks::muted_for_tag(db, user, &tag).await? {
            count += 1;
        }
    }
    Ok(count)
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

fn collapse_id(tag: &str, token: &str) -> String {
    crate::push::topic(tag, token.as_bytes())
}

/// Sends `note` to every iPhone `user` turned notifications on in.
pub async fn deliver(state: &SharedState, user: i64, note: &Note) -> anyhow::Result<()> {
    let Some(apns) = &state.apns else {
        return Ok(());
    };
    let devices: Vec<(i64, String, String)> = sqlx::query_as(
        "SELECT d.id, d.token, d.environment FROM apns_devices d
         JOIN sessions s ON s.token_hash = d.session_hash
         WHERE d.user_id = ? AND d.ended_at IS NULL AND s.revoked_at IS NULL AND s.expires_at > ?",
    )
    .bind(user)
    .bind(now())
    .fetch_all(&state.db)
    .await?;
    if devices.is_empty() {
        return Ok(());
    }
    let badge = waiting_chats(&state.db, user).await?;
    for (id, token, environment) in devices {
        let Some(server) = server_for(&environment, state.config.push_allow_local) else {
            continue;
        };
        let collapse = collapse_id(&note.tag, &token);
        let body = payload(note, badge, &collapse);
        let sent = state
            .http
            .post(format!("{server}/3/device/{token}"))
            .header("authorization", apns.authorization(now()))
            .header("apns-topic", &apns.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .header("apns-expiration", (now() + EXPIRES_IN).to_string())
            .header("apns-collapse-id", collapse)
            .json(&body)
            .send()
            .await;
        match sent {
            Ok(r) if r.status().is_success() => {
                tracing::debug!(user_id = user, device_id = id, "apns sent");
            }
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
                    continue;
                }
                if status == 403 {
                    apns.forget_token();
                }
                tracing::warn!(user_id = user, device_id = id, status, reason = ?reason, "apns refused");
            }
            Err(e) => {
                tracing::warn!(user_id = user, device_id = id, error = %e, "apns send failed")
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::{assert_searches, plan, temp_db};
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

    #[tokio::test]
    async fn waiting_chats_counts_chats_not_messages_and_skips_muted() {
        let db = crate::db::tests::temp_db().await;
        let t = now();
        for (id, name) in [(1, "me"), (2, "ana"), (3, "ben"), (4, "cat")] {
            sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (?, ?, 'h', 'k', 'w', ?)")
                .bind(id).bind(name).bind(t).execute(&db).await.unwrap();
        }
        for friend in [2, 3] {
            sqlx::query("INSERT INTO friendships (user_lo, user_hi, created_at) VALUES (1, ?, ?)")
                .bind(friend)
                .bind(t)
                .execute(&db)
                .await
                .unwrap();
        }
        let text = |from: i64| {
            sqlx::query("INSERT INTO messages (sender_id, recipient_id, kind, ciphertext, created_at) VALUES (?, 1, 'text', 'c', ?)")
                .bind(from).bind(t)
        };
        for from in [2, 2, 2, 3, 4] {
            text(from).execute(&db).await.unwrap();
        }
        assert_eq!(
            waiting_chats(&db, 1).await.unwrap(),
            2,
            "ana and ben; cat isn't a friend"
        );
        sqlx::query(
            "INSERT INTO chat_mutes (user_id, friend_id, value, created_at) VALUES (1, 3, 1, ?)",
        )
        .bind(t)
        .execute(&db)
        .await
        .unwrap();
        assert_eq!(waiting_chats(&db, 1).await.unwrap(), 1, "ben is muted");
    }

    /// The badge reads what's waiting through messages_waiting, never a
    /// whole chat's history or every message.
    #[tokio::test]
    async fn the_badge_reads_whats_waiting() {
        let db = temp_db().await;
        assert_searches(&db, &WAITING, &[], &[]).await;
        let steps = plan(&db, &WAITING).await;
        assert!(
            steps.iter().any(|s| s.contains("INDEX messages_waiting")),
            "{steps:#?}"
        );
    }
}
