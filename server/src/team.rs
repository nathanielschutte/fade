//! Team Napsack (docs/implementation/team-napsack.md): an account the server
//! itself speaks for, which can message anyone without being their friend.
//! Its messages are for occasions (birthdays, holidays; occasions.rs).
//!
//! It's an ordinary account to the apps, so its messages are end-to-end
//! encrypted like any text (format 2): the server holds Team Napsack's
//! private key, works out the same pair key the recipient's app does (ECDH
//! with their public key, then HKDF; shared/crypto/crypto.js `pairKey`),
//! and seals the text. The server writes these messages, so it knows what
//! they say; it still can't read anyone else's. The key is made once and
//! never replaced: a new one would show everyone a changed safety code.
//!
//! It never signs in (auth.rs refuses it) and can't be messaged back: its
//! chat is read-only for the recipient.

use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use hkdf::Hkdf;
use p256::{
    pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey, EncodePublicKey},
    PublicKey, SecretKey,
};
use serde_json::json;
use sha2::Sha256;
use sqlx::SqlitePool;

use crate::{
    db::{now, MESSAGE_COLS},
    ws::Event,
    SharedState,
};

/// Its username, if free; the display name everyone sees.
const USERNAME: &str = "napsack";
const FALLBACK_USERNAME: &str = "team.napsack";
pub const NAME: &str = "Team Napsack";
const KEY_NAME: &str = "team_napsack_key";

/// Team Napsack's user id, if it exists yet.
pub async fn id(db: &SqlitePool) -> sqlx::Result<Option<i64>> {
    sqlx::query_scalar("SELECT user_id FROM system_accounts WHERE kind = 'team'")
        .fetch_optional(db)
        .await
}

/// Whether `user` is an account the server speaks for (it never signs in).
pub async fn is_system(db: &SqlitePool, user: i64) -> sqlx::Result<bool> {
    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM system_accounts WHERE user_id = ?)")
        .bind(user)
        .fetch_one(db)
        .await
}

/// Makes Team Napsack at startup if it isn't there: its key pair, its
/// account, and its display name. Returns its id.
pub async fn ensure(db: &SqlitePool) -> anyhow::Result<i64> {
    if let Some(id) = id(db).await? {
        return Ok(id);
    }
    let secret = SecretKey::random(&mut rand::rngs::OsRng);
    let pkcs8 = secret.to_pkcs8_der()?;
    sqlx::query("INSERT OR IGNORE INTO server_keys (name, value, created_at) VALUES (?, ?, ?)")
        .bind(KEY_NAME)
        .bind(B64.encode(pkcs8.as_bytes()))
        .bind(now())
        .execute(db)
        .await?;
    // (If a key was already stored, that's the one: it never changes.)
    let secret = key(db).await?;
    let spki = B64.encode(secret.public_key().to_public_key_der()?.as_bytes());
    let taken: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE lower(username) = ?)")
            .bind(USERNAME)
            .fetch_one(db)
            .await?;
    let username = if taken { FALLBACK_USERNAME } else { USERNAME };
    // Nobody can sign in as it: the stored hash is of a key nobody has, and
    // auth.rs refuses system accounts anyway.
    let unusable = crate::auth::hash_secret(B64.encode(rand::random::<[u8; 32]>()))
        .await
        .map_err(|_| anyhow::anyhow!("hashing failed"))?;
    let mut tx = db.begin().await?;
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO users (username, auth_hash, public_key, wrapped_private_key, created_at)
         VALUES (?, ?, ?, '', ?) RETURNING id",
    )
    .bind(username)
    .bind(unusable)
    .bind(&spki)
    .bind(now())
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query("INSERT INTO system_accounts (user_id, kind, created_at) VALUES (?, 'team', ?)")
        .bind(id)
        .bind(now())
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO user_names (user_id, set_by, name, created_at) VALUES (?, ?, ?, ?)")
        .bind(id)
        .bind(id)
        .bind(NAME)
        .bind(now())
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    tracing::info!(user_id = id, username, "team napsack account created");
    Ok(id)
}

async fn key(db: &SqlitePool) -> anyhow::Result<SecretKey> {
    let stored: String = sqlx::query_scalar("SELECT value FROM server_keys WHERE name = ?")
        .bind(KEY_NAME)
        .fetch_one(db)
        .await?;
    Ok(SecretKey::from_pkcs8_der(&B64.decode(stored)?)?)
}

/// The key two people share for their chat, exactly as crypto.js `pairKey`
/// derives it: ECDH, then HKDF-SHA-256 with the sorted ids as salt.
pub fn pair_key(
    mine: &SecretKey,
    their_spki_b64: &str,
    my_id: i64,
    their_id: i64,
) -> anyhow::Result<[u8; 32]> {
    let theirs = PublicKey::from_public_key_der(&B64.decode(their_spki_b64)?)?;
    let shared = p256::ecdh::diffie_hellman(mine.to_nonzero_scalar(), theirs.as_affine());
    let (lo, hi) = (my_id.min(their_id), my_id.max(their_id));
    let salt = format!("napsack/v1/pair/{lo}/{hi}");
    let mut key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(salt.as_bytes()), shared.raw_secret_bytes())
        .expand(b"napsack/v1/messages", &mut key)
        .map_err(|_| anyhow::anyhow!("hkdf"))?;
    Ok(key)
}

/// A format 2 text, as crypto.js `encryptText2` makes it: the JSON envelope
/// sealed with AES-256-GCM, a fresh IV first, the sender and recipient bound in.
pub fn seal_text(
    key: &[u8; 32],
    text: &str,
    sender: i64,
    recipient: i64,
) -> anyhow::Result<String> {
    let iv: [u8; 12] = rand::random();
    let aad = format!("napsack/v2/text/{sender}/{recipient}");
    let body = serde_json::to_vec(&json!({ "t": text }))?;
    let sealed = Aes256Gcm::new(key.into())
        .encrypt(
            (&iv).into(),
            Payload {
                msg: &body,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| anyhow::anyhow!("aes-gcm"))?;
    Ok(B64.encode([iv.as_slice(), &sealed].concat()))
}

/// Sends `text` from Team Napsack to `user`: stored like any text, delivered
/// live, and a notification ("Team Napsack: New message"). Returns the message id.
pub async fn send(state: &SharedState, user: i64, text: &str) -> anyhow::Result<i64> {
    let db = &state.db;
    let team = id(db)
        .await?
        .ok_or_else(|| anyhow::anyhow!("no team napsack account"))?;
    let their_key: String = sqlx::query_scalar("SELECT public_key FROM users WHERE id = ?")
        .bind(user)
        .fetch_one(db)
        .await?;
    let key = pair_key(&key(db).await?, &their_key, team, user)?;
    let ciphertext = seal_text(&key, text, team, user)?;
    let message = sqlx::query_as::<_, crate::db::Message>(&format!(
        "INSERT INTO messages (sender_id, recipient_id, kind, ciphertext, format, created_at)
         VALUES (?, ?, 'text', ?, 2, ?) RETURNING {MESSAGE_COLS}"
    ))
    .bind(team)
    .bind(user)
    .bind(&ciphertext)
    .bind(now())
    .fetch_one(db)
    .await?;
    // Its chat appears in their list (friends_changed), then the message itself.
    state.hub.send(user, &Event::FriendsChanged);
    state.hub.send(
        user,
        &Event::Message {
            message: message.clone(),
        },
    );
    crate::push::notify(
        state,
        user,
        crate::push::Note {
            title: NAME.into(),
            body: "New message".into(),
            tag: format!("dm-{team}"),
            url: format!("/#chat={team}"),
        },
    );
    tracing::info!(
        user_id = user,
        message_id = message.id,
        "team napsack message sent"
    );
    Ok(message.id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vector(name: &str) -> serde_json::Value {
        let text = std::fs::read_to_string(format!(
            "{}/../tests/vectors/{name}",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        serde_json::from_str(&text).unwrap()
    }

    /// The server's pair key and format 2 texts are byte-for-byte the app's:
    /// it opens the pinned vectors (made by crypto.js), and what it seals opens too.
    #[test]
    fn matches_the_apps_encryption() {
        let keys = vector("format1.json");
        let texts = vector("texts2.json");
        let alice = SecretKey::from_pkcs8_der(
            &B64.decode(keys["alice"]["pkcs8"].as_str().unwrap())
                .unwrap(),
        )
        .unwrap();
        let alice_id = keys["alice"]["id"].as_i64().unwrap();
        let bob_id = keys["bob"]["id"].as_i64().unwrap();
        let key = pair_key(
            &alice,
            keys["bob"]["spki"].as_str().unwrap(),
            alice_id,
            bob_id,
        )
        .unwrap();

        let v = &texts["texts"][0];
        let (from, to) = (v["from"].as_i64().unwrap(), v["to"].as_i64().unwrap());
        let raw = B64.decode(v["ciphertext"].as_str().unwrap()).unwrap();
        let aad = format!("napsack/v2/text/{from}/{to}");
        let opened = Aes256Gcm::new((&key).into())
            .decrypt(
                raw[..12].into(),
                Payload {
                    msg: &raw[12..],
                    aad: aad.as_bytes(),
                },
            )
            .expect("opens the app's ciphertext");
        assert_eq!(
            String::from_utf8(opened).unwrap(),
            v["plaintext"].as_str().unwrap()
        );

        let sealed = B64
            .decode(seal_text(&key, "happy birthday 🎂", from, to).unwrap())
            .unwrap();
        let opened = Aes256Gcm::new((&key).into())
            .decrypt(
                sealed[..12].into(),
                Payload {
                    msg: &sealed[12..],
                    aad: aad.as_bytes(),
                },
            )
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&opened).unwrap();
        assert_eq!(body["t"], "happy birthday 🎂");
        // A different pair of people gets a different key.
        assert_ne!(
            pair_key(
                &alice,
                keys["bob"]["spki"].as_str().unwrap(),
                alice_id,
                bob_id + 1
            )
            .unwrap(),
            key
        );
    }

    #[tokio::test]
    async fn made_once_and_kept() {
        let db = crate::db::tests::temp_db().await;
        let id = ensure(&db).await.unwrap();
        assert_eq!(ensure(&db).await.unwrap(), id, "made once");
        assert!(is_system(&db, id).await.unwrap());
        let (name, wrapped): (String, String) =
            sqlx::query_as("SELECT username, wrapped_private_key FROM users WHERE id = ?")
                .bind(id)
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!((name.as_str(), wrapped.as_str()), ("napsack", ""));
        let display: String =
            sqlx::query_scalar("SELECT name FROM user_names WHERE user_id = ? AND set_by = ?")
                .bind(id)
                .bind(id)
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!(display, NAME);
    }
}
