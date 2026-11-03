//! WebAuthn, as much as passkeys need (passkeys.rs, docs/design/passkeys.md):
//! reading what a browser or the app sends when a passkey is made or used,
//! and checking it. By hand rather than a large dependency, as Web Push is
//! (push.rs): ES256 only, no attestation (any authenticator will do, so
//! nothing about it is trusted), and user verification always required.
//! <https://www.w3.org/TR/webauthn-3/>

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};
use rand::RngCore;
use serde::Deserialize;
use sha2::{Digest, Sha256};

/// How long a challenge waits to be answered.
const CHALLENGE_TTL: Duration = Duration::from_secs(5 * 60);
/// Challenges waiting at once, across everyone: a flood of requests for them
/// can't grow memory past this (security.md).
const MAX_CHALLENGES: usize = 10_000;

/// Who passkeys are made for: the site's own name (napsack.io; staging's
/// passkeys are staging's), and the origins allowed to use them.
pub struct Rp {
    pub id: String,
    origin: String,
    /// Development and tests (no FADE_PUBLIC_URL): any http://localhost port,
    /// since browsers only make passkeys for a name, never 127.0.0.1.
    any_localhost: bool,
}

impl Rp {
    pub fn new(public_url: &str, deployed: bool) -> Self {
        let rest = public_url.split_once("://").map_or(public_url, |(_, r)| r);
        let host_port = rest.split('/').next().unwrap_or(rest);
        let host = host_port.split(':').next().unwrap_or(host_port);
        let id = if host.is_empty() || host.parse::<std::net::IpAddr>().is_ok() {
            "localhost".to_string()
        } else {
            host.to_ascii_lowercase()
        };
        Self {
            origin: public_url.trim_end_matches('/').to_ascii_lowercase(),
            id,
            any_localhost: !deployed,
        }
    }

    fn origin_ok(&self, origin: &str) -> bool {
        if origin == self.origin {
            return true;
        }
        self.any_localhost
            && self.id == "localhost"
            && origin.strip_prefix("http://localhost").is_some_and(|port| {
                port.is_empty()
                    || port
                        .strip_prefix(':')
                        .is_some_and(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
            })
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Purpose {
    Register,
    SignIn,
}

struct Pending {
    purpose: Purpose,
    user_id: Option<i64>,
    until: Instant,
}

/// Challenges handed out and not yet answered, in memory. Each is used once.
#[derive(Default)]
pub struct Challenges {
    pending: Mutex<HashMap<[u8; 32], Pending>>,
}

impl Challenges {
    /// A fresh challenge, or None while too many are waiting.
    pub fn issue(&self, purpose: Purpose, user_id: Option<i64>) -> Option<[u8; 32]> {
        let mut challenge = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut challenge);
        let mut pending = self.pending.lock().unwrap();
        if pending.len() >= MAX_CHALLENGES {
            let now = Instant::now();
            pending.retain(|_, p| p.until > now);
            if pending.len() >= MAX_CHALLENGES {
                return None;
            }
        }
        pending.insert(
            challenge,
            Pending {
                purpose,
                user_id,
                until: Instant::now() + CHALLENGE_TTL,
            },
        );
        Some(challenge)
    }

    /// Uses up a challenge: true if it was handed out for this, to this
    /// person (or to anyone, signing in), and hasn't expired.
    pub fn take(&self, challenge: &[u8], purpose: Purpose, user_id: Option<i64>) -> bool {
        let Ok(key) = <[u8; 32]>::try_from(challenge) else {
            return false;
        };
        let taken = self.pending.lock().unwrap().remove(&key);
        taken.is_some_and(|p| {
            p.purpose == purpose && p.user_id == user_id && p.until > Instant::now()
        })
    }
}

/// What the browser signed alongside the authenticator (`clientDataJSON`).
#[derive(Deserialize)]
struct ClientData {
    #[serde(rename = "type")]
    kind: String,
    challenge: String,
    origin: String,
    #[serde(rename = "crossOrigin", default)]
    cross_origin: bool,
}

/// The challenge a `clientDataJSON` answers, to look up before checking the rest.
pub fn challenge_of(client_data_json: &[u8]) -> Option<Vec<u8>> {
    let data: ClientData = serde_json::from_slice(client_data_json).ok()?;
    b64url(&data.challenge)
}

fn check_client_data(
    rp: &Rp,
    json: &[u8],
    kind: &str,
    challenge: &[u8],
) -> Result<(), &'static str> {
    let data: ClientData = serde_json::from_slice(json).map_err(|_| "client data unreadable")?;
    if data.kind != kind {
        return Err("wrong ceremony");
    }
    if b64url(&data.challenge).as_deref() != Some(challenge) {
        return Err("wrong challenge");
    }
    if data.cross_origin || !rp.origin_ok(&data.origin) {
        return Err("wrong origin");
    }
    Ok(())
}

/// Base64url, with or without padding, as browsers and apps send it.
pub fn b64url(s: &str) -> Option<Vec<u8>> {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    URL_SAFE_NO_PAD.decode(s.trim_end_matches('=')).ok()
}

// ---------- CBOR ----------
// Just what authenticators send (RFC 8949): definite lengths, integers, byte
// and text strings, arrays, maps, and simple values. Tags and indefinite
// lengths aren't used by CTAP2 and are refused.

#[derive(Debug, Clone, PartialEq)]
enum Cbor {
    Int(i128),
    Bytes(Vec<u8>),
    Text(String),
    Array(Vec<Cbor>),
    Map(Vec<(Cbor, Cbor)>),
    Simple,
}

impl Cbor {
    fn get(&self, key: &Cbor) -> Option<&Cbor> {
        match self {
            Cbor::Map(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

/// One value from the front of `bytes`, and how many bytes it took.
fn cbor(bytes: &[u8]) -> Result<(Cbor, usize), &'static str> {
    fn read(b: &[u8], at: &mut usize, depth: u8) -> Result<Cbor, &'static str> {
        if depth > 8 {
            return Err("cbor too deep");
        }
        let first = *b.get(*at).ok_or("cbor cut short")?;
        *at += 1;
        let (major, info) = (first >> 5, first & 0x1f);
        let mut take = |n: usize| -> Result<&[u8], &'static str> {
            let s = b.get(*at..*at + n).ok_or("cbor cut short")?;
            *at += n;
            Ok(s)
        };
        let arg: u64 = match info {
            0..=23 => info as u64,
            24 => take(1)?[0] as u64,
            25 => u16::from_be_bytes(take(2)?.try_into().unwrap()) as u64,
            26 => u32::from_be_bytes(take(4)?.try_into().unwrap()) as u64,
            27 => u64::from_be_bytes(take(8)?.try_into().unwrap()),
            _ => return Err("cbor length not supported"),
        };
        // Nothing an authenticator sends comes near this; it bounds allocation.
        let len = || {
            usize::try_from(arg)
                .ok()
                .filter(|&n| n <= b.len())
                .ok_or("cbor too long")
        };
        Ok(match major {
            0 => Cbor::Int(arg as i128),
            1 => Cbor::Int(-1 - arg as i128),
            2 => Cbor::Bytes(take(len()?)?.to_vec()),
            3 => Cbor::Text(
                String::from_utf8(take(len()?)?.to_vec()).map_err(|_| "cbor text not utf-8")?,
            ),
            4 => Cbor::Array(
                (0..len()?)
                    .map(|_| read(b, at, depth + 1))
                    .collect::<Result<_, _>>()?,
            ),
            5 => Cbor::Map(
                (0..len()?)
                    .map(|_| Ok((read(b, at, depth + 1)?, read(b, at, depth + 1)?)))
                    .collect::<Result<_, &'static str>>()?,
            ),
            7 => Cbor::Simple,
            _ => return Err("cbor tag not supported"),
        })
    }
    let mut at = 0;
    let value = read(bytes, &mut at, 0)?;
    Ok((value, at))
}

// ---------- authenticator data ----------

const UP: u8 = 0x01; // the person was there
const UV: u8 = 0x04; // and verified (Face ID, a fingerprint, a PIN)
const AT: u8 = 0x40; // a new credential follows

struct AuthData {
    rp_id_hash: [u8; 32],
    flags: u8,
    sign_count: u32,
    /// When a passkey is made: its AAGUID, id, and public key (SEC1, uncompressed).
    created: Option<([u8; 16], Vec<u8>, Vec<u8>)>,
}

fn auth_data(b: &[u8]) -> Result<AuthData, &'static str> {
    if b.len() < 37 {
        return Err("authenticator data too short");
    }
    let flags = b[32];
    let mut out = AuthData {
        rp_id_hash: b[..32].try_into().unwrap(),
        flags,
        sign_count: u32::from_be_bytes(b[33..37].try_into().unwrap()),
        created: None,
    };
    if flags & AT != 0 {
        let rest = &b[37..];
        if rest.len() < 18 {
            return Err("credential data too short");
        }
        let aaguid: [u8; 16] = rest[..16].try_into().unwrap();
        let id_len = u16::from_be_bytes([rest[16], rest[17]]) as usize;
        if id_len == 0 || id_len > 1023 {
            return Err("credential id length");
        }
        let id = rest
            .get(18..18 + id_len)
            .ok_or("credential id cut short")?
            .to_vec();
        let (key, _) = cbor(&rest[18 + id_len..])?;
        out.created = Some((aaguid, id, es256_key(&key)?));
    }
    Ok(out)
}

/// A COSE key that must be ES256 on P-256 (kty 2, alg -7, crv 1), as SEC1.
fn es256_key(key: &Cbor) -> Result<Vec<u8>, &'static str> {
    let int = |k: i128| key.get(&Cbor::Int(k));
    if int(1) != Some(&Cbor::Int(2))
        || int(3) != Some(&Cbor::Int(-7))
        || int(-1) != Some(&Cbor::Int(1))
    {
        return Err("not an ES256 key");
    }
    let (Some(Cbor::Bytes(x)), Some(Cbor::Bytes(y))) = (int(-2), int(-3)) else {
        return Err("key coordinates missing");
    };
    if x.len() != 32 || y.len() != 32 {
        return Err("key coordinates length");
    }
    let sec1 = [&[4u8][..], x, y].concat();
    VerifyingKey::from_sec1_bytes(&sec1).map_err(|_| "key not on the curve")?;
    Ok(sec1)
}

fn check_auth_data(rp: &Rp, data: &AuthData) -> Result<(), &'static str> {
    if data.rp_id_hash != <[u8; 32]>::from(Sha256::digest(rp.id.as_bytes())) {
        return Err("wrong relying party");
    }
    if data.flags & UP == 0 || data.flags & UV == 0 {
        return Err("not verified");
    }
    Ok(())
}

/// A passkey just made, checked.
#[derive(Debug)]
pub struct NewPasskey {
    pub credential_id: Vec<u8>,
    /// P-256, SEC1 uncompressed (65 bytes).
    pub public_key: Vec<u8>,
    pub sign_count: u32,
    pub aaguid: [u8; 16],
}

/// Checks a new passkey (`navigator.credentials.create`'s response) against
/// the challenge it answers. The attestation statement isn't checked:
/// napsack asks for none, and any authenticator will do.
pub fn verify_registration(
    rp: &Rp,
    challenge: &[u8],
    client_data_json: &[u8],
    attestation_object: &[u8],
) -> Result<NewPasskey, &'static str> {
    check_client_data(rp, client_data_json, "webauthn.create", challenge)?;
    let (object, _) = cbor(attestation_object)?;
    let Some(Cbor::Bytes(raw)) = object.get(&Cbor::Text("authData".into())) else {
        return Err("authenticator data missing");
    };
    let data = auth_data(raw)?;
    check_auth_data(rp, &data)?;
    let (aaguid, credential_id, public_key) = data.created.ok_or("no credential")?;
    Ok(NewPasskey {
        credential_id,
        public_key,
        sign_count: data.sign_count,
        aaguid,
    })
}

/// Checks a sign-in (`navigator.credentials.get`'s response) made with the
/// stored passkey. Returns its new signature count.
pub fn verify_assertion(
    rp: &Rp,
    challenge: &[u8],
    client_data_json: &[u8],
    authenticator_data: &[u8],
    signature_der: &[u8],
    public_key: &[u8],
    stored_count: u32,
) -> Result<u32, &'static str> {
    check_client_data(rp, client_data_json, "webauthn.get", challenge)?;
    let data = auth_data(authenticator_data)?;
    check_auth_data(rp, &data)?;
    let key = VerifyingKey::from_sec1_bytes(public_key).map_err(|_| "stored key unreadable")?;
    let signature = Signature::from_der(signature_der).map_err(|_| "signature unreadable")?;
    // Both forms of s are valid ECDSA; authenticators may send either.
    let signature = signature.normalize_s().unwrap_or(signature);
    let signed = [authenticator_data, &Sha256::digest(client_data_json)[..]].concat();
    key.verify(&signed, &signature)
        .map_err(|_| "bad signature")?;
    // Synced passkeys always say 0. One that counts must only go up, or it was copied.
    if (data.sign_count != 0 || stored_count != 0) && data.sign_count <= stored_count {
        return Err("signature count went back");
    }
    Ok(data.sign_count)
}

/// Where a passkey is kept, from its authenticator's AAGUID, when it's one of
/// the common ones (the community list, passkeydeveloper/passkey-authenticator-aaguids).
pub fn provider(aaguid: &[u8; 16]) -> Option<&'static str> {
    let hex: String = aaguid.iter().map(|b| format!("{b:02x}")).collect();
    Some(match hex.as_str() {
        "fbfc3007154e4ecc8c0b6e020557d7bd" | "dd4ec289e01d41c9bb8970fa845d4bf2" => {
            "iCloud Keychain"
        }
        "ea9b8d664d011d213ce4b6b48cb575d4" => "Google Password Manager",
        "adce000235bcc60a648b0b25f1f05503" => "Chrome on Mac",
        "08987058cadc4b81b6e130de50dcbe96"
        | "9ddd1817af5a4672a2b93e3dd95000a9"
        | "6028b017b1d44c02b4b3afcdafc96bb2" => "Windows Hello",
        "bada5566a7aa401fbd9645619a55120d" => "1Password",
        "d548826e79b4db40a3d811116f7e8349" => "Bitwarden",
        "531126d6e717415c93203d9aa6981239" => "Dashlane",
        "53414d53554e47000000000000000000" => "Samsung Pass",
        "50726f746f6e5061737350726f746f6e" => "Proton Pass",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::{signature::Signer, SigningKey};

    /// A stand-in authenticator: makes
    /// passkeys and signs with them as a browser's would.
    pub struct Authenticator {
        pub key: SigningKey,
        pub id: Vec<u8>,
        pub count: u32,
    }

    pub fn client_data(kind: &str, challenge: &[u8], origin: &str) -> Vec<u8> {
        use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
        serde_json::to_vec(&serde_json::json!({
            "type": kind, "challenge": URL_SAFE_NO_PAD.encode(challenge), "origin": origin, "crossOrigin": false,
        }))
        .unwrap()
    }

    fn cbor_head(major: u8, n: usize) -> Vec<u8> {
        match n {
            0..=23 => vec![major << 5 | n as u8],
            24..=255 => vec![major << 5 | 24, n as u8],
            _ => [vec![major << 5 | 25], (n as u16).to_be_bytes().to_vec()].concat(),
        }
    }
    fn cbor_bytes(b: &[u8]) -> Vec<u8> {
        [cbor_head(2, b.len()), b.to_vec()].concat()
    }
    fn cbor_text(s: &str) -> Vec<u8> {
        [cbor_head(3, s.len()), s.as_bytes().to_vec()].concat()
    }

    impl Authenticator {
        pub fn new(count: u32) -> Self {
            let mut id = vec![0u8; 16];
            rand::rngs::OsRng.fill_bytes(&mut id);
            Self {
                key: SigningKey::random(&mut rand::rngs::OsRng),
                id,
                count,
            }
        }

        fn data(&self, rp_id: &str, flags: u8, created: bool) -> Vec<u8> {
            let mut d = Sha256::digest(rp_id.as_bytes()).to_vec();
            d.push(flags);
            d.extend(self.count.to_be_bytes());
            if created {
                let point = self.key.verifying_key().to_encoded_point(false);
                d.extend([
                    0xfb, 0xfc, 0x30, 0x07, 0x15, 0x4e, 0x4e, 0xcc, 0x8c, 0x0b, 0x6e, 0x02, 0x05,
                    0x57, 0xd7, 0xbd,
                ]);
                d.extend((self.id.len() as u16).to_be_bytes());
                d.extend(&self.id);
                // {1: 2, 3: -7, -1: 1, -2: x, -3: y}
                d.extend([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21]);
                d.extend(cbor_bytes(point.x().unwrap()));
                d.push(0x22);
                d.extend(cbor_bytes(point.y().unwrap()));
            }
            d
        }

        /// `attestationObject` for a new passkey, with "none" attestation.
        pub fn attestation(&self, rp_id: &str, flags: u8) -> Vec<u8> {
            [
                vec![0xa3],
                cbor_text("fmt"),
                cbor_text("none"),
                cbor_text("attStmt"),
                vec![0xa0],
                cbor_text("authData"),
                cbor_bytes(&self.data(rp_id, flags, true)),
            ]
            .concat()
        }

        /// `authenticatorData` and a DER signature for signing in.
        pub fn sign(&mut self, rp_id: &str, client_data: &[u8]) -> (Vec<u8>, Vec<u8>) {
            let data = self.data(rp_id, UP | UV, false);
            let signed = [&data[..], &Sha256::digest(client_data)[..]].concat();
            let sig: Signature = self.key.sign(&signed);
            (data, sig.to_der().as_bytes().to_vec())
        }

        pub fn public_key(&self) -> Vec<u8> {
            self.key
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec()
        }
    }

    fn rp() -> Rp {
        Rp::new("https://napsack.io", true)
    }

    #[test]
    fn the_relying_party_is_the_sites_name() {
        let r = rp();
        assert_eq!(r.id, "napsack.io");
        assert!(r.origin_ok("https://napsack.io"));
        for bad in [
            "https://evil.io",
            "http://napsack.io",
            "https://napsack.io.evil.io",
            "http://localhost:8099",
        ] {
            assert!(!r.origin_ok(bad), "{bad}");
        }
        assert_eq!(
            Rp::new("https://staging.napsack.io/", true).id,
            "staging.napsack.io"
        );
        // Development: browsers make passkeys for localhost, never an address.
        let dev = Rp::new("http://127.0.0.1:8099", false);
        assert_eq!(dev.id, "localhost");
        assert!(dev.origin_ok("http://localhost:8099") && dev.origin_ok("http://localhost:3000"));
        assert!(
            !dev.origin_ok("http://localhost:80x") && !dev.origin_ok("http://localhost.evil.io")
        );
        assert!(!Rp::new("https://localhost", true).origin_ok("http://localhost:8099"));
    }

    #[test]
    fn a_new_passkey_is_read_and_checked() {
        let a = Authenticator::new(0);
        let challenge = [7u8; 32];
        let cd = client_data("webauthn.create", &challenge, "https://napsack.io");
        let made = verify_registration(
            &rp(),
            &challenge,
            &cd,
            &a.attestation("napsack.io", UP | UV | AT),
        )
        .unwrap();
        assert_eq!(made.credential_id, a.id);
        assert_eq!(made.public_key, a.public_key());
        assert_eq!(provider(&made.aaguid), Some("iCloud Keychain"));

        let refused =
            |cd: &[u8], att: &[u8]| verify_registration(&rp(), &challenge, cd, att).unwrap_err();
        let att = a.attestation("napsack.io", UP | UV | AT);
        assert_eq!(
            refused(
                &client_data("webauthn.get", &challenge, "https://napsack.io"),
                &att
            ),
            "wrong ceremony"
        );
        assert_eq!(
            refused(
                &client_data("webauthn.create", &[8u8; 32], "https://napsack.io"),
                &att
            ),
            "wrong challenge"
        );
        assert_eq!(
            refused(
                &client_data("webauthn.create", &challenge, "https://evil.io"),
                &att
            ),
            "wrong origin"
        );
        assert_eq!(
            refused(&cd, &a.attestation("evil.io", UP | UV | AT)),
            "wrong relying party"
        );
        assert_eq!(
            refused(&cd, &a.attestation("napsack.io", UP | AT)),
            "not verified"
        );
        assert!(refused(&cd, &att[..att.len() - 5]).starts_with("cbor"));
        assert!(!refused(&cd, b"not cbor at all").is_empty());
    }

    #[test]
    fn a_sign_in_is_checked_against_the_stored_key() {
        let mut a = Authenticator::new(0);
        let challenge = [9u8; 32];
        let cd = client_data("webauthn.get", &challenge, "https://napsack.io");
        let (data, sig) = a.sign("napsack.io", &cd);
        assert_eq!(
            verify_assertion(&rp(), &challenge, &cd, &data, &sig, &a.public_key(), 0),
            Ok(0)
        );

        let other = Authenticator::new(0);
        assert_eq!(
            verify_assertion(&rp(), &challenge, &cd, &data, &sig, &other.public_key(), 0),
            Err("bad signature")
        );
        // The browser's data was changed after signing.
        let changed = client_data("webauthn.get", &challenge, "https://napsack.io").repeat(1);
        let mut tampered = changed.clone();
        tampered.push(b' ');
        assert_eq!(
            verify_assertion(
                &rp(),
                &challenge,
                &tampered,
                &data,
                &sig,
                &a.public_key(),
                0
            ),
            Err("bad signature")
        );
        assert_eq!(
            verify_assertion(&rp(), &[1u8; 32], &cd, &data, &sig, &a.public_key(), 0),
            Err("wrong challenge")
        );

        // A counting authenticator must count up.
        a.count = 5;
        let (data, sig) = a.sign("napsack.io", &cd);
        assert_eq!(
            verify_assertion(&rp(), &challenge, &cd, &data, &sig, &a.public_key(), 4),
            Ok(5)
        );
        assert_eq!(
            verify_assertion(&rp(), &challenge, &cd, &data, &sig, &a.public_key(), 5),
            Err("signature count went back")
        );
    }

    #[test]
    fn challenges_are_used_once_for_their_purpose() {
        let c = Challenges::default();
        let one = c.issue(Purpose::Register, Some(1)).unwrap();
        assert!(!c.take(&one, Purpose::SignIn, None), "another purpose");
        let two = c.issue(Purpose::Register, Some(1)).unwrap();
        assert!(!c.take(&two, Purpose::Register, Some(2)), "another person");
        let three = c.issue(Purpose::SignIn, None).unwrap();
        assert!(c.take(&three, Purpose::SignIn, None));
        assert!(!c.take(&three, Purpose::SignIn, None), "only once");
        assert!(!c.take(&[0u8; 5], Purpose::SignIn, None));
    }

    #[test]
    fn cbor_reads_what_authenticators_send_and_refuses_the_rest() {
        let (v, used) = cbor(&[0xa2, 0x01, 0x02, 0x20, 0x43, 1, 2, 3, 0xff]).unwrap();
        assert_eq!(used, 8);
        assert_eq!(v.get(&Cbor::Int(1)), Some(&Cbor::Int(2)));
        assert_eq!(v.get(&Cbor::Int(-1)), Some(&Cbor::Bytes(vec![1, 2, 3])));
        assert!(cbor(&[0x5f]).is_err(), "indefinite length");
        assert!(cbor(&[0xc0, 0x01]).is_err(), "tag");
        assert!(
            cbor(&[0x5a, 0xff, 0xff, 0xff, 0xff]).is_err(),
            "longer than what was sent"
        );
        assert!(cbor(&[0x81; 20]).is_err(), "too deep");
    }
}
