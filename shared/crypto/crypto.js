// End-to-end encryption, shared by every napsack client: the web app (served
// by the server as /crypto.js) and the iOS app (bundled from this file). It
// uses only the standard WebCrypto API (`crypto.subtle`), TextEncoder/
// TextDecoder, and atob/btoa, which browsers, Node, and React Native (with
// react-native-quick-crypto) all provide. Nothing platform-specific belongs
// here; key storage lives with each client.
//
// Changing bytes on the wire means a new message format (docs/operations/releasing.md).
// The files in tests/vectors/ pin the exact output of each format, and every
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
 * Message formats, stored with every message (server/src/version.rs). New
 * texts and pics are format 2: texts are a JSON envelope (room for replies),
 * pics carry a caption sealed in with the photo. Reactions are format 2 too.
 * Format 1 (the original scheme) stays readable forever.
 */
export const FORMAT = 1;
export const TEXT_FORMAT = 2;
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

/** Re-wraps the private key without it ever leaving this function as a usable key. */
async function rewrap(fromKey, wrappedB64, fromAad, toKey, toAad) {
  const pkcs8 = await open(fromKey, fromB64(wrappedB64), fromAad);
  try {
    return toB64(await seal(toKey, pkcs8, toAad));
  } finally {
    pkcs8.fill(0);
  }
}

/** Changing the password: the same private key, wrapped by the new password's wrap key. */
export async function rewrapIdentity(oldWrapKey, wrappedB64, newWrapKey) {
  return rewrap(oldWrapKey, wrappedB64, WRAP_AAD, newWrapKey, WRAP_AAD);
}

// ---------- recovery key ----------
// A random key the person saves at sign-up. It wraps a second copy of the
// private key, so a forgotten password doesn't cost the message history.
// Shown as 32 Crockford base32 characters in groups of four. It's random
// (160 bits), so HKDF is enough; no slow stretching needed.

const RECOVERY_BYTES = 20;
const RECOVERY_AAD = "napsack/v1/recovery";
const B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford: no I, L, O, U

function toBase32(bytes) {
  let out = "", bits = 0, value = 0;
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

/** Accepts any case, spaces, and dashes, and the letters people mistype (O for 0, I and L for 1). */
export function parseRecoveryKey(text) {
  const clean = String(text).toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  if (clean.length !== 32 || [...clean].some((c) => !B32.includes(c))) {
    throw new Error("That doesn't look like a recovery key. It's 32 letters and numbers.");
  }
  const out = new Uint8Array(RECOVERY_BYTES);
  let bits = 0, value = 0, i = 0;
  for (const c of clean) {
    value = (value << 5) | B32.indexOf(c);
    bits += 5;
    if (bits >= 8) {
      out[i++] = (value >>> (bits - 8)) & 0xff;
      bits -= 8;
    }
  }
  return out;
}

export function formatRecoveryKey(bytes) {
  return toBase32(bytes).match(/.{4}/g).join("-");
}

export function newRecoveryKey() {
  return formatRecoveryKey(globalThis.crypto.getRandomValues(new Uint8Array(RECOVERY_BYTES)));
}

/** Like deriveFromPassword: an auth key for the server, and a wrap key that stays here. */
export async function deriveFromRecoveryKey(text) {
  const hkdf = await subtle.importKey("raw", parseRecoveryKey(text), "HKDF", false, ["deriveBits", "deriveKey"]);
  const params = (info) => ({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: enc.encode(info) });
  const authKey = toB64(await subtle.deriveBits(params("napsack/v1/recovery/auth"), hkdf, 256));
  const wrapKey = await subtle.deriveKey(params("napsack/v1/recovery/wrap"), hkdf, AES, false, ["encrypt", "decrypt"]);
  return { authKey, wrapKey };
}

/** The recovery copy of the private key, made from the password-wrapped one. */
export async function wrapForRecovery(wrapKey, wrappedB64, recoveryWrapKey) {
  return rewrap(wrapKey, wrappedB64, WRAP_AAD, recoveryWrapKey, RECOVERY_AAD);
}

/** Forgot the password: unwraps with the recovery key and wraps under the new password. */
export async function recoverIdentity(recoveryWrapKey, recoveryWrappedB64, newWrapKey) {
  const wrappedPrivateKey = await rewrap(recoveryWrapKey, recoveryWrappedB64, RECOVERY_AAD, newWrapKey, WRAP_AAD);
  return { wrappedPrivateKey, privateKey: await unwrapIdentity(newWrapKey, wrappedPrivateKey) };
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

// ---------- format 2: texts with room to grow, and reactions ----------
// A format 2 text encrypts a small JSON object instead of the bare text:
//   {"t": "the text", "re": 123}   ("re", optional: the message it replies to)
// Readers ignore keys they don't know, so later additions don't need a new format.

const textAad2 = (senderId, recipientId) => `napsack/v2/text/${senderId}/${recipientId}`;

/** The plaintext of a format 2 text: exactly these bytes are encrypted. */
export function packText(text, replyTo = null) {
  const body = { t: String(text) };
  if (replyTo != null) body.re = Number(replyTo);
  return JSON.stringify(body);
}

export function unpackText(json) {
  const body = JSON.parse(json);
  if (typeof body?.t !== "string") throw new Error("malformed text");
  return { text: body.t, replyTo: Number.isSafeInteger(body.re) ? body.re : null };
}

export async function encryptText2(key, text, replyTo, senderId, recipientId) {
  return toB64(await seal(key, enc.encode(packText(text, replyTo)), textAad2(senderId, recipientId)));
}

/** Any text format -> { text, replyTo }. Format 1 texts never reply. */
export async function decryptAnyText(key, b64, format, senderId, recipientId) {
  if (format === 1) return { text: await decryptText(key, b64, senderId, recipientId), replyTo: null };
  if (format === 2) return unpackText(dec.decode(await open(key, fromB64(b64), textAad2(senderId, recipientId))));
  throw new Error(`unknown text format ${format}`);
}

/** The reactions clients offer (the server checks group reactions against the same set). */
export const REACTIONS = ["❤️", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F44D}", "\u{1F44E}"];

// A reaction's associated data names the message it's on, so the server
// can't move it to another message.
const reactionAad = (senderId, recipientId, messageId) => `napsack/v2/reaction/${senderId}/${recipientId}/${messageId}`;

export async function encryptReaction(key, emoji, senderId, recipientId, messageId) {
  return toB64(await seal(key, enc.encode(emoji), reactionAad(senderId, recipientId, messageId)));
}

export async function decryptReaction(key, b64, senderId, recipientId, messageId) {
  return dec.decode(await open(key, fromB64(b64), reactionAad(senderId, recipientId, messageId)));
}

// ---------- format 3: group messages (docs/implementation/group-encryption.md) ----------
// Each message is sealed once with a fresh key K, and K is wrapped for every
// member (the sender too, for their other devices) with the key that sender
// and member share: the pair key's ECDH secret under its own HKDF label. A
// wrap only the sender could have made proves who sent it; the wrap's
// associated data pins the group, sender, member, message id, a digest of the
// content, and the member list the sender used.

export const GROUP_FORMAT = 3;
const K_BYTES = 32;
const MID_BYTES = 16;

/** Same on both sides, like pairKey, but only for wrapping group message keys. */
export async function groupWrapKey(myPrivateKey, theirPublicB64, myId, theirId) {
  const theirs = await subtle.importKey("spki", fromB64(theirPublicB64), ECDH, false, []);
  const shared = await subtle.deriveBits({ name: "ECDH", public: theirs }, myPrivateKey, 256);
  const hkdf = await subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const [lo, hi] = [myId, theirId].sort((a, b) => a - b);
  return subtle.deriveKey({
    name: "HKDF", hash: "SHA-256",
    salt: enc.encode(`napsack/v1/pair/${lo}/${hi}`),
    info: enc.encode("napsack/v3/group-keys"),
  }, hkdf, AES, false, ["encrypt", "decrypt"]);
}

const groupAad = (groupId, senderId, mid, kind) => `napsack/v3/group/${groupId}/${senderId}/${mid}/${kind}`;
const groupKeyAad = (groupId, senderId, memberId, mid, digest, roster) =>
  `napsack/v3/group-key/${groupId}/${senderId}/${memberId}/${mid}/${digest}/${roster}`;

async function sha256B64(bytes) {
  return toB64(new Uint8Array(await subtle.digest("SHA-256", bytes)));
}

/** Commits to who a message was for: SHA-256 of the sorted member ids, comma-joined. */
export async function rosterHash(memberIds) {
  const ids = [...memberIds].map(Number).sort((a, b) => a - b);
  return sha256B64(enc.encode(ids.join(",")));
}

/**
 * Seals `body` (bytes) for a group. `wrapKeys`: Map(member id -> groupWrapKey
 * with that member), every current member including the sender. `kind` is
 * "text" or "pic". Returns { clientId, content (bytes), recipients, wraps }.
 */
export async function encryptGroup(body, { groupId, senderId, kind, wrapKeys }) {
  const recipients = [...wrapKeys.keys()].map(Number).sort((a, b) => a - b);
  if (!recipients.includes(senderId)) throw new Error("the sender wraps for themselves too");
  const clientId = toB64(globalThis.crypto.getRandomValues(new Uint8Array(MID_BYTES)));
  const raw = globalThis.crypto.getRandomValues(new Uint8Array(K_BYTES));
  const k = await subtle.importKey("raw", raw, AES, false, ["encrypt"]);
  const content = await seal(k, body, groupAad(groupId, senderId, clientId, kind));
  const digest = await sha256B64(content);
  const roster = await rosterHash(recipients);
  const wraps = {};
  for (const id of recipients) {
    wraps[id] = toB64(await seal(wrapKeys.get(id), raw, groupKeyAad(groupId, senderId, id, clientId, digest, roster)));
  }
  return { clientId, content, recipients, wraps };
}

/** Opens a group message with my wrap. Throws if anything doesn't check out. */
export async function decryptGroup(content, wrapB64, { groupId, senderId, myId, clientId, recipients, kind, wrapKey }) {
  if (!recipients.map(Number).includes(myId)) throw new Error("not sent to me");
  const bytes = content instanceof Uint8Array ? content : new Uint8Array(content);
  const digest = await sha256B64(bytes);
  const roster = await rosterHash(recipients);
  const raw = await open(wrapKey, fromB64(wrapB64), groupKeyAad(groupId, senderId, myId, clientId, digest, roster));
  if (raw.length !== K_BYTES) throw new Error("malformed key");
  const k = await subtle.importKey("raw", raw, AES, false, ["decrypt"]);
  return open(k, bytes, groupAad(groupId, senderId, clientId, kind));
}

/** A group text: the format 2 envelope, so replies travel inside, out of the server's sight. */
export async function encryptGroupText(text, replyTo, opts) {
  return encryptGroup(enc.encode(packText(text, replyTo)), { ...opts, kind: "text" });
}

export async function decryptGroupText(content, wrapB64, opts) {
  return unpackText(dec.decode(await decryptGroup(content, wrapB64, { ...opts, kind: "text" })));
}

/** A group pic: the format 2 pic envelope (caption sealed in with the photo). */
export async function encryptGroupPic(photo, caption, opts) {
  return encryptGroup(packPic(photo, caption), { ...opts, kind: "pic" });
}

export async function decryptGroupPic(content, wrapB64, opts) {
  return unpackPic(await decryptGroup(content, wrapB64, { ...opts, kind: "pic" }));
}

// ---------- edits to texts (plan X29) ----------
// A new version of a text is the format 2 text envelope ({"t": "..."}),
// sealed like the text: with the pair key in a direct chat, or the format 3
// scheme in a group (content kind "edit/<message id>", wrapped for the
// members the text went to). The associated data names the message it edits,
// so the server can't move an edit onto another message. The text it edits
// is never changed; every version is kept.

const editAad = (senderId, recipientId, messageId) => `napsack/v2/edit/${senderId}/${recipientId}/${messageId}`;
const editKind = (messageId) => `edit/${Number(messageId)}`;

export async function encryptEdit(key, text, senderId, recipientId, messageId) {
  return toB64(await seal(key, enc.encode(packText(text)), editAad(senderId, recipientId, messageId)));
}

export async function decryptEdit(key, b64, senderId, recipientId, messageId) {
  return unpackText(dec.decode(await open(key, fromB64(b64), editAad(senderId, recipientId, messageId)))).text;
}

/** `opts` as for encryptGroup; its wrap keys are for the members the text went to. */
export async function encryptGroupEdit(text, messageId, opts) {
  return encryptGroup(enc.encode(packText(text)), { ...opts, kind: editKind(messageId) });
}

export async function decryptGroupEdit(content, wrapB64, messageId, opts) {
  return unpackText(dec.decode(await decryptGroup(content, wrapB64, { ...opts, kind: editKind(messageId) }))).text;
}

// ---------- formats 4 to 7: videos and photos in a media envelope ----------
// A video (and, from format 6, a photo) travels in a media envelope:
//   header length (2 bytes, big-endian) || header (UTF-8 JSON) || the bytes
// The header says what the bytes are and carries the caption, and where on
// the picture it sits (`y`, a fraction of the height from the top; plan X33):
//   {"type": "video/mp4", "c": "the caption", "y": 0.62}
// Readers ignore header keys they don't know, so later additions don't need a
// new format (`y` came after format 4, and older readers skip it). Formats 4
// and 6 seal the envelope with the pair key (a direct chat); 5 and 7 are the
// format 3 group scheme with the content kind "video" or "image". The format
// number tells the server a video from a photo, as the size would anyway.

export const VIDEO_FORMAT = 4;
export const GROUP_VIDEO_FORMAT = 5;
export const IMAGE_FORMAT = 6;
export const GROUP_IMAGE_FORMAT = 7;
const MAX_MEDIA_HEADER_BYTES = 8192;
// What a sender may say the bytes are: a video type and its parameters, or a
// JPEG (photos are always made JPEG before sending), nothing else.
const VIDEO_TYPE = /^video\/[a-z0-9.+-]+(;[a-z0-9 =.,+"-]*)?$/i;
const IMAGE_TYPE = /^image\/jpeg$/;
const mediaTypeOk = (type, kind) => typeof type === "string" && type.length <= 100
  && (kind === "image" ? IMAGE_TYPE : VIDEO_TYPE).test(type);

const videoAad = (senderId, recipientId) => `napsack/v4/snap/${senderId}/${recipientId}`;
const imageAad = (senderId, recipientId) => `napsack/v6/snap/${senderId}/${recipientId}`;

/**
 * The plaintext of a video or photo: exactly these bytes are encrypted.
 * `y`: where the caption sits (0 top to 1 bottom), or null for the default place.
 */
export function packMedia(media, type, caption = "", y = null) {
  const kind = String(type).startsWith("image/") ? "image" : "video";
  if (!mediaTypeOk(type, kind)) throw new Error(`That isn't a ${kind === "image" ? "photo" : "video"} napsack can send.`);
  if (enc.encode(caption).length > MAX_CAPTION_BYTES) throw new Error("That caption is too long.");
  const fields = { type, c: caption };
  if (y != null) fields.y = Math.round(Math.min(1, Math.max(0, Number(y))) * 1000) / 1000;
  const header = enc.encode(JSON.stringify(fields));
  if (header.length > MAX_MEDIA_HEADER_BYTES) throw new Error("That caption is too long.");
  const out = new Uint8Array(2 + header.length + media.length);
  out[0] = header.length >> 8;
  out[1] = header.length & 0xff;
  out.set(header, 2);
  out.set(media, 2 + header.length);
  return out;
}

/**
 * -> { type, caption, y, media }. Throws unless it's a well-formed envelope
 * of the `kind` expected ("video" or "image"): a photo can't pass as a video.
 */
export function unpackMedia(body, kind = "video") {
  const n = (body[0] << 8) | body[1];
  if (body.length < 2 + n || n > MAX_MEDIA_HEADER_BYTES) throw new Error(`malformed ${kind}`);
  const header = JSON.parse(dec.decode(body.subarray(2, 2 + n)));
  if (!mediaTypeOk(header?.type, kind)) throw new Error(`malformed ${kind}`);
  const y = typeof header.y === "number" && header.y >= 0 && header.y <= 1 ? header.y : null;
  return { type: header.type, caption: typeof header.c === "string" ? header.c : "", y, media: body.subarray(2 + n) };
}

export async function encryptVideo(key, media, type, caption, senderId, recipientId, y = null) {
  return seal(key, packMedia(media, type, caption, y), videoAad(senderId, recipientId));
}

export async function decryptVideo(key, bytes, senderId, recipientId) {
  return unpackMedia(await open(key, bytes, videoAad(senderId, recipientId)), "video");
}

/** A group video: the media envelope, sealed with the format 3 scheme as kind "video". */
export async function encryptGroupVideo(media, type, caption, opts, y = null) {
  return encryptGroup(packMedia(media, type, caption, y), { ...opts, kind: "video" });
}

export async function decryptGroupVideo(content, wrapB64, opts) {
  return unpackMedia(await decryptGroup(content, wrapB64, { ...opts, kind: "video" }), "video");
}

/** Format 6: a photo (JPEG) with its caption and where the caption sits. */
export async function encryptImage(key, jpeg, caption, senderId, recipientId, y = null) {
  return seal(key, packMedia(jpeg, "image/jpeg", caption, y), imageAad(senderId, recipientId));
}

export async function decryptImage(key, bytes, senderId, recipientId) {
  return unpackMedia(await open(key, bytes, imageAad(senderId, recipientId)), "image");
}

/** Format 7: a group photo, the format 3 scheme as kind "image". */
export async function encryptGroupImage(jpeg, caption, opts, y = null) {
  return encryptGroup(packMedia(jpeg, "image/jpeg", caption, y), { ...opts, kind: "image" });
}

export async function decryptGroupImage(content, wrapB64, opts) {
  return unpackMedia(await decryptGroup(content, wrapB64, { ...opts, kind: "image" }), "image");
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
