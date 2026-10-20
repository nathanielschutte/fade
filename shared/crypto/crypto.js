// End-to-end encryption, shared by every napsack client: the web app (served
// by the server as /crypto.js) and the iOS app (bundled from this file). It
// uses only the standard WebCrypto API (`crypto.subtle`), TextEncoder/
// TextDecoder, and atob/btoa, which browsers, Node, and React Native (with
// react-native-quick-crypto) all provide. Nothing platform-specific belongs
// here; key storage lives with each client.
//
// Changing bytes on the wire means a new message format (docs/RELEASING.md).
// tests/vectors/format1.json and format2.json pin the exact output, and every
// client is tested against them.
//
//
// Password -> PBKDF2 (salted with the username) -> master secret, split by HKDF into:
//   auth key: sent to the server in place of the password
//   wrap key: never leaves the device; encrypts the private key the server stores
// Each account has a P-256 key pair. Two friends' keys give them a shared
// AES-GCM key (ECDH + HKDF) that encrypts every text and snap between them.
// The server sees ciphertext, public keys, and metadata (who, when, read state).

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();
const dec = new TextDecoder();

/**
 * Message formats, stored with every message (server/src/version.rs). Texts
 * are format 1. Pics are format 2: a caption sealed in with the photo. Old
 * format 1 pics stay readable forever.
 */
export const FORMAT = 1;
export const TEXT_FORMAT = 1;
export const SNAP_FORMAT = 2;
/** Encoded caption limit (200 characters in the UI; emoji take up to 4 bytes each). */
export const MAX_CAPTION_BYTES = 1000;

const PBKDF2_ITERATIONS = 600_000;
const ECDH = { name: "ECDH", namedCurve: "P-256" };
const AES = { name: "AES-GCM", length: 256 };
const IV_BYTES = 12;

// ---------- encoding ----------

export function toB64(bytes) {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000));
  return btoa(s);
}

export function fromB64(b64) {
  const s = atob(b64);
  const u8 = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i);
  return u8;
}

// ---------- AES-GCM ----------
// Output is IV || ciphertext+tag. `aad` binds the ciphertext to its context,
// so the server can't move it to another chat, sender, or message kind.

export async function seal(key, plaintext, aad) {
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const ct = await subtle.encrypt({ name: "AES-GCM", iv, additionalData: enc.encode(aad) }, key, plaintext);
  const out = new Uint8Array(IV_BYTES + ct.byteLength);
  out.set(iv);
  out.set(new Uint8Array(ct), IV_BYTES);
  return out;
}

export async function open(key, sealed, aad) {
  const u8 = sealed instanceof Uint8Array ? sealed : new Uint8Array(sealed);
  const pt = await subtle.decrypt(
    { name: "AES-GCM", iv: u8.subarray(0, IV_BYTES), additionalData: enc.encode(aad) },
    key, u8.subarray(IV_BYTES));
  return new Uint8Array(pt);
}

// ---------- password ----------

/** Slow on purpose (~0.5-2 s). Usernames are case-insensitive, so the salt is too. */
export async function deriveFromPassword(username, password) {
  const pw = await subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const master = await subtle.deriveBits({
    name: "PBKDF2", hash: "SHA-256", iterations: PBKDF2_ITERATIONS,
    salt: enc.encode(`napsack/v1/user/${username.trim().toLowerCase()}`),
  }, pw, 256);
  const hkdf = await subtle.importKey("raw", master, "HKDF", false, ["deriveBits", "deriveKey"]);
  const params = (info) => ({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: enc.encode(info) });
  const authKey = toB64(await subtle.deriveBits(params("napsack/v1/auth"), hkdf, 256));
  const wrapKey = await subtle.deriveKey(params("napsack/v1/wrap"), hkdf, AES, false, ["encrypt", "decrypt"]);
  return { authKey, wrapKey };
}

// ---------- identity ----------

const WRAP_AAD = "napsack/v1/identity";

/** New key pair for a new account. The private key goes to the server only wrapped. */
export async function createIdentity(wrapKey) {
  const pair = await subtle.generateKey(ECDH, true, ["deriveBits"]);
  const pkcs8 = await subtle.exportKey("pkcs8", pair.privateKey);
  const spki = await subtle.exportKey("spki", pair.publicKey);
  const wrapped = await seal(wrapKey, pkcs8, WRAP_AAD);
  // Re-import as non-extractable: page script can use it but never read it out.
  const privateKey = await subtle.importKey("pkcs8", pkcs8, ECDH, false, ["deriveBits"]);
  return { publicKey: toB64(spki), wrappedPrivateKey: toB64(wrapped), privateKey };
}

/** Throws if the wrap key is wrong (wrong password, or the server swapped the blob). */
export async function unwrapIdentity(wrapKey, wrappedB64) {
  const pkcs8 = await open(wrapKey, fromB64(wrappedB64), WRAP_AAD);
  return subtle.importKey("pkcs8", pkcs8, ECDH, false, ["deriveBits"]);
}

// ---------- per-friend key ----------

/** Same key on both sides: ECDH(mine, theirs) is symmetric, and the salt uses sorted ids. */
export async function pairKey(myPrivateKey, theirPublicB64, myId, theirId) {
  const theirs = await subtle.importKey("spki", fromB64(theirPublicB64), ECDH, false, []);
  const shared = await subtle.deriveBits({ name: "ECDH", public: theirs }, myPrivateKey, 256);
  const hkdf = await subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const [lo, hi] = [myId, theirId].sort((a, b) => a - b);
  return subtle.deriveKey({
    name: "HKDF", hash: "SHA-256",
    salt: enc.encode(`napsack/v1/pair/${lo}/${hi}`),
    info: enc.encode("napsack/v1/messages"),
  }, hkdf, AES, false, ["encrypt", "decrypt"]);
}

/** Additional data for a message: who sent it, to whom, and what it is. */
export const messageAad = (kind, senderId, recipientId) => `napsack/v1/${kind}/${senderId}/${recipientId}`;

export async function encryptText(key, text, senderId, recipientId) {
  return toB64(await seal(key, enc.encode(text), messageAad("text", senderId, recipientId)));
}

export async function decryptText(key, b64, senderId, recipientId) {
  return dec.decode(await open(key, fromB64(b64), messageAad("text", senderId, recipientId)));
}

export async function encryptSnap(key, bytes, senderId, recipientId) {
  return seal(key, bytes, messageAad("snap", senderId, recipientId));
}

export async function decryptSnap(key, bytes, senderId, recipientId) {
  return open(key, bytes, messageAad("snap", senderId, recipientId));
}

// ---------- format 2: pic with a caption ----------
// Plaintext: caption length (2 bytes, big-endian) || caption (UTF-8) || JPEG.
// Same pair key; the associated data says v2, so a format 2 pic can't be
// passed off as format 1 or the other way round.

const picAad = (senderId, recipientId) => `napsack/v2/snap/${senderId}/${recipientId}`;

export function packPic(photo, caption = "") {
  const c = enc.encode(caption);
  if (c.length > MAX_CAPTION_BYTES) throw new Error("That caption is too long.");
  const out = new Uint8Array(2 + c.length + photo.length);
  out[0] = c.length >> 8;
  out[1] = c.length & 0xff;
  out.set(c, 2);
  out.set(photo, 2 + c.length);
  return out;
}

export function unpackPic(body) {
  const n = (body[0] << 8) | body[1];
  if (body.length < 2 + n || n > MAX_CAPTION_BYTES) throw new Error("malformed pic");
  return { caption: dec.decode(body.subarray(2, 2 + n)), photo: body.subarray(2 + n) };
}

export async function encryptPic(key, photo, caption, senderId, recipientId) {
  return seal(key, packPic(photo, caption), picAad(senderId, recipientId));
}

/** Any pic format -> { photo, caption }. Format 1 pics have no caption. */
export async function decryptPic(key, bytes, format, senderId, recipientId) {
  if (format === 1) return { photo: await decryptSnap(key, bytes, senderId, recipientId), caption: "" };
  if (format === 2) return unpackPic(await open(key, bytes, picAad(senderId, recipientId)));
  throw new Error(`unknown pic format ${format}`);
}

/**
 * A code both friends see identically. If it matches when compared in person,
 * no one (including the server) is sitting in the middle.
 */
export async function safetyCode(publicB64A, publicB64B) {
  const [a, b] = [publicB64A, publicB64B].sort();
  const digest = new Uint8Array(await subtle.digest("SHA-256", enc.encode(`napsack/v1/safety/${a}/${b}`)));
  const groups = [];
  for (let i = 0; i < 12; i += 2) groups.push(String(((digest[i] << 8) | digest[i + 1]) % 100000).padStart(5, "0"));
  return groups.join(" ");
}
