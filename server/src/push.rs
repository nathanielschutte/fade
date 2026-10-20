//! Push notifications (F10), with the standard Web Push protocol: the browser
//! gives us an endpoint at its push service (Google, Apple, Mozilla,
//! Microsoft) and a public key; we encrypt each notification to that key
//! (RFC 8291) and sign the request with our VAPID key (RFC 8292). The push
//! service only ever sees ciphertext.
//!
//! What a notification says: who, never what. "New message from Ana". The
//! server can't read direct messages anyway; group notifications follow the
//! same rule, so group encryption later changes nothing.
//!
//! No push while napsack is on screen for that person (a visible socket):
//! the app already shows it.

use axum::{extract::State, http::HeaderMap, Json};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64URL, Engine};
use p256::{
    ecdsa::{signature::Signer, Signature, SigningKey},
    elliptic_curve::{rand_core::OsRng, sec1::ToEncodedPoint},
    PublicKey, SecretKey,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use sqlx::SqlitePool;

use crate::{
    auth::{bearer_token, hash_token, AuthUser},
    db::now,
    error::{AppError, AppResult},
    SharedState,
};

/// Push services we'll send to. The endpoint comes from the browser, so it's
/// untrusted: without this list, anyone could make the server send requests
/// anywhere (including to addresses inside AWS).
const PUSH_HOSTS: &[&str] = &[
    "fcm.googleapis.com",        // Chrome, Android, Edge on some platforms
    "push.apple.com",            // Safari, iPhone home-screen apps (web.push.apple.com)
    "push.services.mozilla.com", // Firefox (updates.push.services.mozilla.com)
    "notify.windows.com",        // Edge on Windows
];
/// Active subscriptions per person (phone, laptop, ...). Past this, the oldest ends.
const MAX_SUBSCRIPTIONS: i64 = 10;
/// Push services keep an undelivered notification this long (seconds).
const TTL: &str = "86400";
/// RFC 8291 record size; notifications are far smaller.
const RECORD_SIZE: u32 = 4096;

// ---------- VAPID ----------

pub struct Vapid {
    key: SigningKey,
    /// Uncompressed P-256 public key, base64url: the browser's `applicationServerKey`.
    pub public: String,
}

impl Vapid {
    fn from_secret(secret: &SecretKey) -> Self {
        Self {
            key: SigningKey::from(secret),
            public: B64URL.encode(secret.public_key().to_encoded_point(false).as_bytes()),
        }
    }

    /// `Authorization: vapid t=<JWT>, k=<public key>`, valid for 12 hours, for
    /// one push service (the JWT's audience is the endpoint's origin).
    fn authorization(&self, endpoint: &reqwest::Url, contact: &str, at: i64) -> String {
        let header = B64URL.encode(br#"{"typ":"JWT","alg":"ES256"}"#);
        let claims = B64URL.encode(
            json!({
                "aud": endpoint.origin().ascii_serialization(),
                "exp": at + 12 * 3600,
                "sub": contact,
            })
            .to_string(),
        );
        let input = format!("{header}.{claims}");
        let sig: Signature = self.key.sign(input.as_bytes());
        format!(
            "vapid t={input}.{}, k={}",
            B64URL.encode(sig.to_bytes()),
            self.public
        )
    }
}

/// The server's VAPID key, made on first start and kept in the database (so
/// it survives instance replacement, and browsers' subscriptions stay valid).
pub async fn load_vapid(db: &SqlitePool) -> anyhow::Result<Vapid> {
    let stored: Option<String> =
        sqlx::query_scalar("SELECT value FROM server_keys WHERE name = 'vapid_private'")
            .fetch_optional(db)
            .await?;
    if let Some(v) = stored {
        return Ok(Vapid::from_secret(&SecretKey::from_slice(
            &B64URL.decode(v)?,
        )?));
    }
    let secret = SecretKey::random(&mut OsRng);
    sqlx::query("INSERT OR IGNORE INTO server_keys (name, value, created_at) VALUES ('vapid_private', ?, ?)")
        .bind(B64URL.encode(secret.to_bytes()))
        .bind(now())
        .execute(db)
        .await?;
    tracing::info!("made the web push signing key");
    Box::pin(load_vapid(db)).await
}

// ---------- RFC 8291 encryption ----------

/// Encrypts `payload` for one browser: `ua_public` (its 65-byte P-256 key) and
/// `auth` (its 16-byte secret). `as_secret` and `salt` are fresh per message;
/// they're parameters so the RFC's worked example can be checked exactly.
fn encrypt(
    payload: &[u8],
    ua_public: &[u8],
    auth: &[u8],
    as_secret: &SecretKey,
    salt: [u8; 16],
) -> Result<Vec<u8>, String> {
    use aes_gcm::{aead::Aead, Aes128Gcm, KeyInit, Nonce};
    use hkdf::Hkdf;

    let ua = PublicKey::from_sec1_bytes(ua_public).map_err(|_| "bad browser key")?;
    let as_public = as_secret.public_key().to_encoded_point(false);
    let shared = p256::ecdh::diffie_hellman(as_secret.to_nonzero_scalar(), ua.as_affine());

    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(ua_public);
    key_info.extend_from_slice(as_public.as_bytes());
    let mut ikm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(auth), shared.raw_secret_bytes())
        .expand(&key_info, &mut ikm)
        .map_err(|_| "hkdf")?;
    let prk = Hkdf::<Sha256>::new(Some(&salt), &ikm);
    let mut cek = [0u8; 16];
    let mut nonce = [0u8; 12];
    prk.expand(b"Content-Encoding: aes128gcm\0", &mut cek)
        .map_err(|_| "hkdf")?;
    prk.expand(b"Content-Encoding: nonce\0", &mut nonce)
        .map_err(|_| "hkdf")?;

    let mut plain = payload.to_vec();
    plain.push(2); // last (only) record, no padding
    let ciphertext = Aes128Gcm::new_from_slice(&cek)
        .map_err(|_| "aes")?
        .encrypt(Nonce::from_slice(&nonce), plain.as_slice())
        .map_err(|_| "aes")?;

    let mut body = Vec::with_capacity(86 + ciphertext.len());
    body.extend_from_slice(&salt);
    body.extend_from_slice(&RECORD_SIZE.to_be_bytes());
    body.push(as_public.as_bytes().len() as u8);
    body.extend_from_slice(as_public.as_bytes());
    body.extend_from_slice(&ciphertext);
    Ok(body)
}

// ---------- subscriptions ----------

/// https, on a known push service's host (or a local test receiver, when
/// `FADE_PUSH_ALLOW_LOCAL` is set for the test suite).
fn allowed_endpoint(endpoint: &str, allow_local: bool) -> Option<reqwest::Url> {
    if endpoint.len() > 1024 {
        return None;
    }
    let url = reqwest::Url::parse(endpoint).ok()?;
    let host = url.host_str()?;
    let ok = match url.scheme() {
        "https" => {
            url.port().is_none()
                && PUSH_HOSTS
                    .iter()
                    .any(|h| host == *h || host.ends_with(&format!(".{h}")))
        }
        "http" => allow_local && host == "127.0.0.1",
        _ => false,
    };
    ok.then_some(url)
}

#[derive(Deserialize)]
pub struct SubscriptionKeys {
    p256dh: String,
    auth: String,
}

/// The shape of the browser's `PushSubscription.toJSON()`.
#[derive(Deserialize)]
pub struct Subscribe {
    endpoint: String,
    keys: SubscriptionKeys,
}

fn session_of(headers: &HeaderMap) -> AppResult<String> {
    bearer_token(headers)
        .map(hash_token)
        .ok_or(AppError::Unauthorized)
}

/// `POST /api/push/subscriptions`: this browser wants notifications, for this
/// session. Sending the same endpoint again (after signing in again) replaces it.
pub async fn subscribe(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    headers: HeaderMap,
    Json(req): Json<Subscribe>,
) -> AppResult<Json<Value>> {
    if allowed_endpoint(&req.endpoint, state.config.push_allow_local).is_none() {
        tracing::info!(
            user_id = me.id,
            "push subscription refused: endpoint not a known push service"
        );
        return Err(AppError::bad(
            "This browser's notification service isn't supported.",
        ));
    }
    let key_ok = B64URL
        .decode(req.keys.p256dh.trim_end_matches('='))
        .ok()
        .is_some_and(|k| k.len() == 65 && PublicKey::from_sec1_bytes(&k).is_ok());
    let auth_ok = B64URL
        .decode(req.keys.auth.trim_end_matches('='))
        .is_ok_and(|a| a.len() == 16);
    if !key_ok || !auth_ok {
        return Err(AppError::bad(
            "That notification subscription was malformed.",
        ));
    }
    let session = session_of(&headers)?;
    let at = now();
    let mut tx = state.db.begin().await?;
    sqlx::query(
        "UPDATE push_subscriptions SET ended_at = ?, end_reason = 'replaced'
         WHERE endpoint = ? AND ended_at IS NULL",
    )
    .bind(at)
    .bind(&req.endpoint)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO push_subscriptions (user_id, session_hash, endpoint, p256dh, auth, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(me.id)
    .bind(&session)
    .bind(&req.endpoint)
    .bind(req.keys.p256dh.trim_end_matches('='))
    .bind(req.keys.auth.trim_end_matches('='))
    .bind(at)
    .execute(&mut *tx)
    .await?;
    // Keep the newest few.
    sqlx::query(
        "UPDATE push_subscriptions SET ended_at = ?, end_reason = 'replaced'
         WHERE user_id = ? AND ended_at IS NULL AND id NOT IN (
           SELECT id FROM push_subscriptions WHERE user_id = ? AND ended_at IS NULL
           ORDER BY id DESC LIMIT ?)",
    )
    .bind(at)
    .bind(me.id)
    .bind(me.id)
    .bind(MAX_SUBSCRIPTIONS)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    tracing::info!(user_id = me.id, "notifications turned on");
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct Unsubscribe {
    endpoint: String,
}

/// `POST /api/push/subscriptions/remove`: turned off in this browser.
pub async fn unsubscribe(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<Unsubscribe>,
) -> AppResult<Json<Value>> {
    let ended = sqlx::query(
        "UPDATE push_subscriptions SET ended_at = ?, end_reason = 'turned_off'
         WHERE user_id = ? AND endpoint = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(me.id)
    .bind(&req.endpoint)
    .execute(&state.db)
    .await?
    .rows_affected();
    tracing::info!(user_id = me.id, ended, "notifications turned off");
    Ok(Json(json!({ "ended": ended })))
}

/// Signing out ends that session's notifications.
pub async fn end_for_session(db: &SqlitePool, session_hash: &str) -> sqlx::Result<()> {
    sqlx::query(
        "UPDATE push_subscriptions SET ended_at = ?, end_reason = 'signed_out'
         WHERE session_hash = ? AND ended_at IS NULL",
    )
    .bind(now())
    .bind(session_hash)
    .execute(db)
    .await?;
    Ok(())
}

// ---------- sending ----------

/// One notification, as the service worker shows it (server/static/sw.js).
#[derive(Serialize, Debug, Clone)]
pub struct Note {
    pub title: String,
    pub body: String,
    /// Notifications with the same tag replace each other (one per chat).
    pub tag: String,
    /// Where tapping it goes, e.g. `/#chat=7`.
    pub url: String,
}

/// Sends `note` to every browser `user` turned notifications on in, unless
/// napsack is on their screen right now. Returns at once; delivery happens
/// in the background.
pub fn notify(state: &SharedState, user: i64, note: Note) {
    if state.hub.is_visible(user) {
        return;
    }
    let state = state.clone();
    tokio::spawn(async move {
        if let Err(e) = deliver(&state, user, &note).await {
            tracing::warn!(user_id = user, error = %e, "push delivery failed");
        }
    });
}

/// Push services accept a short topic so a newer notification replaces an
/// undelivered one: base64url characters, at most 32.
fn topic(tag: &str) -> String {
    tag.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(32)
        .collect()
}

async fn deliver(state: &SharedState, user: i64, note: &Note) -> anyhow::Result<()> {
    let subs: Vec<(i64, String, String, String)> = sqlx::query_as(
        "SELECT p.id, p.endpoint, p.p256dh, p.auth FROM push_subscriptions p
         JOIN sessions s ON s.token_hash = p.session_hash
         WHERE p.user_id = ? AND p.ended_at IS NULL AND s.revoked_at IS NULL AND s.expires_at > ?",
    )
    .bind(user)
    .bind(now())
    .fetch_all(&state.db)
    .await?;
    let payload = serde_json::to_vec(note)?;
    for (id, endpoint, p256dh, auth) in subs {
        let Some(url) = allowed_endpoint(&endpoint, state.config.push_allow_local) else {
            continue;
        };
        let mut salt = [0u8; 16];
        rand::rngs::OsRng.fill_bytes(&mut salt);
        let body = encrypt(
            &payload,
            &B64URL.decode(&p256dh)?,
            &B64URL.decode(&auth)?,
            &SecretKey::random(&mut OsRng),
            salt,
        )
        .map_err(|e| anyhow::anyhow!("encrypting: {e}"))?;
        let auth_header = state
            .vapid
            .authorization(&url, &state.config.public_url, now());
        let sent = state
            .http
            .post(url)
            .header("TTL", TTL)
            .header("Urgency", "high")
            .header("Topic", topic(&note.tag))
            .header("Content-Encoding", "aes128gcm")
            .header("Content-Type", "application/octet-stream")
            .header("Authorization", auth_header)
            .body(body)
            .send()
            .await;
        match sent {
            Ok(r) if r.status().is_success() => {
                tracing::debug!(user_id = user, subscription_id = id, "push sent");
            }
            Ok(r) if matches!(r.status().as_u16(), 404 | 410) => {
                // The browser unsubscribed or the subscription expired.
                sqlx::query(
                    "UPDATE push_subscriptions SET ended_at = ?, end_reason = 'gone'
                     WHERE id = ? AND ended_at IS NULL",
                )
                .bind(now())
                .bind(id)
                .execute(&state.db)
                .await?;
                tracing::info!(
                    user_id = user,
                    subscription_id = id,
                    "push subscription gone"
                );
            }
            Ok(r) => tracing::warn!(
                user_id = user,
                subscription_id = id,
                status = r.status().as_u16(),
                "push refused"
            ),
            Err(e) => {
                tracing::warn!(user_id = user, subscription_id = id, error = %e, "push send failed")
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b64(s: &str) -> Vec<u8> {
        B64URL.decode(s).unwrap()
    }

    /// RFC 8291, Appendix A: the worked example, byte for byte.
    #[test]
    fn encrypts_exactly_like_the_rfc_example() {
        let as_secret =
            SecretKey::from_slice(&b64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")).unwrap();
        assert_eq!(
            B64URL.encode(as_secret.public_key().to_encoded_point(false).as_bytes()),
            "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
        );
        let salt: [u8; 16] = b64("DGv6ra1nlYgDCS1FRnbzlw").try_into().unwrap();
        let body = encrypt(
            &b64("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24"),
            &b64("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"),
            &b64("BTBZMqHH6r4Tts7J_aSIgg"),
            &as_secret,
            salt,
        )
        .unwrap();
        // The RFC prints the 86-byte header and the ciphertext as separate base64 strings.
        assert_eq!(
            body[..86],
            b64("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")
        );
        assert_eq!(
            body[86..],
            b64("8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ")
        );
    }

    #[test]
    fn vapid_jwt_is_signed_and_scoped_to_the_push_service() {
        use p256::ecdsa::{signature::Verifier, VerifyingKey};
        let vapid = Vapid::from_secret(&SecretKey::random(&mut OsRng));
        let url = reqwest::Url::parse("https://fcm.googleapis.com/fcm/send/abc").unwrap();
        let header = vapid.authorization(&url, "https://napsack.example", 1000);
        let (t, k) = header
            .strip_prefix("vapid t=")
            .unwrap()
            .split_once(", k=")
            .unwrap();
        assert_eq!(k, vapid.public);
        let (input, sig) = t.rsplit_once('.').unwrap();
        let claims: Value = serde_json::from_slice(&b64(input.split_once('.').unwrap().1)).unwrap();
        assert_eq!(claims["aud"], "https://fcm.googleapis.com");
        assert_eq!(claims["exp"], 1000 + 12 * 3600);
        assert_eq!(claims["sub"], "https://napsack.example");
        let key = VerifyingKey::from_sec1_bytes(&b64(k)).unwrap();
        let sig = Signature::from_slice(&b64(sig)).unwrap();
        assert!(key.verify(input.as_bytes(), &sig).is_ok());
    }

    #[test]
    fn only_known_push_services() {
        for ok in [
            "https://fcm.googleapis.com/fcm/send/x",
            "https://web.push.apple.com/QGx",
            "https://updates.push.services.mozilla.com/wpush/v2/x",
            "https://wns2-by3p.notify.windows.com/w/?token=x",
        ] {
            assert!(allowed_endpoint(ok, false).is_some(), "{ok}");
        }
        for bad in [
            "http://fcm.googleapis.com/x",       // not https
            "https://fcm.googleapis.com:8443/x", // odd port
            "https://evilfcm.googleapis.com.attacker.io/x",
            "https://notfcm.googleapis.com.evil/x",
            "https://169.254.169.254/latest/meta-data", // AWS metadata
            "https://localhost/x",
            "http://127.0.0.1:9/x", // only in tests
            "file:///etc/passwd",
            "not a url",
        ] {
            assert!(allowed_endpoint(bad, false).is_none(), "{bad}");
        }
        assert!(allowed_endpoint("http://127.0.0.1:9/x", true).is_some());
        assert!(allowed_endpoint("http://10.0.0.1:9/x", true).is_none());
        assert_eq!(topic("dm-7 & more!"), "dm-7more");
    }
}
