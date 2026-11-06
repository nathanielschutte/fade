// napsack web client. Plain ES module: no framework, no build step.
// Every API call here is what the future mobile app will make too.
// Texts and snaps are encrypted here before upload; see crypto.js.

import * as e2e from "/crypto.js";
import * as keystore from "/keystore.js";
import * as cache from "/cache.js";

import { qrSvg } from "/qr.js";
import { markEnvironment, withEnvironment } from "/env.js";
import { createDrawing } from "/draw.js";
import { emojiOnly } from "/emoji-only.js";
import { chatName as mapChatName, chatSummary, drawGraph, groupLetter, isChat, widthChanged } from "/graph-view.js";

// "napsack (staging)" on a non-production copy (env.js), set at boot.
let APP_NAME = "napsack";
const VIEW_MS = 10_000;        // how long a snap stays on screen
const MAX_EDGE = 1280;         // longest side of a snap, before any further shrinking
const SNAP_TARGET_BYTES = 200 * 1024;
const TOKEN_KEY = "fade.token";
const IDENTITY_KEY = "identity";

const $ = (sel, root = document) => root.querySelector(sel);

const state = {
  token: localStorage.getItem(TOKEN_KEY),
  me: null,
  // Whether the chat and group lists have answered yet, so an empty list can
  // say "loading" rather than "no friends" (X23); the last error loading them.
  loaded: { chats: false, groups: false, error: null },
  loadFailed: new Map(),       // "d:<friend>" or "g:<group>" -> why its first page didn't load
  identity: null,              // { userId, privateKey (non-extractable), publicKey }
  pins: {},                    // friend id -> public key first seen (trust on first use)
  pastPins: {},                // friend id -> keys they had before, accepted by me; still read old messages
  readKeys: new Map(),         // friend id -> (promised) chat keys for reading: pinned, then past
  reactionText: new Map(),     // reaction cache key -> decrypted emoji, or null
  actionFor: null,             // "d:<id>" or "g:<id>": the message whose reaction/reply row is open
  replyTo: null,               // { group, id, who, snippet } while composing a reply
  typing: new Map(),           // "d:<friend>" or "g:<group>:<user>" -> when the "typing" hint ends
  invite: null,                // { token, inviter, problem } from an /i/<token> link
  pairKeys: new Map(),         // friend id -> (promised) AES key shared with them
  plaintext: new Map(),        // message id -> decrypted text, or null if it couldn't be
  editText: new Map(),         // "<message id>:<edit ciphertext>" -> the newest edit's text, or null (X29)
  editing: null,               // the text being edited in the composer: { group, id, m }
  config: null,
  chats: [],
  requests: { incoming: [], outgoing: [] },
  activeId: null,              // friend id of the open chat
  groups: [],                  // GroupSummary[] (messages end-to-end encrypted; names and pictures aren't)
  activeGroupId: null,         // group id of the open group chat (activeId is null then)
  groupMessages: new Map(),    // group id -> GroupMessage[], oldest first
  groupHistory: new Map(),     // group id -> { hasMore, loading }
  groupReads: new Map(),       // group id -> Map(user id -> { username, last }): how far each member has read
  showHidden: false,           // the chat list is showing hidden chats
  search: { q: "", hits: null }, // the chat list's search box, and message matches (null while looking)
  groupDetail: null,           // the group shown in the info sheet
  messages: new Map(),         // friend id -> Message[], oldest first; may be only the newest pages
  readUpTo: new Map(),         // friend id -> when they last read my texts ("read" events)
  history: new Map(),          // friend id -> { hasMore, loading } for paging back
  ws: null,
  wsRetry: 0,
  wsTimer: null,               // the next reconnect attempt, while the socket is down
};

// ---------- helpers ----------

// Quick way to create new elements with properties:
//  - class, text, on<event>=<handler function>, and other attributes.
function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value == null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat()) if (child != null) node.append(child);
  return node;
}


// Our API errors, thrown as exceptions so they can be caught and reported
class ApiError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}


// Make an API call. Requests give up after a while rather than hang on a bad
// connection, and reads (GETs) are tried again a couple of times on network
// errors and the brief 502s of a deploy. Writes aren't retried here: the
// outbox does that, with ids that make a resend safe. `as: "json"`,
// `as: "text"`, or `as: "bytes"` reads the body inside the same time limit.
async function api(path, { method = "GET", json, body, headers = {}, timeout, retries, as } = {}) {
  const HEADERS = { ...headers };

  // our primary client authorization mechanism
  if (state.token) HEADERS.Authorization = `Bearer ${state.token}`;

  if (json !== undefined) {
    HEADERS["Content-Type"] = "application/json";
    body = JSON.stringify(json);
  }

  const large = as === "bytes" || body instanceof Blob || body instanceof Uint8Array;
  const limit = timeout ?? (large ? 90_000 : 20_000);
  const tries = retries ?? (method === "GET" ? 2 : 0);
  // Uploads and downloads of pics are slow by nature; the rest says when the
  // connection is (netWatch).
  const watched = !large;
  if (watched) netWatch.started();
  let ok = false;
  try {
  for (let attempt = 0; ; attempt++) {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), limit);
    const lost = () => new ApiError(abort.signal.aborted
      ? "The connection is too slow right now. Try again in a moment."
      : "Can't reach the server. Check your connection.", 0);
    try {
      let res;
      try {
        res = await fetch(`/api${path}`, { method, headers: HEADERS, body, cache: "no-store", signal: abort.signal });
      } catch {
        throw lost();
      }

      // 401 Unauthorized, we have a token but it's not working
      if (res.status === 401 && state.token && !path.startsWith("/auth/")) {
        await signOutLocally("Your session ended. Sign in again.");
      }

      if (!res.ok) {
        let msg = `Request failed (${res.status}).`;
        try { msg = (await res.json()).error || msg; } catch {}
        throw new ApiError(msg, res.status);
      }

      let out = res;
      if (as === "json") out = await res.json();
      else if (as === "text") out = await res.text();
      else if (as === "bytes") out = new Uint8Array(await res.arrayBuffer());
      ok = true;
      return out;
    } catch (err) {
      // A body cut off mid-download counts as a dropped connection.
      const e = err instanceof ApiError ? err : lost();
      if (attempt < tries && retryable(e)) {
        await sleep(700 * 3 ** attempt);
        continue;
      }
      if (watched && e.status === 0) netWatch.unreachable();
      throw e;
    } finally {
      clearTimeout(timer);
    }
  }
  } finally {
    if (watched) netWatch.ended(ok);
  }
}

// ---------- slow and unreachable (X23) ----------
// When something has been loading for a few seconds, the banner says the
// connection is slow; when requests can't get through at all, it says so.
// It never covers the socket's own news (offline, reconnecting), and clears
// itself once requests are answered again.
const SLOW_MS = 4000;
const netWatch = {
  pending: 0,
  timer: null,
  started() {
    this.pending++;
    if (!this.timer) this.timer = setTimeout(() => this.slow(), SLOW_MS);
  },
  ended(ok) {
    this.pending = Math.max(0, this.pending - 1);
    if (ok && ["slow", "down"].includes($("#conn-banner").dataset.kind)) setConnBanner(null);
    if (!this.pending) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  },
  slow() {
    this.timer = null;
    if (!this.pending || !state.token || !$("#conn-banner").hidden) return;
    setConnBanner("Slow connection: still loading…", "slow");
  },
  unreachable() {
    if (!state.token || !navigator.onLine) return;
    const kind = $("#conn-banner").dataset.kind;
    if ($("#conn-banner").hidden || kind === "slow") setConnBanner("Can't reach napsack right now. Check your connection.", "down");
  },
};

/** Worth trying again: the connection dropped or timed out, or the server is briefly away. */
function retryable(err) {
  return err instanceof ApiError && (err.status === 0 || err.status === 502 || err.status === 503 || err.status === 504);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Tries `fn` up to `tries` times while the failure is the connection's, waiting a little longer each time. */
async function withRetries(fn, tries = 3) {
  for (let i = 0; ; i++) {
    try {
      return await fn();
    } catch (err) {
      if (i >= tries - 1 || !retryable(err)) throw err;
      await sleep(1000 * 3 ** i);
    }
  }
}

/** A random id for something being sent, so the server can tell a retry from a new message. */
function newClientId() {
  return e2e.toB64(crypto.getRandomValues(new Uint8Array(16))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// gimme dat json right away
const getJSON = (path, opts) => api(path, { ...opts, as: "json" });

function relTime(ts) {
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  if (s < 7 * 86400) return `${Math.floor(s / 86400)}d`;
  return new Date(ts * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function clockTime(ts) {
  return new Date(ts * 1000).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

const PAGE = 50;               // messages per request when opening a chat or scrolling back
const SLOW_PAGE = 20;          // the same, when the connection says it's slow or saving data (X31)
/** Messages to ask for at once: fewer when the browser says the connection is slow. */
function pageSize() {
  const c = navigator.connection;
  return c && (c.saveData || ["slow-2g", "2g"].includes(c.effectiveType)) ? SLOW_PAGE : PAGE;
}


// ---------- diagnostics ----------
// Events and errors go to the server's admin log viewer (/admin#logs) as well
// as the console. Never pass message text, pictures, keys, or anything typed:
// only ids, counts, statuses, and error descriptions. The server also redacts
// fields that look like content.

const diag = { queue: [], timer: null };

function report(level, message, fields = {}) {
  (level === "error" || level === "warn" ? console.warn : console.debug)(`[napsack] ${message}`, fields);
  
  diag.queue.push({ level, message, fields });
  
  // remove oldest queue entries if queue exceeds 200 length
  if (diag.queue.length > 200) {
    diag.queue.splice(0, diag.queue.length - 200);
  }

  // each new report resets our batch timer
  clearTimeout(diag.timer);

  // half a second if we got an error, 5 seconds otherwise
  // this lets the queue accumulate
  diag.timer = setTimeout(flushReports, level === "error" ? 500 : 5000);
}

// { message: <message>, status: <status> } => error=message, status=status
// <message> => error=message, status=undefined
// message is always a string no longer than 300 characters
const errorFields = (err) => ({ error: String(err?.message ?? err).slice(0, 300), status: err?.status });

async function flushReports(keepalive = false) {
  if (!diag.queue.length) return;

  const entries = diag.queue.splice(0, 50);
  const headers = { "Content-Type": "application/json" };
  
  if (state.token) headers.Authorization = `Bearer ${state.token}`;
  try {
    await fetch("/api/logs", { method: "POST", headers, keepalive, body: JSON.stringify({ entries }) });
  } catch {
    // Offline: drop them rather than pile up.
  }

  // queue the next subset of the batch in a second
  if (diag.queue.length) diag.timer = setTimeout(flushReports, 1000);
}

window.addEventListener("pagehide", () => flushReports(true));
window.addEventListener("error", (e) =>
  report("error", "uncaught error", { error: String(e.message), at: `${e.filename?.split("/").pop()}:${e.lineno}` }));
window.addEventListener("unhandledrejection", (e) => report("error", "unhandled rejection", errorFields(e.reason)));


// ---------- general util ----------
// get the friend ID from an outbound or inbound message object
const friendOf = (m) => (m.sender_id === state.me.id ? m.recipient_id : m.sender_id);

// find chat object in our state array by its ID
const chatById = (id) => state.chats.find((c) => c.id === id);

// what I call a friend: my nickname for them, else their display name, else their username
const chatName = (c) => c.nickname || c.display_name || c.username;

// the same for anyone: friends by what I call them, me by my display name, others by username
function personName(id, username) {
  if (id === state.me?.id) return state.me.display_name || state.me.username;
  const c = chatById(id);
  return c ? chatName(c) : username;
}


// ---------- encryption ----------

const pinsKey = () => `pins:${state.me.id}`;
const pastPinsKey = () => `pastPins:${state.me.id}`;

async function loadPins() {
  state.pins = (await keystore.loadLocal(pinsKey()).catch(() => null)) || {};
  state.pastPins = (await keystore.loadLocal(pastPinsKey()).catch(() => null)) || {};
}

/**
 * Remember each friend's key the first time we see it. If the server later
 * hands out a different one, sending is blocked until I accept it: keys only
 * change when an admin resets an account, and a key the server swapped in
 * would let it read the chat.
 */
async function checkPins(chats) {
  let changed = false;
  for (const chat of chats) {
    const pinned = state.pins[chat.id];
    if (!pinned) {
      state.pins[chat.id] = chat.public_key;
      changed = true;
    }
    chat.keyChanged = Boolean(pinned) && pinned !== chat.public_key;
    if (chat.keyChanged) report("warn", "friend key changed; chat blocked", { friend_id: chat.id });
  }
  if (changed) await keystore.saveLocal(pinsKey(), state.pins);
}

/**
 * The new key becomes the pinned one; the old one stays, locally, to read the
 * messages it protected. Past keys only ever come from my own pins, never from
 * the server: a server-supplied "old key" could be used to forge old messages.
 */
// Note: in local testing, pastPins didn't get set even after I tried an admin reset
async function acceptNewKey(chat, verified) {
  const old = state.pins[chat.id];
  if (old && old !== chat.public_key) {
    state.pastPins[chat.id] = [...(state.pastPins[chat.id] || []), old];
  }

  state.pins[chat.id] = chat.public_key;
  
  await keystore.saveLocal(pinsKey(), state.pins);
  await keystore.saveLocal(pastPinsKey(), state.pastPins);

  state.pairKeys.delete(chat.id);
  state.readKeys.delete(chat.id);
  state.plaintext.clear();

  report("info", "friend key accepted", { friend_id: chat.id, verified });

  await refreshChats();

  if (state.activeId === chat.id) openChat(chat.id, { keepScroll: true });
}

/**
 * Keys that can read this chat's messages: the pinned key, then any I accepted
 * before it. A page of messages asks for them all at once, so what's kept is
 * the derivation itself: it runs once, and everyone waits on the same one. (A
 * friend not met yet is looked up first, outside it: a chat list loading its
 * own last messages must never wait on itself.)
 */
async function readKeysFor(friendId) {
  if (!state.readKeys.has(friendId) && !state.pins[friendId] && !chatById(friendId)) await refreshChats();
  return once(state.readKeys, friendId, async () => {
    const pinned = state.pins[friendId] || chatById(friendId)?.public_key;
    if (!pinned) throw new Error("Not a friend.");
    const publics = [pinned, ...[...(state.pastPins[friendId] || [])].reverse()];
    return Promise.all(publics.map((pub) => e2e.pairKey(state.identity.privateKey, pub, state.me.id, friendId)));
  });
}

/** `make()` for `key`, started at most once while it's kept in `map`; a failure isn't kept. */
function once(map, key, make) {
  let pending = map.get(key);
  if (!pending) {
    pending = make();
    map.set(key, pending);
    pending.catch(() => { if (map.get(key) === pending) map.delete(key); });
  }
  return pending;
}

/** Tries each reading key in turn. */
async function withReadKey(friendId, fn) {
  let last;
  for (const key of await readKeysFor(friendId)) {
    try {
      return await fn(key);
    } catch (err) {
      last = err;
    }
  }
  throw last;
}

async function keyFor(friendId) {
  if (state.pairKeys.has(friendId)) return state.pairKeys.get(friendId);
  if (!chatById(friendId)) await refreshChats();
  const chat = chatById(friendId);
  if (!chat) throw new Error("Not a friend.");
  if (chat.keyChanged) throw new Error(`${chat.username}'s safety code changed. Messages are blocked.`);
  return once(state.pairKeys, friendId, () => e2e.pairKey(state.identity.privateKey, chat.public_key, state.me.id, friendId));
}

/**
 * Adds `text` and `replyTo` to a text (null text if it can't be decrypted),
 * and `reactionList` ([{ user, emoji }]) to any message.
 */
async function decrypt(m) {
  await decryptReactions(m);
  if (m.kind !== "text") return m;
  // A newer app wrote this in a scheme this one doesn't know.
  m.unsupported = ![1, 2].includes(m.format ?? 1);
  if (m.unsupported) {
    m.text = null;
    return m;
  }
  if (!state.plaintext.has(m.id)) {
    let body = null;
    try {
      body = await withReadKey(friendOf(m), (k) => e2e.decryptAnyText(k, m.ciphertext, m.format ?? 1, m.sender_id, m.recipient_id));
    } catch (err) {
      if (!beforeMyReset(m)) report("warn", "decrypt failed", { message_id: m.id, friend_id: friendOf(m), ...errorFields(err) });
    }
    state.plaintext.set(m.id, body);
  }
  const body = state.plaintext.get(m.id);
  m.text = body?.text ?? null;
  m.originalText = m.text;
  m.replyTo = body?.replyTo ?? null;
  m.beforeReset = m.text == null && beforeMyReset(m);
  // Edited (X29): the newest version shows; the first stays in `originalText`.
  if (m.edit_ciphertext && m.text != null) {
    const key = `${m.id}:${m.edit_ciphertext}`; // unique per edit (two can share a second)
    if (!state.editText.has(key)) {
      let text = null;
      try {
        text = await withReadKey(friendOf(m), (k) => e2e.decryptEdit(k, m.edit_ciphertext, m.sender_id, m.recipient_id, m.id));
      } catch (err) {
        report("warn", "edit decrypt failed", { message_id: m.id, ...errorFields(err) });
      }
      state.editText.set(key, text);
    }
    if (state.editText.get(key) != null) {
      m.text = state.editText.get(key);
      m.edited = true;
    }
  }
  return m;
}

/** Reactions are encrypted too, bound to the message they're on. */
async function decryptReactions(m) {
  const out = [];
  for (const r of m.reactions || []) {
    // By its ciphertext, not its time: one changed within the same second is
    // another reaction, and showed as the last one (seen once any emoji could be picked).
    const cacheKey = `${m.id}:${r.sender_id}:${r.ciphertext}`;
    if (!state.reactionText.has(cacheKey)) {
      let emoji = null;
      try {
        const to = r.sender_id === state.me.id ? friendOf(m) : state.me.id;
        emoji = await withReadKey(friendOf(m), (k) => e2e.decryptReaction(k, r.ciphertext, r.sender_id, to, m.id));
      } catch {
        // unreadable reactions are just not shown
      }
      // Any one emoji (X49), not only the quick row: they may have picked it from the full list.
      state.reactionText.set(cacheKey, e2e.isReaction(emoji) ? emoji : null);
    }
    const emoji = state.reactionText.get(cacheKey);
    if (emoji) out.push({ user: r.sender_id, emoji });
  }
  m.reactionList = out;
}

/** An admin reset gave me a new key: what came before can't be read by anyone now. */
const beforeMyReset = (m) => Boolean(state.me?.key_reset_at) && m.created_at < state.me.key_reset_at;

async function loadIdentity() {
  const id = await keystore.loadLocal(IDENTITY_KEY).catch(() => null);
  if (!id || id.userId !== state.me.id) return false;
  state.identity = id;
  await forgetOtherAccounts(state.me.id);
  await loadPins();
  return true;
}

/** Signed in, and anything another account left here goes before this one
 * uses anything: pins an older napsack kept at sign-out (before 2026-11-06),
 * or what a tab still open as someone else wrote. */
async function forgetOtherAccounts(myId) {
  const mine = new Set([IDENTITY_KEY, `pins:${myId}`, `pastPins:${myId}`]);
  await Promise.allSettled([
    keystore.keepOnly((k) => mine.has(k)),
    // Kept answers are "<user id>:<what>", beside "me" (checked by its token) and the public "config".
    cache.keepOnly((k) => !/^\d+:/.test(k) || k.startsWith(`${myId}:`)),
  ]);
}

// ---------- auth ----------

let authMode = "login";

function showAuth() {
  $("#app").hidden = true;
  $("#auth").hidden = false;
  showRecover(false);
  setAuthMode("login");
}

// ---------- password strength (F23) ----------
// A hint while a new password is chosen, never a rule beyond the 8 characters
// the server asks for. Length counts most; a few unrelated words is the advice.
const COMMON_PASSWORDS = new Set(["password", "password1", "12345678", "123456789", "1234567890", "qwertyuiop",
  "qwerty123", "iloveyou", "11111111", "abc12345", "letmein1", "napsack1", "baseball", "football", "sunshine"]);

function passwordStrength(pw) {
  if (pw.length < 8) return { level: "short", text: "Too short: at least 8 characters." };
  const kinds = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter((r) => r.test(pw)).length;
  if (COMMON_PASSWORDS.has(pw.toLowerCase()) || new Set(pw).size <= 3) {
    return { level: "weak", text: "Easy to guess. A few unrelated words make a strong one." };
  }
  if (pw.length >= 16 || (pw.length >= 12 && kinds >= 3)) return { level: "strong", text: "Strong." };
  if (pw.length >= 12 || (pw.length >= 10 && kinds >= 3)) return { level: "good", text: "Good. Longer is even better." };
  return { level: "weak", text: "Weak. Longer is stronger: try a few unrelated words." };
}

function showStrength(input, hint) {
  const value = input.value;
  hint.hidden = !value;
  if (!value) return;
  const { level, text } = passwordStrength(value);
  hint.textContent = text;
  hint.dataset.level = level;
}

$("#auth-form").password.addEventListener("input", (e) => {
  if (authMode === "register") showStrength(e.target, $("#password-strength"));
});
$("#password-form").change_password.addEventListener("input", (e) => showStrength(e.target, $("#change-strength")));

function setAuthMode(mode) {
  authMode = mode;
  const register = mode === "register";
  $("#auth-submit").textContent = register ? "Create account" : "Sign in";
  $("#auth-toggle").textContent = register
    ? "Have an account? Sign in"
    : "New here? Create an account";
  $("#invite-field").hidden = !(register && state.config?.invite_required && !state.invite?.inviter);
  $("#password-hint").hidden = !register;
  $("#password-strength").hidden = true;
  $("#auth-form").password.autocomplete = register ? "new-password" : "current-password";
  $("#auth-error").textContent = "";
  renderPasskeySignIn();
}

$("#auth-toggle").addEventListener("click", () =>
  setAuthMode(authMode === "login" ? "register" : "login"));

$("#auth-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.currentTarget;
  const submit = $("#auth-submit");
  const label = submit.textContent;
  const register = authMode === "register";
  const username = form.username.value.trim();
  const password = form.password.value;
  $("#auth-error").textContent = "";
  // People type their email here (seen in the logs, plan X32). Usernames can't
  // hold an @, so say so before spending a sign-in attempt on it.
  if (username.includes("@")) {
    $("#auth-error").textContent = register
      ? "Pick a username, not an email address: letters, numbers, _ and . only."
      : "That's an email address. Sign in with your napsack username instead.";
    return;
  }
  if (register && password.length < 8) {
    $("#auth-error").textContent = "Passwords need at least 8 characters.";
    return;
  }
  submit.disabled = true;
  submit.textContent = register ? "Creating your keys…" : "Unlocking…";
  try {
    // The password stays here. The server gets a key derived from it.
    const { authKey, wrapKey } = await e2e.deriveFromPassword(username, password);
    let res, privateKey;
    if (register) {
      const identity = await e2e.createIdentity(wrapKey);
      privateKey = identity.privateKey;
      res = await getJSON("/auth/register", {
        method: "POST",
        json: {
          username,
          auth_key: authKey,
          invite_code: state.config?.invite_required && !state.invite?.inviter ? form.invite_code.value.trim() : undefined,
          invite_token: state.invite?.inviter ? state.invite.token : undefined,
          public_key: identity.publicKey,
          wrapped_private_key: identity.wrappedPrivateKey,
        },
      });
    } else {
      res = await getJSON("/auth/login", { method: "POST", json: { username, auth_key: authKey } });
      try {
        privateKey = await e2e.unwrapIdentity(wrapKey, res.wrapped_private_key);
      } catch {
        throw new Error("Couldn't unlock your keys. Check your password.");
      }
    }
    await startSession(res, privateKey);
    form.reset();
    report("info", register ? "signed up" : "signed in");
    // New accounts get a recovery key right away, while the password is at hand.
    const recoveryKey = register ? await setUpRecovery(authKey, wrapKey, res.wrapped_private_key).catch(() => null) : null;
    const invitedBy = register ? state.invite?.inviter : null;
    if (invitedBy) state.invite = null; // used: we're friends now
    enterApp();
    // Then a passkey is recommended (F26), made with these same keys, so the
    // password isn't asked again. Decided now, so it follows the recovery key at once.
    const offer = register && await canOfferPasskey()
      ? () => offerPasskey({ authKey, wrapKey, wrapped: res.wrapped_private_key })
      : null;
    if (recoveryKey) await showRecoveryKey(recoveryKey, offer);
    else offer?.();
    if (invitedBy) {
      await refreshChats();
      openChat(invitedBy.id);
    }
  } catch (err) {
    report("info", register ? "sign-up failed" : "sign-in failed", errorFields(err));
    $("#auth-error").textContent = err.message;
  } finally {
    submit.disabled = false;
    submit.textContent = label;
  }
});

async function startSession(res, privateKey) {
  // Whatever this browser still holds belongs to no one signed in here: an
  // earlier account's pins (an older napsack kept them), what a tab that never
  // signed out wrote. It goes before anything of this account is kept or used.
  await forgetKept();
  state.token = res.token;
  state.me = res.user;
  state.identity = { userId: res.user.id, privateKey, publicKey: res.public_key };
  await keystore.saveLocal(IDENTITY_KEY, state.identity);
  await loadPins();
  localStorage.setItem(TOKEN_KEY, res.token);
}

// ---------- recovery key, password, reset ----------

/** Makes and registers a recovery key. Returns it, for showing once. */
async function setUpRecovery(authKey, wrapKey, wrappedPrivateKey) {
  const recoveryKey = e2e.newRecoveryKey();
  const rec = await e2e.deriveFromRecoveryKey(recoveryKey);
  const recoveryWrapped = await e2e.wrapForRecovery(wrapKey, wrappedPrivateKey, rec.wrapKey);
  await api("/me/recovery", {
    method: "PUT",
    json: { auth_key: authKey, recovery_auth_key: rec.authKey, recovery_wrapped_key: recoveryWrapped },
  });
  state.me.has_recovery_key = true;
  renderAccountBar();
  report("info", "recovery key set");
  return recoveryKey;
}

/** Shows the key until the person says they saved it; then `next`, if given (sign-up's passkey offer). */
function showRecoveryKey(recoveryKey, next = null) {
  const dialog = $("#recovery-dialog");
  $("#recovery-key").textContent = recoveryKey;
  $("#recovery-saved").checked = false;
  $("#recovery-done").disabled = true;
  $("#recovery-copy").textContent = "Copy";
  afterRecoveryKey = next;
  dialog.showModal();
  return new Promise((resolve) => dialog.addEventListener("close", () => {
    $("#recovery-key").textContent = ""; // don't leave it in the page
    runAfterRecoveryKey(); // closed with Escape: Done runs it itself
    resolve();
  }, { once: true }));
}

// What follows the recovery key, run as its dialog closes. Done runs it in the
// same moment, so one sheet replaces the other with nothing in between.
let afterRecoveryKey = null;
function runAfterRecoveryKey() {
  const next = afterRecoveryKey;
  afterRecoveryKey = null;
  next?.();
}

$("#recovery-saved").addEventListener("change", (e) => { $("#recovery-done").disabled = !e.target.checked; });
// A file to keep with your other important things (F23): the key, and what it's for.
$("#recovery-download").addEventListener("click", () => {
  const key = $("#recovery-key").textContent;
  const text = `napsack recovery key for ${state.me?.username ?? "your account"}\n\n${key}\n\n`
    + "If you forget your password, choose \"Forgot your password?\" when you sign in and enter this key: "
    + "you get back in with all your messages. Keep it somewhere safe and private.\n";
  const link = el("a", { href: URL.createObjectURL(new Blob([text], { type: "text/plain" })), download: "napsack-recovery-key.txt" });
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
});
$("#recovery-done").addEventListener("click", () => {
  $("#recovery-dialog").close();
  runAfterRecoveryKey();
});
// Escape doesn't dismiss it before it's saved.
$("#recovery-dialog").addEventListener("cancel", (e) => { if (!$("#recovery-saved").checked) e.preventDefault(); });
$("#recovery-copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("#recovery-key").textContent);
    $("#recovery-copy").textContent = "Copied";
  } catch {
    $("#recovery-copy").textContent = "Select it and copy";
  }
});

/** The password proves itself to the server, which returns the wrapped key to work with. */
async function unlockWithPassword(password) {
  const { authKey, wrapKey } = await e2e.deriveFromPassword(state.me.username, password);
  const { wrapped_private_key: wrapped } = await getJSON("/auth/unlock", { method: "POST", json: { auth_key: authKey } });
  return { authKey, wrapKey, wrapped };
}

let passwordMode = "recovery";

function openPasswordDialog(mode) {
  passwordMode = mode;
  const change = mode === "change";
  const passkey = mode === "passkey";
  $("#password-form").reset();
  $("#change-strength").hidden = true;
  $("#password-error").textContent = "";
  $("#password-title").textContent = change ? "Change password" : passkey ? "Add a passkey" : "Recovery key";
  $("#password-text").textContent = change
    ? "Your messages stay readable: your key is locked again under the new password. Other devices will be signed out."
    : passkey
      ? "Enter your password, then let your device make the passkey. Next time, sign in with it instead of your password."
      : state.me.has_recovery_key
        ? "Making a new recovery key replaces your old one, which stops working. Enter your password to continue."
        : "Enter your password to make a recovery key.";
  $("#password-new-field").hidden = !change;
  $("#password-confirm-field").hidden = !change;
  $("#password-submit").textContent = change ? "Change password" : passkey ? "Add a passkey" : "Make a recovery key";
  $("#password-dialog").showModal();
}

$("#password-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.currentTarget;
  const btn = $("#password-submit");
  const label = btn.textContent;
  const change = passwordMode === "change";
  $("#password-error").textContent = "";
  if (change && form.change_password.value.length < 8) {
    $("#password-error").textContent = "Passwords need at least 8 characters.";
    return;
  }
  if (change && form.change_password.value !== form.change_confirm.value) {
    $("#password-error").textContent = "The new passwords don't match.";
    return;
  }
  btn.disabled = true;
  btn.textContent = "Unlocking…";
  try {
    const current = await unlockWithPassword(form.current_password.value);
    if (change) {
      const next = await e2e.deriveFromPassword(state.me.username, form.change_password.value);
      const rewrapped = await e2e.rewrapIdentity(current.wrapKey, current.wrapped, next.wrapKey);
      const res = await getJSON("/me/password", {
        method: "POST",
        json: { auth_key: current.authKey, new_auth_key: next.authKey, new_wrapped_private_key: rewrapped },
      });
      $("#password-dialog").close();
      report("info", "password changed");
      showSecurityNote(`Password changed.${res.sessions_ended ? ` Signed out ${res.sessions_ended} other ${res.sessions_ended === 1 ? "device" : "devices"}.` : ""}`);
    } else if (passwordMode === "passkey") {
      btn.textContent = "Waiting for your passkey…";
      if (!await addPasskey(current)) return; // the system's sheet was closed: still here to try again
      $("#password-dialog").close();
      $("#passkey-note").textContent = "Passkey added.";
      loadPasskeys();
    } else {
      const key = await setUpRecovery(current.authKey, current.wrapKey, current.wrapped);
      $("#password-dialog").close();
      await showRecoveryKey(key);
      showSecurityNote("Recovery key saved.");
    }
  } catch (err) {
    $("#password-error").textContent = err.message;
  } finally {
    btn.disabled = false;
    btn.textContent = label;
  }
});

// ---------- passkeys (F26, docs/design/passkeys.md) ----------
// Signing in with Face ID, a fingerprint, or a security key instead of the
// password. A passkey has to unlock the private key too, so each one keeps its
// own copy of it on the server, wrapped by a secret only that passkey gives
// (WebAuthn's PRF extension; crypto.js), which the server never sees. Adding
// one needs the password, as a recovery key does. A passkey that can't give
// the secret is never used: napsack says so, and the password still works.

/** What this browser can do, known moments after the page loads: `use`
 * passkeys at all (WebAuthn, with PRF not ruled out), and `make` one on the
 * device itself (Face ID, a fingerprint), which sign-up recommends. */
const passkeySupport = { use: false, make: false };
const passkeysKnown = (async () => {
  const P = window.PublicKeyCredential;
  if (!P || !navigator.credentials?.get) return;
  try {
    // Browsers that list what they can do say outright when PRF isn't there.
    if ((await P.getClientCapabilities?.())?.["extension:prf"] === false) return;
  } catch { /* not said: tried, and a passkey without it is caught then */ }
  passkeySupport.use = true;
  try {
    passkeySupport.make = Boolean(await P.isUserVerifyingPlatformAuthenticatorAvailable?.());
  } catch { /* none on the device itself, then */ }
})();
passkeysKnown.then(() => { renderPasskeySignIn(); renderPasskeys(); });

/** Passkeys work on this page: the browser can, the server names its site
 * (`passkey_rp_id`), and this page is on it. A passkey belongs to a name,
 * never an address: in development, open http://localhost, not 127.0.0.1. */
function passkeysHere() {
  const rp = state.config?.passkey_rp_id;
  return passkeySupport.use && Boolean(rp) && location.hostname === rp;
}

/** Sign-up's recommendation is for a device that makes passkeys itself. */
async function canOfferPasskey() {
  // Known long since (making the keys took longer); a browser that never says isn't waited on.
  await Promise.race([passkeysKnown, sleep(1000)]);
  return passkeySupport.make && passkeysHere();
}

function renderPasskeySignIn() {
  $("#passkey-sign-in").hidden = !(authMode === "login" && passkeysHere());
}

// WebAuthn's bytes travel as base64url without padding (the key's copy as plain base64).
function b64url(bytes) {
  return e2e.toB64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function fromB64url(text) {
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/");
  return e2e.fromB64(b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), "="));
}

/** The same 32 bytes every time; each passkey turns them into its own secret. */
let prfInput = null;
const passkeyPrfInput = () => (prfInput ??= e2e.passkeyPrfInput());

/** The person closed the system's passkey sheet (or it timed out): not a problem to show. */
const passkeyCancelled = (err) => err?.name === "NotAllowedError" || err?.name === "AbortError";

/** Anything else the browser refused: plain words for the person, the details for us. */
function passkeyTrouble(err, at) {
  report("warn", "passkey refused by the browser", { at, name: err?.name, ...errorFields(err) });
  return new Error("Passkeys aren't working in this browser right now. Your password still works.");
}

/** An error that trying again on this device won't fix. */
const finalError = (text) => Object.assign(new Error(text), { final: true });

/** Tells the password manager a passkey doesn't work here any more, so it can
 * drop it too (WebAuthn's signal API, where the browser has it). */
function forgetPasskey(rpId, credentialId) {
  const P = window.PublicKeyCredential;
  if (!rpId || typeof P?.signalUnknownCredential !== "function") return;
  P.signalUnknownCredential({ rpId, credentialId }).catch(() => {});
}

const NO_PRF_HERE = "This device's passkeys can't unlock your messages, so napsack can't use them here. Your password still works.";

/**
 * Makes a passkey for this account and gives it its own copy of the private
 * key, with the password's keys in hand: `authKey`, `wrapKey`, and the
 * password-wrapped key. Returns false if the person closed the system's
 * sheet; throws, in plain words, when it can't be done (`final` when trying
 * again on this device won't help).
 */
async function addPasskey({ authKey, wrapKey, wrapped }) {
  const o = await getJSON("/me/passkeys/options", { method: "POST" });
  const input = await passkeyPrfInput();
  let cred;
  try {
    cred = await navigator.credentials.create({
      publicKey: {
        rp: { id: o.rp_id, name: o.rp_name },
        user: { id: fromB64url(o.user_id), name: o.user_name, displayName: o.user_name },
        challenge: fromB64url(o.challenge),
        pubKeyCredParams: [{ type: "public-key", alg: -7 }], // ES256, what the server checks
        authenticatorSelection: { residentKey: "required", requireResidentKey: true, userVerification: "required" },
        attestation: "none",
        excludeCredentials: (o.exclude ?? []).map((id) => ({ type: "public-key", id: fromB64url(id) })),
        extensions: { prf: { eval: { first: input } } },
      },
    });
  } catch (err) {
    if (passkeyCancelled(err)) return false;
    if (err?.name === "InvalidStateError") throw finalError("This device already has a passkey for napsack.");
    throw passkeyTrouble(err, "add");
  }
  if (!cred) return false;
  // From here, stopping leaves a passkey napsack doesn't know: its manager is told to drop it.
  const orphan = () => forgetPasskey(o.rp_id, cred.id);
  let secret;
  try {
    const prf = cred.getClientExtensionResults().prf;
    secret = prf?.results?.first;
    // Some turn PRF on when made but answer only when used: ask this one, once.
    if (!secret && prf?.enabled) secret = await evaluatePrf(o.rp_id, cred.rawId, input);
  } catch (err) {
    orphan();
    if (passkeyCancelled(err)) return false;
    throw passkeyTrouble(err, "add");
  }
  if (!secret) {
    orphan();
    report("info", "passkey without prf", { at: "add" });
    throw finalError(NO_PRF_HERE);
  }
  let wrappedKey;
  try {
    wrappedKey = await e2e.wrapForPasskey(wrapKey, wrapped, await e2e.deriveFromPasskey(secret));
  } catch (err) {
    orphan();
    report("warn", "passkey wrap failed", errorFields(err));
    throw new Error("That passkey couldn't be added. Try again.");
  } finally {
    new Uint8Array(secret).fill(0); // the secret isn't kept, in memory either
  }
  try {
    const res = await getJSON("/me/passkeys", {
      method: "POST",
      json: {
        auth_key: authKey,
        client_data_json: b64url(cred.response.clientDataJSON),
        attestation_object: b64url(cred.response.attestationObject),
        wrapped_key: wrappedKey,
      },
    });
    report("info", "passkey added", { provider: res.provider ?? "unknown" });
    return true;
  } catch (err) {
    // Refused. (Not a lost answer, which may have been stored, nor "already added".)
    if (err.status >= 400 && err.status !== 409) orphan();
    throw err;
  }
}

/** Asks one passkey for its PRF answer alone. The challenge goes nowhere. */
async function evaluatePrf(rpId, rawId, input) {
  const got = await navigator.credentials.get({
    publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      rpId,
      allowCredentials: [{ type: "public-key", id: rawId }],
      userVerification: "required",
      extensions: { prf: { eval: { first: input } } },
    },
  });
  return got?.getClientExtensionResults().prf?.results?.first ?? null;
}

/** Signing in with any passkey the device has for napsack, then opening the
 * private key with that passkey's secret: the same session as the password's. */
async function signInWithPasskey() {
  const btn = $("#passkey-sign-in");
  const submit = $("#auth-submit");
  if (btn.disabled || submit.disabled) return;
  $("#auth-error").textContent = "";
  btn.disabled = submit.disabled = true;
  btn.textContent = "Waiting for your passkey…";
  let secret = null;
  try {
    const o = await getJSON("/auth/passkey/options", { method: "POST" });
    let cred;
    try {
      cred = await navigator.credentials.get({
        publicKey: {
          challenge: fromB64url(o.challenge),
          rpId: o.rp_id,
          userVerification: "required",
          // No list: the device offers whichever passkeys it has for napsack.
          extensions: { prf: { eval: { first: await passkeyPrfInput() } } },
        },
      });
    } catch (err) {
      if (passkeyCancelled(err)) return;
      throw passkeyTrouble(err, "sign-in");
    }
    if (!cred) return;
    secret = cred.getClientExtensionResults().prf?.results?.first ?? null;
    if (!secret) {
      // Without its secret the key can't be opened, so the server isn't asked at all.
      report("info", "passkey without prf", { at: "sign-in" });
      throw new Error("This passkey can't unlock napsack here. Sign in with your password.");
    }
    btn.textContent = "Unlocking…";
    const res = await getJSON("/auth/passkey", {
      method: "POST",
      json: {
        credential_id: b64url(cred.rawId),
        client_data_json: b64url(cred.response.clientDataJSON),
        authenticator_data: b64url(cred.response.authenticatorData),
        signature: b64url(cred.response.signature),
      },
    });
    let privateKey;
    try {
      privateKey = await e2e.unwrapWithPasskey(await e2e.deriveFromPasskey(secret), res.passkey_wrapped_key);
    } catch {
      // A session that can't read anything is no use: it ends here.
      api("/auth/logout", { method: "POST", headers: { Authorization: `Bearer ${res.token}` } }).catch(() => {});
      report("warn", "passkey couldn't unlock the key");
      throw new Error("This passkey couldn't unlock your messages. Sign in with your password.");
    }
    await startSession(res, privateKey);
    $("#auth-form").reset();
    report("info", "signed in with a passkey");
    enterApp();
  } catch (err) {
    report("info", "passkey sign-in failed", errorFields(err));
    $("#auth-error").textContent = err.message;
  } finally {
    if (secret) new Uint8Array(secret).fill(0);
    btn.disabled = submit.disabled = false;
    btn.textContent = "Sign in with a passkey";
  }
}

$("#passkey-sign-in").addEventListener("click", signInWithPasskey);

// Right after sign-up: a passkey, recommended, with the sign-up's keys still in hand.
const passkeyOffer = { keys: null };

function offerPasskey(keys) {
  passkeyOffer.keys = keys;
  $("#passkey-offer-text").textContent = "Next time, sign in with Face ID or your fingerprint instead of your password. "
    + "It unlocks your messages too, and your password keeps working.";
  $("#passkey-offer-error").textContent = "";
  $("#passkey-offer-add").hidden = false;
  $("#passkey-offer-later").textContent = "Not now";
  $("#passkey-offer").showModal();
  report("info", "passkey offered");
}

$("#passkey-offer-add").addEventListener("click", async () => {
  const btn = $("#passkey-offer-add");
  const keys = passkeyOffer.keys;
  if (!keys || btn.disabled) return;
  btn.disabled = true;
  btn.textContent = "Waiting for your passkey…";
  $("#passkey-offer-error").textContent = "";
  try {
    if (!await addPasskey(keys)) return; // the system's sheet was closed: the offer stands
    passkeyOffer.keys = null;
    $("#passkey-offer-text").textContent = "Passkey added. Next time, choose “Sign in with a passkey”.";
    btn.hidden = true;
    $("#passkey-offer-later").textContent = "Done";
  } catch (err) {
    $("#passkey-offer-error").textContent = err.message;
    if (err.final) {
      passkeyOffer.keys = null;
      btn.hidden = true;
      $("#passkey-offer-later").textContent = "OK";
    }
  } finally {
    btn.disabled = false;
    btn.textContent = "Add a passkey";
  }
});
$("#passkey-offer-later").addEventListener("click", () => $("#passkey-offer").close());
$("#passkey-offer").addEventListener("close", () => {
  if (passkeyOffer.keys) report("info", "passkey offer declined");
  passkeyOffer.keys = null; // the password's keys aren't kept past the offer
});

// Security › Passkeys: every one on the account, from any device. Only in
// memory, and only the server's latest answer is shown.
const passkeyList = { items: null, rp: null, loads: 0 };

async function loadPasskeys() {
  const asked = ++passkeyList.loads;
  let res;
  try {
    res = await getJSON("/me/passkeys");
  } catch (err) {
    report("warn", "loading passkeys failed", errorFields(err));
    // Shown only when there's no list at all: an empty one would look like none are set up.
    if (asked === passkeyList.loads && !passkeyList.items) $("#passkey-note").textContent = PASSKEYS_UNLOADED;
    return;
  }
  if (asked !== passkeyList.loads) return; // a newer answer is on its way
  if ($("#passkey-note").textContent === PASSKEYS_UNLOADED) $("#passkey-note").textContent = "";
  passkeyList.items = res.passkeys;
  passkeyList.rp = res.rp_id;
  renderPasskeys();
}

const PASSKEYS_UNLOADED = "Couldn't load your passkeys. Check your connection and open this again.";

function renderPasskeys() {
  // Where none can be made, say why; the list stays, so any can still be removed.
  const here = passkeysHere();
  const rp = state.config?.passkey_rp_id;
  $("#passkey-add-row").hidden = !here;
  $("#passkey-unavailable").hidden = here;
  $("#passkey-unavailable").textContent = here ? ""
    : passkeySupport.use && rp ? `Passkeys for napsack work only at ${rp}. Your password works everywhere.`
    : "This browser can't use passkeys for napsack. Your password works everywhere.";
  const list = $("#passkey-list");
  const items = passkeyList.items;
  if (!items) {
    list.replaceChildren(); // nothing claimed before the server answers
    return;
  }
  if (!items.length) {
    list.replaceChildren(el("li", { class: "passkey-none", text: "No passkeys yet." }));
    return;
  }
  // Merged into what's shown, so a "Tap again" already showing stays.
  const shown = new Map([...list.querySelectorAll("li[data-id]")].map((li) => [li.dataset.id, li]));
  list.replaceChildren(...items.map((p) => {
    const li = shown.get(String(p.id)) ?? passkeyRow(p);
    $(".person-name", li).textContent = p.provider || "Passkey";
    // Each part kept whole (no-break spaces), so a phone wraps between them.
    $(".person-meta", li).textContent = [
      `Added ${dayName(p.created_at)}`,
      p.last_used_at ? `last used ${dayName(p.last_used_at)}` : "not used yet",
    ].map((part) => part.replace(/ /g, "\u00a0")).join(" · ");
    return li;
  }));
}

/** "today", "yesterday", or the date. */
function dayName(ts) {
  const midnight = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const ago = Math.round((midnight(new Date()) - midnight(new Date(ts * 1000))) / 86_400_000);
  return ago === 0 ? "today" : ago === 1 ? "yesterday" : longDate(ts);
}

function passkeyRow(p) {
  const remove = el("button", { type: "button", class: "button", onclick: () => removePasskey(remove, p) }, "Remove");
  return el("li", { class: "person passkey", "data-id": String(p.id) },
    el("span", { class: "passkey-text" }, el("span", { class: "person-name" }), el("span", { class: "person-meta" })),
    remove);
}

/** Two taps, like removing someone from a group. */
async function removePasskey(btn, p) {
  if (!btn.dataset.confirm) {
    btn.dataset.confirm = "1";
    btn.textContent = "Tap again to remove";
    btn.classList.add("danger");
    return;
  }
  btn.disabled = true;
  $("#passkey-note").textContent = "";
  try {
    await api(`/me/passkeys/${p.id}/remove`, { method: "POST" });
  } catch (err) {
    $("#passkey-note").textContent = err.message;
    btn.disabled = false;
    loadPasskeys(); // it may be gone already
    return;
  }
  report("info", "passkey removed");
  forgetPasskey(passkeyList.rp ?? state.config?.passkey_rp_id, p.credential_id);
  passkeyList.items = passkeyList.items?.filter((x) => x.id !== p.id) ?? null;
  renderPasskeys();
  $("#passkey-note").textContent = "Passkey removed.";
  loadPasskeys();
}

$("#passkey-add").addEventListener("click", () => {
  $("#passkey-note").textContent = "";
  openPasswordDialog("passkey");
});

// ---------- deleting your own account (F22) ----------
// What goes, then the password (checked by the server) and the username typed
// again; the button only works once both are filled in and the name matches.

function deleteReady() {
  const form = $("#delete-form");
  return form.delete_password.value.length > 0
    && form.delete_username.value.trim().toLowerCase() === state.me.username.toLowerCase();
}

$("#delete-account").addEventListener("click", () => {
  $("#delete-form").reset();
  $("#delete-error").textContent = "";
  $("#delete-username-label").textContent = `Type your username, ${state.me.username}`;
  $("#delete-submit").disabled = true;
  $("#delete-dialog").showModal();
});
$("#delete-form").addEventListener("input", () => { $("#delete-submit").disabled = !deleteReady(); });
$("#delete-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  if (!deleteReady()) return;
  const form = e.currentTarget;
  const btn = $("#delete-submit");
  btn.disabled = true;
  btn.textContent = "Deleting…";
  $("#delete-error").textContent = "";
  try {
    const { authKey } = await e2e.deriveFromPassword(state.me.username, form.delete_password.value);
    await getJSON("/me/delete", { method: "POST", json: { auth_key: authKey, username: form.delete_username.value.trim() } });
    await signOutLocally("Your account was deleted. Everything of yours is gone from napsack.");
  } catch (err) {
    $("#delete-error").textContent = err.message;
    btn.textContent = "Delete my account forever";
    btn.disabled = !deleteReady();
  }
});

$("#recovery-nudge-button").addEventListener("click", () => openPasswordDialog("recovery"));
$("#security-recovery").addEventListener("click", () => openPasswordDialog("recovery"));
$("#security-password").addEventListener("click", () => openPasswordDialog("change"));
$("#security-sessions").addEventListener("click", async () => {
  try {
    const res = await getJSON("/me/sessions/end-others", { method: "POST" });
    showSecurityNote(res.sessions_ended
      ? `Signed out ${res.sessions_ended} other ${res.sessions_ended === 1 ? "device" : "devices"}.`
      : "No other devices were signed in.");
  } catch (err) {
    showSecurityNote(err.message);
  }
});

function showSecurityNote(text) {
  if ($("#profile-dialog").open) {
    $("#security-note").textContent = text;
    renderSecurity();
  }
}

// ---------- changing your username (X30) ----------
// The username salts the password, so a new one locks the private key again
// under it, like a password change. Old names stay yours (usernames.rs).

function renderUsername(p) {
  const later = p.next_rename_at && p.next_rename_at * 1000 > Date.now();
  $("#username-status").textContent = [
    `Your username is @${p.username}.`,
    later ? `You can change it again on ${longDate(p.next_rename_at)}.` : "",
  ].filter(Boolean).join(" ");
  $("#username-change").hidden = Boolean(later);
  $("#username-form").hidden = true;
}

$("#username-change").addEventListener("click", () => {
  const form = $("#username-form");
  form.reset();
  $("#username-error").textContent = "";
  form.hidden = false;
  $("#username-change").hidden = true;
  form.username.focus();
});
$("#username-cancel").addEventListener("click", () => {
  $("#username-form").hidden = true;
  $("#username-change").hidden = false;
});

$("#username-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.currentTarget;
  const btn = $("#username-submit");
  const username = form.username.value.trim();
  $("#username-error").textContent = "";
  if (!/^[A-Za-z0-9_.]{3,20}$/.test(username)) {
    $("#username-error").textContent = "Usernames are 3 to 20 characters: letters, numbers, dots, and underscores.";
    return;
  }
  btn.disabled = true;
  btn.textContent = "Locking your keys…";
  try {
    const password = form.password.value;
    const current = await unlockWithPassword(password);
    const next = await e2e.deriveFromPassword(username, password);
    const rewrapped = await e2e.rewrapIdentity(current.wrapKey, current.wrapped, next.wrapKey);
    const res = await getJSON("/me/username", {
      method: "POST",
      json: { username, auth_key: current.authKey, new_auth_key: next.authKey, new_wrapped_private_key: rewrapped },
    });
    report("info", "username changed");
    state.me.username = res.username;
    await refreshMe();
    await openProfile(state.me.id);
    showSecurityNote(`Your username is now @${res.username}. Sign in with it from now on.`);
  } catch (err) {
    $("#username-error").textContent = err.message;
  } finally {
    btn.disabled = false;
    btn.textContent = "Change username";
  }
});

async function renderSecurity() {
  $("#share-activity").checked = Boolean(state.me.share_activity);
  renderPushStatus();
  renderPasskeys(); // what's known at once, then the server's answer
  loadPasskeys();
  $("#blocked-list").replaceChildren(); // reopened: no "Tap again" left armed from before
  renderBlocks(); // what's known at once, then the server's answer
  loadBlocks();
  $("#security-status").textContent = state.me.has_recovery_key ? "Recovery key saved." : "No recovery key yet.";
  try {
    const s = await getJSON("/me/security");
    const others = s.active_sessions - 1;
    $("#security-status").textContent = [
      s.recovery_set_at ? `Recovery key saved ${longDate(s.recovery_set_at)}.` : "No recovery key yet.",
      others > 0 ? `Signed in on ${others} other ${others === 1 ? "device" : "devices"}.` : "Not signed in anywhere else.",
    ].join(" ");
  } catch (err) {
    report("warn", "loading security failed", errorFields(err));
  }
}

// Signed out: back in with a recovery key (everything) or an admin's reset code (no history).
const secretKind = (text) => {
  const n = String(text).replace(/[\s-]/g, "").length;
  return n === 32 ? "recovery" : n === 16 ? "code" : null;
};

function showRecover(on) {
  $("#auth-form").hidden = on;
  $("#auth-toggle").hidden = on;
  $("#auth-forgot").hidden = on;
  $("#recover-form").hidden = !on;
  $("#recover-back").hidden = !on;
  $("#recover-error").textContent = "";
  $("#recover-kind").textContent = "";
  if (on) $("#recover-form").recover_username.value = $("#auth-form").username.value;
}

$("#auth-forgot").addEventListener("click", () => showRecover(true));
$("#recover-back").addEventListener("click", () => showRecover(false));
$("#recover-secret").addEventListener("input", (e) => {
  const kind = secretKind(e.target.value);
  $("#recover-kind").textContent = kind === "recovery"
    ? "Recovery key: you'll keep all your messages."
    : kind === "code"
      ? "Reset code: you'll get your account and friends back, but messages from before can't be read, and your friends will see a new safety code."
      : "";
});

$("#recover-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.currentTarget;
  const btn = $("#recover-submit");
  const username = form.recover_username.value.trim();
  const secret = form.secret.value;
  const kind = secretKind(secret);
  $("#recover-error").textContent = "";
  if (!kind) {
    $("#recover-error").textContent = "Recovery keys are 32 letters and numbers; reset codes are 16.";
    return;
  }
  if (form.new_password.value.length < 8) {
    $("#recover-error").textContent = "Passwords need at least 8 characters.";
    return;
  }
  if (form.new_password.value !== form.new_confirm.value) {
    $("#recover-error").textContent = "The new passwords don't match.";
    return;
  }
  btn.disabled = true;
  btn.textContent = "Unlocking…";
  try {
    const next = await e2e.deriveFromPassword(username, form.new_password.value);
    let res, privateKey, recoveryKey = null;
    if (kind === "recovery") {
      const rec = await e2e.deriveFromRecoveryKey(secret);
      const start = await getJSON("/auth/recover/start", { method: "POST", json: { username, recovery_auth_key: rec.authKey } });
      let got;
      try {
        got = await e2e.recoverIdentity(rec.wrapKey, start.recovery_wrapped_key, next.wrapKey);
      } catch {
        throw new Error("That recovery key couldn't unlock your account.");
      }
      res = await getJSON("/auth/recover/finish", {
        method: "POST",
        json: { username, recovery_auth_key: rec.authKey, new_auth_key: next.authKey, new_wrapped_private_key: got.wrappedPrivateKey },
      });
      privateKey = got.privateKey;
    } else {
      // A fresh key pair: the old one is locked behind the forgotten password.
      const identity = await e2e.createIdentity(next.wrapKey);
      res = await getJSON("/auth/reset", {
        method: "POST",
        json: { username, code: secret, new_auth_key: next.authKey, public_key: identity.publicKey, wrapped_private_key: identity.wrappedPrivateKey },
      });
      privateKey = identity.privateKey;
    }
    await startSession(res, privateKey);
    if (kind === "code") recoveryKey = await setUpRecovery(next.authKey, next.wrapKey, res.wrapped_private_key).catch(() => null);
    form.reset();
    report("info", kind === "recovery" ? "recovered with recovery key" : "reset with code");
    showRecover(false);
    enterApp();
    if (recoveryKey) await showRecoveryKey(recoveryKey);
  } catch (err) {
    $("#recover-error").textContent = err.message;
  } finally {
    btn.disabled = false;
    btn.textContent = "Get back in";
  }
});

// Signing out, or a session the server ended: everything napsack kept in this
// browser goes, then the page starts over, so nothing of this account is left
// for whoever signs in next. Not on the device: the token, the private key,
// the pinned keys (Nate, 2026-11-06: pins go too), the kept chats (cache.js),
// settings, both databases themselves, anything in Cache Storage or cookies
// (napsack keeps nothing there, but nothing of the site's stays), this
// browser's push subscription, and the notifications on screen. Not in memory:
// the reload leaves no state behind, whatever later code adds to it. Other
// tabs start over too (the "storage" listener below). `notice` ("Your session
// ended") is the one thing carried across, to show on the sign-in screen.
const SIGNED_OUT_NOTICE_KEY = "napsack.signedOutNotice";
let signingOut = null;

function signOutLocally(notice = null) {
  signingOut ??= forgetEverything(notice); // several failing requests at once end it once
  return signingOut;
}

async function forgetEverything(notice) {
  $("#app").hidden = true; // nothing of theirs stays on screen while it goes
  afterRecoveryKey = null; // closing the recovery key's dialog mustn't open the passkey offer
  for (const d of document.querySelectorAll("dialog[open]")) d.close();
  const ws = state.ws;
  state.ws = null;
  ws?.close();
  clearInterval(conn.heartbeat);
  clearNotifications(); // they name friends
  await Promise.allSettled([
    keystore.forget(),
    cache.forget(),
    navigator.serviceWorker?.getRegistration()
      .then((reg) => reg?.pushManager.getSubscription())
      .then((sub) => sub?.unsubscribe()),
  ]);
  // Emptied first, so even a database another tab is slow to let go of holds nothing meanwhile.
  await Promise.allSettled([dropDatabases(), forgetCacheStorage()]);
  forgetCookies();
  try {
    localStorage.clear();
    sessionStorage.clear();
    if (notice) sessionStorage.setItem(SIGNED_OUT_NOTICE_KEY, notice);
  } catch { /* storage refused: nothing was kept in it either */ }
  location.reload();
  await new Promise(() => {}); // the page is going; nothing more runs here
}

// Clearing out what was left before signing in (boot): signing in waits for it,
// so a deletion still on its way never lands after the new account's key.
let leftovers = Promise.resolve();

/** Signing in: whatever was kept before goes, without deleting the databases
 * this page goes on using. */
async function forgetKept() {
  await leftovers;
  clearNotifications();
  // The server's public settings stay (the same for everyone): napsack opens
  // from them next time even while the server is slow to answer.
  await Promise.allSettled([keystore.clear(), cache.keepOnly((k) => k === "config"), forgetCacheStorage()]);
  forgetCookies();
  try {
    localStorage.clear();
    sessionStorage.clear();
  } catch { /* storage refused: nothing is kept in it, then */ }
}

/** Every IndexedDB database of this site (they're all napsack's), deleted. */
async function dropDatabases({ except = [] } = {}) {
  let names = [keystore.DB_NAME, cache.DB_NAME];
  try {
    names = [...new Set([...names, ...(await indexedDB.databases()).map((d) => d.name).filter(Boolean)])];
  } catch { /* a browser that can't list them: napsack's own two, then */ }
  await Promise.allSettled(names.filter((n) => !except.includes(n)).map(dropDatabase));
}

/** Never hangs: a tab that won't let go only delays the deletion, which then
 * finishes by itself. (Each database was emptied first.) */
function dropDatabase(name) {
  return new Promise((resolve) => {
    let req;
    try {
      req = indexedDB.deleteDatabase(name);
    } catch {
      resolve(); // storage refused: nothing was kept
      return;
    }
    req.onsuccess = req.onerror = () => resolve();
    req.onblocked = () => setTimeout(resolve, 1000);
  });
}

/** napsack keeps nothing in Cache Storage (sw.js caches nothing), so this is a
 * backstop: whatever is there goes. */
async function forgetCacheStorage() {
  if (!("caches" in window)) return;
  for (const name of await caches.keys()) await caches.delete(name);
}

/** napsack sets no cookies (the session is a header, never a cookie), so this
 * is a backstop too: any cookie of this site a script can see goes. */
function forgetCookies() {
  try {
    for (const part of document.cookie.split(";")) {
      const name = part.split("=")[0].trim();
      if (name) document.cookie = `${name}=; Max-Age=0; Path=/`;
    }
  } catch { /* cookies refused: none were kept */ }
}

// Another tab signed out, or signed in (as anyone): this one starts over too,
// so it never goes on showing one account while the browser holds another's,
// or none. (The tab that made the change gets no event of its own.)
window.addEventListener("storage", (e) => {
  if (e.storageArea !== localStorage || (e.key !== null && e.key !== TOKEN_KEY) || signingOut) return;
  let token = null;
  try { token = localStorage.getItem(TOKEN_KEY); } catch { /* refused: as if gone */ }
  if (token === state.token) return;
  $("#app").hidden = true;
  location.reload();
});

// Signing out takes two taps, like leaving a group: the first says what it
// does (everything of the account leaves this browser), the second does it.
// Both Sign out buttons (the account bar's and the profile's) work this way;
// a tap anywhere else, or the profile opening again, puts one back.
const SIGN_OUTS = [["#sign-out", "#sign-out-note"], ["#profile-sign-out", "#profile-sign-out-note"]];

function disarmSignOut(button) {
  for (const [b, note] of SIGN_OUTS) {
    if (button && b !== button) continue;
    const btn = $(b);
    if (!btn.dataset.confirm) continue;
    delete btn.dataset.confirm;
    btn.textContent = "Sign out";
    btn.classList.remove("danger");
    $(note).hidden = true;
  }
}

for (const [b, note] of SIGN_OUTS) {
  $(b).addEventListener("click", async () => {
    const btn = $(b);
    if (!btn.dataset.confirm) {
      disarmSignOut(); // only one asks at a time
      btn.dataset.confirm = "1";
      btn.textContent = "Tap again to sign out";
      btn.classList.add("danger");
      $(note).hidden = false;
      return;
    }
    btn.disabled = true;
    try { await api("/auth/logout", { method: "POST" }); } catch {}
    await signOutLocally();
  });
}
document.addEventListener("pointerdown", (e) => {
  for (const [b] of SIGN_OUTS) if (!$(b).contains(e.target)) disarmSignOut(b);
});

// ---------- app shell ----------

function enterApp() {
  $("#auth").hidden = true;
  $("#app").hidden = false;
  renderAccountBar();
  showTab("chats");
  syncPush();
  clearNotifications();
  // Kept, so the next open starts at once (X31).
  const me = state.me;
  tokenTag(state.token).then((tag) => cache.put("me", { tag, me }));
  if (location.hash) openFromLink(location.hash);
  refreshChats();
  refreshGroups();
  refreshRequests();
  connectSocket();
}

// ---------- announcements (announcements.rs) ----------
// A short message from the Admins, at the top of the chat list until it ends
// or is withdrawn. Dismissing one hides it on this device; a new one shows.
const DISMISSED_ANNOUNCEMENT_KEY = "napsack.announcementDismissed";

function showAnnouncement(a) {
  state.announcement = a ?? null;
  let dismissed = null;
  try { dismissed = localStorage.getItem(DISMISSED_ANNOUNCEMENT_KEY); } catch { /* shown, then */ }
  const show = Boolean(a) && String(a.id) !== dismissed && a.ends_at * 1000 > Date.now();
  $("#announcement").hidden = !show;
  if (show) $("#announcement-text").textContent = a.body;
}

async function loadAnnouncement() {
  try {
    showAnnouncement((await getJSON("/announcement")).announcement);
  } catch (err) {
    report("warn", "loading the announcement failed", errorFields(err));
  }
}

$("#announcement-close").addEventListener("click", () => {
  try { localStorage.setItem(DISMISSED_ANNOUNCEMENT_KEY, String(state.announcement?.id)); } catch { /* hidden for now, anyway */ }
  $("#announcement").hidden = true;
});

function renderAccountBar() {
  // System (the admin panel) is for PowerUsers and Admins (roles.md); the server checks again.
  // Here, not once at start: the app may open from a kept "me" with an older role (X31).
  $("#admin-link").hidden = !(["power", "powerxtreme", "admin"].includes(state.me.role) || state.me.is_admin);
  $("#profile-admin-link").hidden = $("#admin-link").hidden;
  // Admins can't delete their account (deletion.rs); a note says why instead.
  const admin = state.me.role === "admin" || Boolean(state.me.is_admin);
  $("#delete-hint").hidden = admin;
  $("#delete-row").hidden = admin;
  $("#delete-admin-note").hidden = !admin;
  $("#my-name").textContent = personName(state.me.id);
  paintAvatar($("#my-avatar"), state.me);
  paintAvatar($("#tab-avatar"), state.me);
  $("#recovery-nudge").hidden = Boolean(state.me.has_recovery_key);
  renderPushNudge();
}

/** My display name or picture may have changed in another tab. */
function refreshMe() {
  return reload(loads.me, loadMe);
}

async function loadMe() {
  try {
    state.me = await getJSON("/me");
  } catch (err) {
    report("warn", "loading me failed", errorFields(err));
    return;
  }
  renderAccountBar();
}

// ---------- loading the lists ----------
// The chat list and groups load at start, on reconnecting (anything could
// have happened meanwhile), and when the server says they changed
// (friends_changed, groups_changed). Messages, reads, and presence don't
// load them again: each changes one row, in place ("the lists, live").

const loads = {
  chats: { running: null, again: null },
  groups: { running: null, again: null },
  requests: { running: null, again: null },
  me: { running: null, again: null },
};

/**
 * Runs `load`, or, while one is on its way (which may have been sent before
 * whatever the caller wants to see), once more right after it, for everyone
 * who asks meanwhile. Never two at once, so an older answer can't land on a
 * newer one, and every caller's promise settles after a load that started
 * after it asked.
 */
function reload(slot, load) {
  if (!slot.running) {
    slot.running = load().finally(() => { slot.running = null; });
    return slot.running;
  }
  const next = () => {
    slot.again = null;
    return reload(slot, load);
  };
  slot.again ??= slot.running.then(next, next);
  return slot.again;
}

function refreshChats() {
  return reload(loads.chats, loadChats);
}

let refreshTimer = null;
function refreshChatsSoon() {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refreshChats, 150);
}

// While a list is on its way, what the socket says about it is applied at
// once, and again on top of the answer, which the server may have put
// together before it. Each change is safe to apply twice: last messages only
// move forward by id, and the counts move with them.
const sinceSent = { chats: [], groups: [] };

function listEvent(which, apply) {
  apply();
  if (loads[which].running) sinceSent[which].push(apply);
}

async function loadChats() {
  if (!state.loaded.chats && !state.chats.length) await showKeptChats();
  const me = state.me?.id; // (refreshMe replaces the object, so it's the id that says who)
  sinceSent.chats = []; // whatever came before this was sent, the answer has
  let text, chats;
  try {
    text = await api(`/friends?tz=${tzOffset()}`, { as: "text" });
    chats = JSON.parse(text);
    await checkPins(chats);
    // Read before it's shown, so a row never says "Encrypted message" on the
    // way. (Every friend's key is pinned by now, which is all decrypting needs.)
    await Promise.all(chats.map((c) => c.last_message && decrypt(c.last_message)));
  } catch (err) {
    report("warn", "loading chats failed", errorFields(err));
    state.loaded.error = err.message;
    renderChatList();
    return;
  }
  // Signed out while it loaded (an ended session, an account turned off).
  if (!state.me || state.me.id !== me) return;
  state.chats = chats;
  kept.chats = JSON.parse(text); // as sent: still encrypted
  newInChats.clear(); // counted from this answer's last messages on
  const meanwhile = sinceSent.chats;
  sinceSent.chats = [];
  for (const apply of meanwhile) apply();
  if (meanwhile.length) keepListSoon("chats");
  else keepAnswer("friends", text, kept.chats);
  state.loaded.chats = true;
  state.loaded.error = null;
  renderChatList();
  renderChatHeader();
  if (state.activeId && !chatById(state.activeId)) closeChat(); // unfriended
  else if (state.activeId) renderMessages(); // sender names follow renames
}

// ---------- the lists, live ----------
// What the socket says changes one row, in place: its last message, whether
// it's hidden, and its unread count, which follow from the messages
// themselves. Pics also change streaks: for those the list asks the server.
// An event in a group (a join, a rename, a picture) changes the group, and
// the server says so itself (groups_changed), so it isn't asked twice.

// Messages counted into a row since its list loaded, so each counts once, in
// whatever order the socket brings them (events are handled side by side,
// and decrypting can finish out of order).
const newInChats = new Map();  // friend id -> { base: the last message id loaded, ids }
const newInGroups = new Map(); // group id -> the same

/** Whether `m` is new to `row` since its list loaded, and not counted yet; it's counted now. */
function isNewTo(seen, id, row, m) {
  if (!seen.has(id)) seen.set(id, { base: row.last_message?.id ?? 0, ids: new Set() });
  const s = seen.get(id);
  if (m.id <= s.base || s.ids.has(m.id)) return false;
  s.ids.add(m.id);
  return true;
}

/** A message, new or changed, in a direct chat. `raw` is it as sent, still encrypted, for the kept copy. */
function chatGotMessage(m, raw) {
  const fid = friendOf(m);
  const chat = chatById(fid);
  // Someone not in my list yet: the server knows who. A list on its way
  // (friends_changed comes first) has them, and this is applied again on it.
  if (!chat) return loads.chats.running ? undefined : refreshChatsSoon();
  if (m.kind === "snap") refreshChatsSoon(); // streaks, and pics still waiting, are the server's to count
  const fresh = isNewTo(newInChats, fid, chat, m);
  if (fresh) {
    // Theirs is unread, and anything new brings a hidden chat back (marks.rs).
    chat.hidden = false;
    if (m.sender_id === fid) chat.unread += 1;
  }
  const latest = m.id >= (chat.last_message?.id ?? 0);
  if (latest) chat.last_message = m;
  if (!fresh && !latest) return; // an older message changed (a reaction, an edit): the row doesn't show it
  const row = keptChat(fid);
  if (row) {
    if (latest) row.last_message = raw;
    row.hidden = chat.hidden;
    row.unread = chat.unread;
  }
  keepListSoon("chats");
  renderChatList();
}

/** They read my texts, up to `at`. */
function friendRead(friendId, at) {
  for (const row of [chatById(friendId), keptChat(friendId)]) {
    const lm = row?.last_message;
    if (lm && lm.sender_id === state.me.id && lm.kind === "text" && !lm.read_at && lm.created_at <= at) lm.read_at = at;
  }
  keepListSoon("chats");
}

/**
 * This device read their texts, and the server says it marked some. It surely
 * marked the ones here when the read went out (`sentIds`). Pics waiting to be
 * opened stay unread: when every unread message is one loaded here, what's
 * left is exactly those; otherwise (or if newer texts came meanwhile, which
 * it may not have marked) the server counts.
 */
function readByMe(friendId, sentIds) {
  const at = Math.floor(Date.now() / 1000);
  let marked = 0, late = 0, waiting = 0;
  for (const m of state.messages.get(friendId) || []) {
    if (m.sender_id !== friendId) continue;
    if (m.kind === "text" && !m.read_at && sentIds.has(m.id)) {
      m.read_at = at;
      if (!beforeMyReset(m)) marked++;
    } else if (beforeMyReset(m)) {
      continue; // sealed to the key I had before a reset: never counted (D14)
    } else if (m.kind === "text" && !m.read_at) {
      late++;
    } else if (m.kind === "snap" && m.snap_state === "pending") {
      waiting++;
    }
  }
  const chat = chatById(friendId);
  const exact = Boolean(chat) && !late && marked + waiting === chat.unread;
  if (!exact) refreshChatsSoon();
  // A count, not a change: it holds for a list that knows of nothing newer than this read did.
  const upTo = chat?.last_message?.id ?? 0;
  listEvent("chats", () => {
    for (const row of [chatById(friendId), keptChat(friendId)]) {
      if (!row) continue;
      const lm = row.last_message;
      if (lm && sentIds.has(lm.id) && !lm.read_at) lm.read_at = at;
      if (!exact) continue;
      if ((lm?.id ?? 0) === upTo) row.unread = waiting;
      else refreshChatsSoon();
    }
    keepListSoon("chats");
    renderChatList();
  });
}

/** A message, new or changed, in a group. `raw` is it as sent, still sealed, for the kept copy. */
function groupGotMessage(m, raw) {
  const g = groupById(m.group_id);
  // A group I was just added to: as for a friend not in the list yet (groups_changed comes first).
  if (!g) return loads.groups.running ? undefined : refreshGroupsSoon();
  // New texts and pics from the others are unread (groups.rs counts the same).
  const fresh = isNewTo(newInGroups, g.id, g, m);
  if (fresh && m.sender_id !== state.me.id && m.kind === "text") g.unread += 1;
  const latest = m.id >= (g.last_message?.id ?? 0);
  if (latest) g.last_message = m;
  if (!fresh && !latest) return; // an older message changed: a reaction, who opened a pic
  const row = keptGroup(m.group_id);
  if (row) {
    if (latest) row.last_message = raw;
    row.unread = g.unread;
  }
  keepListSoon("groups");
  renderChatList();
}

/** This device read the group, up to the message that was newest when the read went out (`upTo`). */
function groupReadByMe(groupId, upTo) {
  listEvent("groups", () => {
    for (const g of [groupById(groupId), keptGroup(groupId)]) {
      if (!g) continue;
      // Anything newer may have come after the server's read: it counts those.
      if ((g.last_message?.id ?? 0) === upTo) g.unread = 0;
      else refreshGroupsSoon();
    }
    keepListSoon("groups");
    renderChatList();
  });
}

// ---------- my own reads, echoed ----------
// A read this device sends comes back over the socket (`read` by me, or
// `groups_changed` for a group) to every device of mine, without saying which
// one sent it. This one has already applied it when the server answered, so
// each answer accounts for one echo, in whichever order the two arrive. An
// echo no answer accounts for is another device's, and the list asks the server.
const echoes = new Map(); // "d" (direct chats) or "g:<id>" -> { sending, answered, early }
let socketTurn = 0;       // bumped on every new connection: an old one's echoes don't come

/**
 * Sends one of my reads. `send` resolves to whether the server will echo it;
 * `answered()` applies it; `foreign()` deals with an echo that wasn't ours.
 */
async function sendRead(key, send, answered, foreign) {
  if (!echoes.has(key)) echoes.set(key, { sending: 0, answered: 0, early: 0 });
  const slot = echoes.get(key);
  const turn = socketTurn;
  slot.sending++;
  let echoed = false;
  try {
    echoed = await send();
  } finally {
    slot.sending--;
  }
  if (echoed && turn === socketTurn) {
    if (slot.early) slot.early--;
    else slot.answered++;
  }
  if (echoed) answered();
  // Echoes that came while reads were on their way, and that no answer
  // accounted for, were another device's.
  if (!slot.sending && slot.early) {
    slot.early = 0;
    foreign();
  }
}

/** The socket echoed a read of mine: true if it's this device's own (already applied, or about to be). */
function ownEcho(key) {
  const slot = echoes.get(key);
  if (slot?.answered) {
    slot.answered--;
    return true;
  }
  if (slot?.sending) {
    slot.early++;
    return true;
  }
  return false;
}

// ---------- what was kept on this device (cache.js, X31) ----------
// The chat list, groups, and each chat's newest page show from the device at
// once, decrypted as they're shown, while the server's answer is on its way.
// What's kept is written only when it changed. The two lists also follow
// what the socket says, through copies of its messages taken before they're
// decrypted, so the device's copy stays current without asking the server.
const kept = { chats: null, groups: null, tags: new Map(), dirty: new Set(), timer: null, wroteAt: 0 };
const KEPT_LISTS = { chats: "friends", groups: "groups" };
const keptChat = (id) => kept.chats?.find((c) => c.id === id);
const keptGroup = (id) => kept.groups?.find((g) => g.id === id);

/** A short fingerprint of an answer, to tell whether it's what was kept last. */
function fingerprint(text) {
  let h = 0x811c9dc5; // FNV-1a
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 0x01000193);
  return `${text.length}:${h >>> 0}`;
}

/** Keeps a server answer (`value`: it parsed, not yet decrypted) under `key`, unless that's what's kept already. */
function keepAnswer(key, text, value = JSON.parse(text)) {
  const tag = fingerprint(text);
  if (signingOut || !state.me || kept.tags.get(key) === tag) return;
  kept.tags.set(key, tag);
  cache.put(`${state.me.id}:${key}`, value);
}

// A change is written as soon as this event is handled, and a burst of them
// at most every KEEP_EVERY_MS, together. Never put off for longer: a write
// left for the page closing may not land (the page goes before the database
// has it), and the next start would show the list from before.
const KEEP_EVERY_MS = 250;

/** The kept chat list or groups changed here: written at once, or with the burst it's part of. */
function keepListSoon(which) {
  kept.dirty.add(which);
  kept.timer ??= setTimeout(writeKeptLists, Math.max(0, kept.wroteAt + KEEP_EVERY_MS - Date.now()));
}

function writeKeptLists() {
  clearTimeout(kept.timer);
  kept.timer = null;
  kept.wroteAt = Date.now();
  if (!state.me || signingOut) return;
  for (const which of kept.dirty) {
    if (!kept[which]) continue;
    kept.tags.delete(KEPT_LISTS[which]); // no longer exactly what the server last sent
    cache.put(`${state.me.id}:${KEPT_LISTS[which]}`, kept[which]);
  }
  kept.dirty.clear();
}
// Not left unwritten when napsack goes to the background or the page closes.
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") writeKeptLists(); });
window.addEventListener("pagehide", writeKeptLists);

async function showKeptChats() {
  const me = state.me;
  const chats = await cache.get(`${me.id}:friends`);
  if (!chats?.length || state.loaded.chats || state.me !== me) return;
  await checkPins(chats);
  for (const c of chats) c.active_now = null; // who's around now isn't something to keep
  // In place first: decrypting looks up each friend's key in the chat list.
  state.chats = chats;
  newInChats.clear();
  await Promise.all(chats.map((c) => c.last_message && decrypt(c.last_message)));
  if (state.loaded.chats || state.me !== me) return; // the server answered first
  state.loaded.chats = true;
  renderChatList();
}

async function showKeptGroups() {
  const me = state.me;
  const groups = await cache.get(`${me.id}:groups`);
  if (!groups?.length || state.loaded.groups || state.me !== me) return;
  await Promise.all(groups.map((g) => g.last_message && openGroupMessage(g.last_message)));
  if (state.loaded.groups || state.me !== me) return;
  state.groups = groups;
  newInGroups.clear();
  state.loaded.groups = true;
  renderChatList();
}

/** A chat's newest page as kept, while it loads (nothing if it's already showing). */
async function showKeptPage(key, decryptOne, isOpen, set) {
  const page = await cache.get(`${state.me.id}:${key}`);
  if (!page?.length) return;
  await Promise.all(page.map(decryptOne));
  if (!isOpen()) return;
  set(page);
  renderMessages();
}

// Pull to refresh: dragging the chat list down past its top refetches chats,
// groups, and requests, and reconnects the socket if it's down. Live updates
// usually make it a no-op, but it's what people expect a list to do.
const PULL_TRIGGER = 64; // px the indicator must reach (half the finger's travel)
const pull = { from: null, height: 0, busy: false, last: 0 };

function setPull(h) {
  pull.height = h;
  $("#pull").style.height = `${h}px`;
  $("#pull").style.setProperty("--pull-turn", `${h * 4}deg`);
}

async function pullRefresh() {
  pull.busy = true;
  const started = Date.now();
  // At most every few seconds, however often someone pulls.
  if (started - pull.last > 3000) {
    pull.last = started;
    if (!state.ws || state.ws.readyState === WebSocket.CLOSED) {
      state.wsRetry = 0;
      connectSocket();
    }
    await Promise.all([refreshChats(), refreshGroups(), refreshRequests()]);
    report("debug", "chat list pulled to refresh");
  }
  // Long enough to see that something happened.
  await new Promise((r) => setTimeout(r, Math.max(0, 500 - (Date.now() - started))));
  pull.busy = false;
}

// One finger on the list is either a sideways swipe on a row (its actions) or
// a vertical drag (scrolling, or pulling to refresh at the top). The first
// few pixels of movement decide which, and it stays that way until lift.
const drag = { x: 0, y: 0, mode: null, row: null, from: 0, width: 0, shift: 0 };

$("#chat-list").addEventListener("touchstart", (e) => {
  const t = e.touches[0];
  drag.x = t.clientX;
  drag.y = t.clientY;
  drag.mode = null;
  drag.row = e.target.closest(".chat-row");
  const actions = drag.row?.querySelector(".row-actions");
  drag.width = actions ? actions.offsetWidth : 0;
  drag.from = drag.row && drag.row === rowSwipe.open ? -drag.width : 0;
  pull.from = !pull.busy && $("#chat-list").scrollTop <= 0 ? t.clientY : null;
}, { passive: true });

$("#chat-list").addEventListener("touchmove", (e) => {
  const t = e.touches[0];
  const dx = t.clientX - drag.x;
  const dy = t.clientY - drag.y;
  if (!drag.mode) {
    if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
    drag.mode = Math.abs(dx) > Math.abs(dy) && drag.width ? "swipe" : "vertical";
    if (drag.mode === "swipe" && rowSwipe.open && rowSwipe.open !== drag.row) closeSwipedRow();
  }
  if (drag.mode === "swipe") {
    e.preventDefault(); // napsack moves the row, not the page
    drag.shift = Math.max(-drag.width, Math.min(0, drag.from + dx));
    shiftRow(drag.row, drag.shift, false);
    return;
  }
  if (pull.from == null) return;
  const pulled = t.clientY - pull.from;
  if (pulled <= 0 || $("#chat-list").scrollTop > 0) {
    if (pull.height) setPull(0);
    return;
  }
  e.preventDefault(); // napsack draws this pull, not the browser
  $("#pull").classList.remove("settling");
  setPull(Math.min(pulled * 0.5, PULL_TRIGGER * 1.4));
}, { passive: false });

async function endDrag(e) {
  if (drag.mode === "swipe") {
    // Past halfway it opens; otherwise it slides back.
    const open = e.type !== "touchcancel" && drag.shift < -drag.width / 2;
    shiftRow(drag.row, open ? -drag.width : 0);
    rowSwipe.open = open ? drag.row : null;
    drag.mode = null;
    return;
  }
  drag.mode = null;
  if (pull.from == null) return;
  pull.from = null;
  const el = $("#pull");
  el.classList.add("settling");
  if (e.type === "touchcancel" || pull.height < PULL_TRIGGER) return setPull(0);
  setPull(44);
  el.classList.add("refreshing");
  await pullRefresh();
  el.classList.remove("refreshing");
  setPull(0);
}
$("#chat-list").addEventListener("touchend", endDrag);
$("#chat-list").addEventListener("touchcancel", endDrag);

function chatStatus(chat) {
  if (chat.keyChanged) return { text: "Safety code changed" };
  if (chat.deactivated) return { text: "Account turned off" };
  const m = chat.last_message;
  if (!m) return { text: "Say hi" };
  const mine = m.sender_id === state.me.id;
  if (m.kind === "snap") {
    const w = mediaWord(m), W = capitalize(w);
    if (!mine && m.snap_state === "pending") return { text: `New ${w}`, marker: "snap" };
    const label = mine
      ? { pending: `Sent a ${w}`, opened: `${W} opened`, expired: `${W} expired unopened` }
      : { opened: `${W} viewed`, expired: `${W} expired` };
    // A text from before it can still be unread (the server's count): its
    // pics viewed from the list (X41), say, or a pic sent from the camera.
    return { text: label[m.snap_state] || W, marker: chatUnreadShown(chat) > 0 ? "text" : null };
  }
  const body = m.text ?? "Encrypted message";
  if (!mine && !m.read_at && !readingNow("d", chat.id)) return { text: body, marker: "text" };
  return { text: mine ? `You: ${body}` : body };
}

const PREVIEW_CHARS = 140;

/** Previews also end in "…" through CSS; this caps what goes in the DOM at all. */
function preview(text) {
  const chars = Array.from(text ?? "");
  return chars.length > PREVIEW_CHARS ? `${chars.slice(0, PREVIEW_CHARS - 1).join("")}…` : chars.join("");
}

/** One chat in the list. `actions` (favorite, hide, leave) sit behind the
 * row: a phone swipes it aside to reach them, a computer shows them on hover. */
// Double-tapping a chat in the list opens it straight into the camera, to
// answer with a pic. On a computer the first click opens the chat at once (the
// list stays in view); a second click on the same spot within DOUBLE_TAP_MS
// opens the camera instead of doing anything else there. A click elsewhere is
// just a click. Phones wait a moment first (`tapOnPhone`). A row whose newest
// message is a pic waiting from them shows the pics instead (`tapPics`).
const DOUBLE_TAP_MS = 350;
const DOUBLE_TAP_PX = 40;
const cameraTap = { up: null, click: null, timer: null };

/**
 * Watches for the second tap of a double tap after the chat has opened
 * (`windowMs` more): on the same spot, it opens the camera and does nothing
 * else. Caught when the finger lifts, which phones always report, and the
 * click that follows is swallowed. Anything else passes through untouched.
 */
function armCameraTap(opening, first, windowMs = DOUBLE_TAP_MS) {
  disarmCameraTap();
  const near = (e) => Math.hypot(e.clientX - first.clientX, e.clientY - first.clientY) <= DOUBLE_TAP_PX;
  const swallow = (e) => { e.preventDefault(); e.stopPropagation(); };
  let caught = false;
  cameraTap.up = (e) => {
    if (caught || !near(e)) return;
    caught = true;
    swallow(e);
    cameraAfter(opening);
  };
  cameraTap.click = (e) => {
    if (!e.isTrusted) return; // our own press of the camera button
    if (!caught && near(e)) {
      caught = true;
      cameraAfter(opening);
    }
    if (caught) swallow(e);
    disarmCameraTap();
  };
  document.addEventListener("pointerup", cameraTap.up, true);
  document.addEventListener("click", cameraTap.click, true);
  // A little past the window, for the click that follows a caught pointerup.
  cameraTap.timer = setTimeout(disarmCameraTap, windowMs + 150);
}

/** Opens the camera once the chat has opened, if this chat can take a pic. */
async function cameraAfter(opening) {
  await opening;
  const button = $("#camera-button");
  if (!button.hidden && !button.disabled) button.click();
}

// On a phone the chat covers the list, so a tap there waits a moment before
// opening it: just long enough for the second tap of a quick double tap to land
// on the row (straight to the camera). A slower second tap lands on the opened
// chat, where `armCameraTap` still catches it. The row lights up at once.
const wideLayout = matchMedia("(min-width: 760px)");
const PHONE_OPEN_DELAY_MS = 150;
const pendingTap = { key: null, button: null, timer: null };

function tapOnPhone(button, key, onclick, first) {
  const second = pendingTap.key === key;
  clearPendingTap();
  if (second) return cameraAfter(onclick());
  button.classList.add("tapped");
  pendingTap.key = key;
  pendingTap.button = button;
  const at = { clientX: first.clientX, clientY: first.clientY };
  pendingTap.timer = setTimeout(() => {
    clearPendingTap();
    armCameraTap(onclick(), at, DOUBLE_TAP_MS - PHONE_OPEN_DELAY_MS);
  }, PHONE_OPEN_DELAY_MS);
}

function clearPendingTap() {
  clearTimeout(pendingTap.timer);
  pendingTap.button?.classList.remove("tapped");
  pendingTap.key = pendingTap.button = null;
}

/**
 * A tap on a row whose newest message is a pic or video waiting from them
 * (X41): the chat's waiting pics, shown over the list, which is where you are
 * after. Seeing one opens it for good, so on a computer as on a phone this
 * waits out a double tap first (the chat with the camera up, as any row's),
 * and nothing is fetched but the chat's newest messages meanwhile. The
 * keyboard has no second tap to wait for.
 */
function tapPics(button, key, p, e) {
  disarmCameraTap();
  if (e.detail === 0) return p.showPics();
  const second = pendingTap.key === key;
  clearPendingTap();
  if (second) return cameraAfter(p.onclick());
  button.classList.add("tapped");
  pendingTap.key = key;
  pendingTap.button = button;
  const page = p.loadPics();
  page.catch(() => {}); // a double tap after all: nobody waits for it
  pendingTap.timer = setTimeout(() => {
    clearPendingTap();
    p.showPics(page);
  }, DOUBLE_TAP_MS);
}

function disarmCameraTap() {
  clearTimeout(cameraTap.timer);
  if (cameraTap.up) document.removeEventListener("pointerup", cameraTap.up, true);
  if (cameraTap.click) document.removeEventListener("click", cameraTap.click, true);
  cameraTap.up = cameraTap.click = null;
}

/** A row's frame: who it is, the picture, the actions. What changes as messages
 * come and go (the latest, the time, unread, the open one) is paintRow's. */
function chatRow(p) {
  const { onclick, group, avatar, actions = [], muted = false } = p;
  // Muted: no unread dot or bold (paintRow), and a 🔕 by the name.
  const name = muted ? `${p.name} 🔕` : p.name;
  const key = `${group ? "g" : "d"}:${name}`;
  // While a row is swiped open, a tap anywhere on the list just closes it.
  const open = (e) => {
    if (rowSwipe.open) return closeSwipedRow();
    // Decided by what the row holds now, not when it was drawn.
    if (p.opensPics?.()) return tapPics(e.currentTarget, key, p, e);
    if (e.detail > 0 && !wideLayout.matches) return tapOnPhone(e.currentTarget, key, onclick, e);
    if (e.detail > 0 && pendingTap.key === key) { // the second tap, the pic gone meanwhile: still a double tap
      clearPendingTap();
      return cameraAfter(onclick());
    }
    clearPendingTap();
    const opening = onclick();
    if (e.detail > 0) armCameraTap(opening, e); // a tap or click, not the keyboard
  };
  const li = el("li", { class: "chat-row" },
    el("button", { type: "button", class: "chat-item", onclick: open },
      el("span", { class: "marker", "aria-hidden": "true" }),
      avatar(),
      el("span", { class: "chat-text" },
        group ? el("span", { class: "visually-hidden", text: "Group: " }) : null,
        el("span", { class: "chat-name", text: name }),
        el("span", { class: "chat-status" }),
        el("span", { class: "chat-hint" })),
      el("span", { class: "chat-time" }),
    ),
    actions.length ? el("div", { class: "row-actions" }, ...actions.map((a) =>
      el("button", { type: "button", class: `row-action ${a.cls ?? ""}`, "aria-label": a.aria, title: a.aria, onclick: a.run },
        rowIcon(a.icon), el("span", { class: "row-action-label", text: a.label })))) : null);
  // A computer's pointer leaving the row, or focus leaving it, disarms a
  // two-tap action. A touch lifting off is no leaving: the swipe closing is.
  li.addEventListener("pointerleave", (e) => { if (e.pointerType === "mouse") disarmRow(li); });
  li.addEventListener("focusout", (e) => { if (!li.contains(e.relatedTarget)) disarmRow(li); });
  paintRow(li, p);
  return li;
}

/** Brings a row up to date in place: its latest message, time, unread marker, and whether it's the open chat. */
function paintRow(li, { status, time, current, group, muted = false, picsHint = "" }) {
  const marker = muted ? null : status.marker;
  const button = li.firstElementChild;
  button.classList.toggle("is-muted", Boolean(muted));
  button.classList.toggle("has-unread", marker === "snap" || marker === "text");
  button.classList.toggle("has-snap", marker === "snap");
  button.classList.toggle("is-group", Boolean(group));
  if (current) button.setAttribute("aria-current", "true");
  else button.removeAttribute("aria-current");
  const set = (node, prop, value) => { if (node[prop] !== value) node[prop] = value; };
  set(button.querySelector(".marker"), "className", `marker ${marker || ""}`);
  set(button.querySelector(".chat-status"), "textContent", preview(status.text));
  set(button.querySelector(".chat-time"), "textContent", time ? relTime(time) : "");
  // For screen readers: what a tap does when it isn't opening the chat (X41).
  set(button.querySelector(".chat-hint"), "textContent", picsHint);
}

// Row action icons. A computer shows just these (small, over the time); a
// phone shows the words behind the swiped row.
const ROW_ICONS = {
  star: "M12 3.5l2.6 5.3 5.9.9-4.25 4.1 1 5.85L12 16.9l-5.25 2.75 1-5.85L3.5 9.7l5.9-.9z",
  archive: "M4 6.5h16v3.5H4zM5.5 10v8.5h13V10M10 13.5h4",
  leave: "M14 4.5h4.5v15H14M10 8l-4 4 4 4M6 12h9",
  bell: "M6.5 16.5V11a5.5 5.5 0 0 1 9-4.25M17.5 10.5v6l1.5 1.5H8.5M10 20.5a2 2 0 0 0 4 0M4 4l16 16",
  block: "M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 1 0 0-17zM6 6l12 12",
};
function rowIcon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", ROW_ICONS[name]);
  svg.append(path);
  return svg;
}

// ---------- drawing the chat list ----------
// Asked for often (every message, presence change, typing hint, and search
// keystroke): drawn at most once a frame, and only rows whose content changed
// are built again. The rest stay as they are, a swiped-open or hovered row
// included. The tab's title (the unread count) follows at once, even while
// napsack is in the background and nothing is drawn.
let chatListFrame = 0;
let listNodes = new Map(); // key -> { sig, node }: what the list shows now

function renderChatList() {
  if (!state.me) return;
  renderTitle();
  watchMuteEnds();
  chatListFrame ||= requestAnimationFrame(drawChatList);
}

function renderTitle() {
  const unread = state.chats.reduce((n, c) => n + (c.hidden || isMuted(c) ? 0 : chatUnreadShown(c)), 0)
    + state.groups.reduce((n, g) => n + (isMuted(g) || readingNow("g", g.id) ? 0 : g.unread), 0);
  document.title = unread ? `(${unread}) ${APP_NAME}` : APP_NAME;
}

/**
 * Whether I'm reading this chat (`kind` "d") or group ("g") now: it's open
 * and napsack is on screen. What arrives in it is read as it comes (markRead,
 * markGroupRead), so it doesn't show as unread while that read is on its way.
 */
function readingNow(kind, id) {
  if (document.visibilityState !== "visible") return false;
  return kind === "g" ? state.activeGroupId === id : state.activeId === id;
}

/** A chat's unread count as shown: in the one I'm reading, its texts here are being read already; pics wait to be opened. */
function chatUnreadShown(c) {
  if (!c.unread || !readingNow("d", c.id)) return c.unread;
  const reading = (state.messages.get(c.id) || [])
    .filter((m) => m.sender_id === c.id && m.kind === "text" && !m.read_at && !beforeMyReset(m)).length;
  return Math.max(0, c.unread - reading);
}

/** Whether a chat or group is muted now: a mute for some hours ends by itself
 * (marks.rs), whether or not the list has been fetched since. */
function isMuted(x) {
  return Boolean(x.muted) && (x.muted_until == null || x.muted_until > Date.now() / 1000);
}

// When the next mute for some hours ends, the list is drawn again, so its 🔕
// goes and the tab counts it. At most a day ahead, then looked at again
// (timers can't wait longer than about 24 days).
let muteEndTimer = 0;
function watchMuteEnds() {
  clearTimeout(muteEndTimer);
  const now = Date.now() / 1000;
  const ends = [...state.chats, ...state.groups].filter((x) => x.muted && x.muted_until > now).map((x) => x.muted_until);
  if (ends.length) muteEndTimer = setTimeout(renderChatList, (Math.min(Math.min(...ends) - now, 86400) + 1) * 1000);
}

/** Makes `parent` hold exactly `nodes`, in order, moving as few as it can. */
function placeChildren(parent, nodes) {
  const wanted = new Set(nodes);
  for (const child of [...parent.childNodes]) if (!wanted.has(child)) child.remove();
  let at = parent.firstChild;
  for (const node of nodes) {
    if (node === at) at = at.nextSibling;
    else parent.insertBefore(node, at);
  }
}

/** What a row's frame shows (chatRow), to tell when it has to be built again. */
function rowSig(p) {
  return JSON.stringify([p.name, Boolean(p.group), Boolean(p.muted), p.avatarSig,
    p.actions.map((a) => [a.label, a.aria, a.cls ?? ""])]);
}

function chatRowProps(chat) {
  const name = chatName(chat);
  const id = chat.id;
  return {
    name: chatRowName(chat),
    status: isTyping(`d:${id}`) ? { text: "typing…" } : chatStatus(chat),
    time: chat.last_message?.created_at,
    current: id === state.activeId,
    onclick: () => openChat(id),
    opensPics: () => chatOpensPics(chatById(id)),
    loadPics: () => getJSON(`/chats/${id}/messages?limit=${pageSize()}`),
    showPics: (page) => picsFromList("d", id, page),
    picsHint: chatOpensPics(chat) ? picsHint(chat.last_message) : "",
    avatar: () => el("span", { class: `avatar-wrap ${chat.active_now ? "online" : ""}` },
      paintAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), chat)),
    avatarSig: [Boolean(chat.active_now), name, chat.avatar_id ?? null],
    muted: isMuted(chat),
    actions: chat.hidden
      ? [{ label: "Unhide", icon: "archive", aria: `Show your chat with ${name} again`, run: () => unhideChat(id) }]
      : [favoriteAction(chat, name, () => { const c = chatById(id); if (c) setFavorite("chats", id, !c.favorite); }),
        muteAction("chats", chat, name),
        { label: "Hide", icon: "archive", aria: `Hide your chat with ${name}`, run: () => hideChat(id) },
        // Team Napsack only sends, and can't be blocked (blocks.rs).
        ...(chat.system ? [] : [{ label: "Block", icon: "block", cls: "danger", aria: `Block ${name}`,
          run: () => { closeSwipedRow(); openBlock({ id, username: chat.username }); } }])],
  };
}

function groupRowProps(g) {
  const id = g.id;
  return {
    name: g.name, status: groupStatus(g), time: g.last_message?.created_at, group: true,
    current: id === state.activeGroupId,
    onclick: () => openGroup(id),
    opensPics: () => groupOpensPics(groupById(id)),
    loadPics: () => getJSON(`/groups/${id}/messages?limit=${pageSize()}`),
    showPics: (page) => picsFromList("g", id, page),
    picsHint: groupOpensPics(g) ? picsHint(g.last_message) : "",
    avatar: () => el("span", { class: "avatar-wrap" },
      paintGroupAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), g)),
    avatarSig: [g.name, g.avatar_id ?? null],
    muted: isMuted(g),
    actions: [favoriteAction(g, g.name, () => { const x = groupById(id); if (x) setFavorite("groups", id, !x.favorite); }),
      muteAction("groups", g, g.name),
      { label: "Leave", icon: "leave", cls: "danger", aria: `Leave ${g.name}`, run: (e) => leaveFromList(e.currentTarget, g) }],
  };
}

/** Favorites first, then everything else, each newest first. Hidden direct
 * chats sit out of the list behind a "Hidden chats" link. */
function drawChatList() {
  chatListFrame = 0;
  if (!state.me) return;
  const list = $("#chat-list");
  const next = new Map();
  /** What `key` shows: its node as it is if it still shows the same (`sig`), else a new one. */
  const keep = (key, sig, make) => {
    const had = listNodes.get(key);
    const node = had?.sig === sig ? had.node : make();
    next.set(key, { sig, node });
    return node;
  };
  const row = (e) => {
    const node = keep(e.key, rowSig(e.props), () => chatRow(e.props));
    paintRow(node, e.props);
    return node;
  };
  const heading = (key, text) => keep(`h:${key}`, text, () => el("li", { class: "list-heading", text }));
  const entries = [
    ...state.chats.map((chat) => ({
      key: `d:${chat.id}`,
      at: chat.last_message?.created_at ?? 0,
      name: chatName(chat),
      favorite: chat.favorite,
      hidden: chat.hidden,
      props: chatRowProps(chat),
      search: `${chatName(chat)} ${chat.username}`.toLowerCase(),
    })),
    ...state.groups.map((g) => ({
      key: `g:${g.id}`,
      at: g.last_message?.created_at ?? 0,
      name: g.name,
      favorite: g.favorite,
      hidden: false,
      props: groupRowProps(g),
      search: g.name.toLowerCase(),
    })),
  ].sort((a, b) => b.at - a.at || a.name.localeCompare(b.name));

  // Until both lists have answered, an empty list means "not here yet", not "no friends".
  const loaded = state.loaded.chats && state.loaded.groups;
  $("#chat-empty").hidden = entries.length > 0 || !loaded;
  const items = [];
  if (!loaded && !entries.length) {
    const failed = state.loaded.error;
    if (failed) {
      items.push(keep("problem", failed, () => el("li", { class: "list-problem" },
        el("p", { text: `Couldn't load your chats. ${failed}` }),
        el("button", { type: "button", class: "button", onclick: () => { state.loaded.error = null; renderChatList(); refreshChats(); refreshGroups(); } }, "Try again"))));
    } else {
      for (let i = 0; i < 5; i++) {
        items.push(keep(`skeleton:${i}`, "", () => el("li", { class: "skeleton-row", "aria-hidden": "true" },
          el("span", { class: "skeleton-dot" }), el("span", { class: "skeleton-lines" }, el("span"), el("span")))));
      }
    }
  } else {
    const q = state.search.q.trim().toLowerCase();
    if (q) {
      // Searching: chats whose name matches (hidden ones too), then messages that do.
      const named = entries.filter((e) => e.search.includes(q));
      items.push(heading("chats", "Chats"), ...(named.length ? named.map(row)
        : [keep("note:no-chats", "", () => el("li", { class: "search-note", text: "No chats by that name." }))]));
      if (q.length >= 2) items.push(heading("messages", "Messages"), ...searchResults(q, keep));
    } else {
      const shown = entries.filter((e) => !e.hidden);
      const favorites = shown.filter((e) => e.favorite);
      const hidden = entries.filter((e) => e.hidden);
      if (favorites.length) items.push(heading("favorites", "Favorites"), ...favorites.map(row), heading("chats", "Chats"));
      items.push(...shown.filter((e) => !e.favorite).map(row));
      if (hidden.length) {
        items.push(keep("hidden-toggle", JSON.stringify([state.showHidden, hidden.length]), () => el("li", { class: "hidden-toggle" }, el("button", {
          type: "button", class: "link", "aria-expanded": state.showHidden ? "true" : "false",
          onclick: () => { state.showHidden = !state.showHidden; renderChatList(); },
        }, state.showHidden ? "Hide hidden chats" : `Hidden chats (${hidden.length})`))));
        if (state.showHidden) items.push(...hidden.map(row));
      }
    }
  }
  placeChildren(list, items);
  listNodes = next;
  if (rowSwipe.open && !rowSwipe.open.isConnected) rowSwipe.open = null; // its row was drawn again
  list.setAttribute("aria-busy", !loaded && !entries.length && !state.loaded.error ? "true" : "false");
}

function favoriteAction(chat, name, run) {
  return chat.favorite
    ? { label: "Unfavorite", icon: "star", cls: "fav on", aria: `Remove ${name} from favorites`, run }
    : { label: "Favorite", icon: "star", cls: "fav", aria: `Add ${name} to favorites`, run };
}

// ---------- favorites and hidden chats ----------
// Both are private to me and kept on the server (marks.rs), so they follow me
// to my other devices, which hear about changes through friends_changed /
// groups_changed.

async function setFavorite(kind, id, on) {
  const item = kind === "groups" ? groupById(id) : chatById(id);
  if (!item) return;
  item.favorite = on; // show it at once; the server has the final say
  renderChatList();
  try {
    await api(`/${kind}/${id}/favorite`, { method: "PUT", json: { on } });
  } catch (err) {
    item.favorite = !on;
    renderChatList();
    alert(err.message);
  }
}

/** Off the list until a new message or until I open it again. The messages
 * stay on the server; what this browser had loaded for it is dropped. */
async function hideChat(friendId) {
  const chat = chatById(friendId);
  if (!chat) return;
  chat.hidden = true;
  forgetChat(friendId);
  if (state.activeId === friendId) closeChat();
  renderChatList();
  showToast(`Hid your chat with ${chatName(chat)}.`, () => unhideChat(friendId));
  try {
    await api(`/chats/${friendId}/hidden`, { method: "PUT", json: { on: true } });
    report("info", "chat hidden", { friend_id: friendId });
  } catch (err) {
    chat.hidden = false;
    renderChatList();
    alert(err.message);
  }
}

async function unhideChat(friendId) {
  const chat = chatById(friendId);
  if (!chat?.hidden) return;
  chat.hidden = false;
  renderChatList();
  try {
    await api(`/chats/${friendId}/hidden`, { method: "PUT", json: { on: false } });
  } catch (err) {
    report("warn", "unhiding chat failed", { friend_id: friendId, ...errorFields(err) });
  }
}

/** What this browser holds for a chat, besides the friend's pinned key (kept,
 * so a changed safety code is still caught if the chat comes back). */
function forgetChat(friendId) {
  for (const m of state.messages.get(friendId) || []) state.plaintext.delete(m.id);
  searchCache.delete(`d:${friendId}`);
  state.messages.delete(friendId);
  state.history.delete(friendId);
  state.typing.delete(`d:${friendId}`);
}

/** Puts a row's armed two-tap actions back as they were. */
function disarmRow(li) {
  for (const btn of li?.querySelectorAll(".row-action[data-confirm]") ?? []) {
    armedLeaves.get(btn)?.();
    armedLeaves.delete(btn);
  }
}

/** Leaving from the list takes two taps, like the group's info sheet. The
 * first lasts while the row stays where it was: swiping it shut, moving the
 * pointer off it, or focus leaving it disarms it (disarmRow). */
const armedLeaves = new WeakMap(); // an armed Leave button -> how to put it back
async function leaveFromList(btn, g) {
  if (!btn.dataset.confirm) {
    const label = btn.querySelector(".row-action-label");
    const was = { text: label.textContent, aria: btn.getAttribute("aria-label"), title: btn.title };
    armedLeaves.set(btn, () => {
      delete btn.dataset.confirm;
      label.textContent = was.text;
      btn.setAttribute("aria-label", was.aria);
      btn.title = was.title;
      btn.classList.remove("confirm");
    });
    btn.dataset.confirm = "1";
    label.textContent = "Tap to leave";
    btn.setAttribute("aria-label", `Tap again to leave ${g.name}`);
    btn.title = "Click again to leave";
    btn.classList.add("confirm");
    return;
  }
  try {
    await leaveGroup(g.id);
  } catch (err) {
    alert(err.message);
  }
}

// ---------- mute (X3) ----------
// No notifications (the server skips them) and no unread dot, for 8 hours, a
// week, or until turned back on. Private, and on every device, like favorites.

function muteAction(kind, item, name) {
  return isMuted(item)
    ? { label: "Unmute", icon: "bell", aria: `Unmute ${name}`, run: () => setMute(kind, item.id, name, false) }
    : { label: "Mute", icon: "bell", aria: `Mute ${name}`, run: () => openMuteDialog(kind, item.id, name) };
}

let muteTarget = null;
function openMuteDialog(kind, id, name) {
  muteTarget = { kind, id, name };
  $("#mute-title").textContent = `Mute ${name}`;
  $("#mute-dialog").showModal();
}
for (const b of document.querySelectorAll("#mute-dialog [data-hours]")) {
  b.addEventListener("click", () => {
    $("#mute-dialog").close();
    if (muteTarget) setMute(muteTarget.kind, muteTarget.id, muteTarget.name, true, Number(b.dataset.hours) || null);
  });
}

async function setMute(kind, id, name, on, hours = null) {
  const item = kind === "groups" ? groupById(id) : chatById(id);
  if (!item) return;
  const was = { muted: item.muted, muted_until: item.muted_until };
  item.muted = on;
  item.muted_until = on && hours ? Math.floor(Date.now() / 1000) + hours * 3600 : null; // until the server says
  renderChatList();
  try {
    const r = await getJSON(`/${kind}/${id}/mute`, { method: "PUT", json: hours ? { on, hours } : { on } });
    item.muted_until = r.muted_until;
    if (on) showToast(`Muted ${name}.`, () => setMute(kind, id, name, false));
  } catch (err) {
    Object.assign(item, was);
    renderChatList();
    alert(err.message);
  }
}

// ---------- search (X3) ----------
// Messages are end-to-end encrypted, so searching happens here: over each
// chat's latest messages, fetched and decrypted at most once a minute. Chat
// names match as you type.
const SEARCH_DEPTH = 200;
const SEARCH_FRESH_MS = 60_000;
const searchCache = new Map(); // "d:<id>" or "g:<id>" -> { at, msgs }; emptied when searching ends
let searchTimer = null;

$("#chat-search").addEventListener("input", (e) => {
  state.search = { q: e.target.value, hits: null };
  renderChatList();
  clearTimeout(searchTimer);
  const q = e.target.value.trim();
  if (q.length >= 2) searchTimer = setTimeout(() => runSearch(q), 250);
  else if (!q) searchCache.clear(); // done searching: the decrypted copies go
});
$("#chat-search").addEventListener("keydown", (e) => {
  if (e.key === "Escape") clearSearch();
});

function clearSearch() {
  $("#chat-search").value = "";
  state.search = { q: "", hits: null };
  searchCache.clear();
  renderChatList();
}

/** A chat's newest messages, decrypted: what's loaded here if it reaches back
 * as far as a search looks, else fetched (and kept for a minute). */
async function searchHistory(src) {
  const here = src.loaded();
  if (here) return here;
  const cached = searchCache.get(src.key);
  if (cached && Date.now() - cached.at < SEARCH_FRESH_MS) return cached.msgs;
  const msgs = await getJSON(src.url);
  await Promise.all(msgs.map(src.decrypt));
  searchCache.set(src.key, { at: Date.now(), msgs });
  return msgs;
}

/** The newest SEARCH_DEPTH of a chat's loaded messages, if they're that many
 * (or the whole chat) and nothing newer than them is missing. */
function loadedForSearch(msgs, history, last) {
  if (!msgs?.length || !history) return null;
  if (last && msgs[msgs.length - 1].id < last.id) return null;
  if (msgs.length < SEARCH_DEPTH && history.hasMore) return null;
  return msgs.slice(-SEARCH_DEPTH);
}

async function runSearch(q) {
  const needle = q.toLowerCase();
  for (const [key, found] of searchCache) if (Date.now() - found.at >= SEARCH_FRESH_MS) searchCache.delete(key);
  // A chat without a single message has nothing to look through.
  const sources = [
    ...state.chats.filter((c) => c.last_message).map((c) => ({
      key: `d:${c.id}`, name: chatName(c), open: () => openChat(c.id),
      loaded: () => loadedForSearch(state.messages.get(c.id), state.history.get(c.id), c.last_message),
      url: `/chats/${c.id}/messages?limit=${SEARCH_DEPTH}`, decrypt, text: (m) => (m.kind === "text" ? m.text : null),
    })),
    ...state.groups.filter((g) => g.last_message).map((g) => ({
      key: `g:${g.id}`, name: g.name, open: () => openGroup(g.id),
      loaded: () => loadedForSearch(state.groupMessages.get(g.id), state.groupHistory.get(g.id), g.last_message),
      url: `/groups/${g.id}/messages?limit=${SEARCH_DEPTH}`, decrypt: openGroupMessage,
      text: (m) => (m.kind === "text" && !m.pic && !m.undecryptable ? m.body : null),
    })),
  ];
  const hits = [];
  for (let i = 0; i < sources.length; i += 4) {
    const batch = sources.slice(i, i + 4);
    const loaded = await Promise.all(batch.map((src) => searchHistory(src).catch((err) => {
      report("warn", "search loading failed", errorFields(err));
      return [];
    })));
    if (state.search.q.trim() !== q) return; // typing moved on
    batch.forEach((src, k) => {
      for (const m of loaded[k]) {
        const t = src.text(m);
        if (t && t.toLowerCase().includes(needle)) hits.push({ src, m, t });
      }
    });
  }
  hits.sort((a, b) => b.m.created_at - a.m.created_at);
  state.search.hits = hits.slice(0, 30);
  renderChatList();
}

/** The "Messages" part of the list while searching; `keep` is drawChatList's. */
function searchResults(q, keep) {
  const hits = state.search.hits;
  const note = (key, text) => keep(`note:${key}`, "", () => el("li", { class: "search-note", text }));
  if (!hits) return [note("looking", "Looking through your messages…")];
  if (!hits.length) return [note("no-messages", "No messages with that in the last 200 of each chat.")];
  return hits.map((h) => keep(`hit:${h.src.key}:${h.m.id}`, JSON.stringify([q, h.src.name, relTime(h.m.created_at), h.t]), () => {
    const i = h.t.toLowerCase().indexOf(q);
    const start = Math.max(0, i - 30);
    const end = i + q.length;
    return el("li", {}, el("button", { type: "button", class: "search-hit", onclick: () => openHit(h) },
      el("span", { class: "search-who" },
        el("span", { text: h.src.name }),
        el("span", { class: "search-time", text: relTime(h.m.created_at) })),
      el("span", { class: "search-snippet" },
        `${start > 0 ? "…" : ""}${h.t.slice(start, i)}`,
        el("mark", { text: h.t.slice(i, end) }),
        `${h.t.slice(end, end + 70)}${h.t.length > end + 70 ? "…" : ""}`)));
  }));
}

/** Opens the chat at the message. */
async function openHit(h) {
  await h.src.open();
  showMessage(h.src.key[0], Number(h.src.key.slice(2)), h.m.id);
}

/**
 * In the open chat ("d", a friend's id) or group ("g"), brings one message
 * into view and flashes it: a search hit, or a link to a message (Team
 * Napsack's warnings). Loads earlier pages until it's there, or the history
 * begins. Says so when it isn't there to show (not in your history, or gone).
 */
async function showMessage(kind, ownerId, messageId) {
  const group = kind === "g";
  const open = () => (group ? state.activeGroupId : state.activeId) === ownerId;
  for (let pages = 0; pages < 100 && open(); pages++) {
    const msgs = (group ? state.groupMessages : state.messages).get(ownerId);
    const h = (group ? state.groupHistory : state.history).get(ownerId);
    if (!msgs?.length || msgs[0].id <= messageId || !h?.hasMore) break;
    await (group ? loadOlderGroup(ownerId) : loadOlder(ownerId));
  }
  if (!open()) return;
  const li = $(`#messages [data-key="${kind}:${messageId}"]`);
  if (!li) {
    showToast("That message isn't in this chat any more, or it's from before you joined.");
    return;
  }
  showInChat(li);
  li.classList.add("flash");
  setTimeout(() => li.classList.remove("flash"), 1700);
}

let toastTimer = null;
/** A short note at the bottom, with Undo when there's something to undo. */
function showToast(text, undo) {
  clearTimeout(toastTimer);
  $("#toast-text").textContent = text;
  $("#toast-undo").hidden = !undo;
  $("#toast-undo").onclick = () => { hideToast(); undo(); };
  $("#toast").hidden = false;
  toastTimer = setTimeout(hideToast, 6000);
}
function hideToast() {
  clearTimeout(toastTimer);
  $("#toast").hidden = true;
}

// Swiping a row sideways (touch) slides it over to show its actions. The
// list's touch handlers below decide whether a drag is a swipe or a scroll.
const rowSwipe = { open: null };
function shiftRow(row, px, animate = true) {
  const item = row.querySelector(".chat-item");
  row.classList.toggle("swiping", !animate);
  item.style.transform = px ? `translateX(${px}px)` : "";
}
function closeSwipedRow() {
  if (rowSwipe.open) shiftRow(rowSwipe.open, 0);
  disarmRow(rowSwipe.open);
  rowSwipe.open = null;
}

// ---------- where the chat is scrolled ----------
// Few rules, all about the newest message (Nate, 2026-11-02). Opening a chat
// shows it, at the bottom, and so does sending. While you're at (or very
// near) the bottom, anything that adds to the chat or squeezes it (a new
// message, the typing line, the composer growing, the phone keyboard) keeps
// it fully in view. Once you've scrolled up, nothing moves what you're
// reading: older pages load above it and new messages arrive below it.
// Nothing else scrolls the chat but you. (The browser's own scroll anchoring
// is off for the chat, in style.css, so these are the rules in every browser.)
const NEAR_BOTTOM_PX = 40;
// `pinned`: at the bottom, keeping the newest message in view. `anchor`:
// otherwise, what's at the top of the view (topInView), to keep where it is.
const scroller = { pinned: true, anchor: null };

const atBottom = (list) => list.scrollHeight - list.scrollTop - list.clientHeight <= NEAR_BOTTOM_PX;

/** Opening a chat, or sending: the newest message, at the bottom, from now on. */
function toNewest() {
  scroller.pinned = true;
  scroller.anchor = null;
}

/**
 * The first message in view (else the first thing), and how far below the
 * chat's top edge it starts. A message's own bubble, because the lines
 * around messages come and go: a sender's name moves up to the first of
 * theirs when older messages from them load above.
 */
function topInView(list) {
  const items = list.children;
  if (!items.length || !list.clientHeight) return null;
  const box = list.getBoundingClientRect();
  let lo = 0;
  let hi = items.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (items[mid].getBoundingClientRect().bottom > box.top) hi = mid;
    else lo = mid + 1;
  }
  for (let i = lo; i < items.length; i++) {
    const r = items[i].getBoundingClientRect();
    if (r.top >= box.bottom) break;
    const key = chatDrawn.keys.get(items[i]);
    if (key?.startsWith("m:")) return { node: items[i], key, from: r.top - box.top };
  }
  const node = items[lo];
  return { node, key: chatDrawn.keys.get(node), from: node.getBoundingClientRect().top - box.top };
}

/** Scrolls so `anchor` (from topInView) is back where it was, whatever changed around it. */
function keepInView(list, anchor) {
  if (!anchor || !list.clientHeight) return;
  const node = anchor.node.isConnected ? anchor.node : chatDrawn.nodes.get(anchor.key)?.node;
  if (!node?.isConnected) return;
  const moved = node.getBoundingClientRect().top - list.getBoundingClientRect().top - anchor.from;
  if (Math.abs(moved) >= 0.5) list.scrollTop += moved;
}

/** After the chat changed: the rules. `before` is topInView from just before the change. */
function settleScroll(list, before) {
  if (scroller.pinned) {
    list.scrollTop = list.scrollHeight;
    return;
  }
  keepInView(list, before ?? scroller.anchor);
  if (!list.clientHeight) return; // not on screen: nothing to measure, and the anchor stays
  // What was below may have gone (a "Sending…" line): at the bottom now is at the bottom.
  if (atBottom(list)) toNewest();
  else scroller.anchor = topInView(list);
}

/** Scrolls to put `node` in the middle of the chat: a search hit, or the message a reply quotes. Asked for. */
function showInChat(node, smooth = false) {
  const list = $("#messages");
  const r = node.getBoundingClientRect();
  const box = list.getBoundingClientRect();
  const max = list.scrollHeight - list.clientHeight;
  const top = Math.max(0, Math.min(max, list.scrollTop + r.top - box.top - (box.height - r.height) / 2));
  scroller.pinned = max - top <= NEAR_BOTTOM_PX; // where it ends up; the scroll events follow it there
  list.scrollTo({ top, behavior: smooth ? "smooth" : "auto" });
  if (!smooth) scroller.anchor = scroller.pinned ? null : topInView(list);
}

/** Scrolls just enough to show all of `node`: the row a tap on a message just opened. */
function revealInChat(node) {
  if (!node) return;
  const list = $("#messages");
  const r = node.getBoundingClientRect();
  const box = list.getBoundingClientRect();
  if (r.bottom > box.bottom) list.scrollTop += Math.min(r.bottom - box.bottom, r.top - box.top);
  else if (r.top < box.top) list.scrollTop -= box.top - r.top;
}

$("#messages").addEventListener("scroll", () => {
  const list = $("#messages");
  if (!list.clientHeight) return; // not on screen
  scroller.pinned = atBottom(list);
  scroller.anchor = scroller.pinned ? null : topInView(list);
  if (list.scrollTop >= 200) return;
  if (state.activeId) loadOlder(state.activeId);
  else if (state.activeGroupId) loadOlderGroup(state.activeGroupId);
}, { passive: true });

// The chat's own size changed (the composer grew, the typing line or a reply
// came, the keyboard or the window): the same rules.
new ResizeObserver(() => {
  const list = $("#messages");
  if (!list.clientHeight) return;
  if (scroller.pinned) list.scrollTop = list.scrollHeight;
  else keepInView(list, scroller.anchor);
}).observe($("#messages"));

// ---------- drawing the conversation ----------
// Each thing in a chat (a sender line, a bubble, its reactions, "Seen", ...)
// has a key and a signature of what it shows. Drawing again builds only what
// changed and leaves the rest in place, so a new message is a new row or two,
// and what you're reading isn't rebuilt under you.
const chatDrawn = { owner: null, nodes: new Map(), keys: new WeakMap() };

/** Shows `items` ({ key, sig, make }) as the conversation `owner` ("d:<friend>" or "g:<group>"). */
function drawConversation(owner, items) {
  const list = $("#messages");
  if (chatDrawn.owner !== owner) {
    chatDrawn.owner = owner;
    chatDrawn.nodes = new Map();
    list.replaceChildren();
  }
  const before = scroller.pinned ? null : topInView(list);
  const next = new Map();
  const nodes = items.map((item) => {
    const had = chatDrawn.nodes.get(item.key);
    const node = had?.sig === item.sig ? had.node : item.make();
    next.set(item.key, { sig: item.sig, node });
    chatDrawn.keys.set(node, item.key);
    return node;
  });
  placeChildren(list, nodes);
  chatDrawn.nodes = next;
  settleScroll(list, before);
}

/** A plain line in a chat: who's talking, a note, a group event. */
const chatLine = (key, cls, text) => ({ key, sig: `${cls}|${text}`, make: () => el("li", { class: cls, text }) });

// ---------- conversation ----------

/**
 * Opens a chat, at its newest message. `keepScroll`: it's already open and
 * this only catches up (after reconnecting), so wherever it's scrolled stays.
 */
async function openChat(friendId, { keepScroll = false } = {}) {
  const chat = chatById(friendId);
  if (!chat) return;
  if (chat.hidden) unhideChat(friendId); // opening a hidden chat brings it back
  if (state.activeId !== friendId) {
    setReply(null);
    state.actionFor = null;
  }
  if (!keepScroll || state.activeId !== friendId) toNewest();
  state.activeId = friendId;
  state.activeGroupId = null;
  setConversationMode("direct");
  $("#app").classList.add("in-chat");
  closeProfileTab();
  $("#chat-placeholder").hidden = true;
  $("#chat").hidden = false;
  renderChatHeader();
  renderChatList();
  renderMessages();
  if (!state.messages.has(friendId)) {
    await showKeptPage(`chat:${friendId}`, decrypt, () => state.activeId === friendId && !state.messages.has(friendId), (page) => {
      state.messages.set(friendId, page);
      // A page shorter than any page size is the whole chat; otherwise there may be more.
      state.history.set(friendId, { hasMore: page.length >= SLOW_PAGE, loading: false });
    });
  }
  try {
    const size = pageSize();
    const text = await api(`/chats/${friendId}/messages?limit=${size}`, { as: "text" });
    const page = JSON.parse(text);
    keepAnswer(`chat:${friendId}`, text); // as sent: still encrypted
    await Promise.all(page.map(decrypt));
    if (state.activeId !== friendId) return;
    const loaded = state.messages.get(friendId);
    // Reopening or reconnecting: merge the newest page into what's loaded, so
    // scrolled-back history stays. If the page doesn't reach what we have (a
    // gap), start over from the newest page.
    if (loaded?.length && page.length && page[0].id <= loaded[loaded.length - 1].id) {
      for (const m of page) await upsertMessage(m);
    } else {
      state.messages.set(friendId, page);
      state.history.set(friendId, { hasMore: page.length === size, loading: false });
    }
    renderMessages();
    fillViewport(friendId);
    markRead(friendId);
  } catch (err) {
    report("warn", "opening chat failed", { friend_id: friendId, ...errorFields(err) });
    if (!state.messages.has(friendId)) {
      state.loadFailed.set(`d:${friendId}`, err.message);
      if (state.activeId === friendId) renderMessages();
    }
  }
  // Catching up never moves the cursor (someone may be typing in the search box).
  if (!keepScroll && matchMedia("(min-width: 760px)").matches) $("#composer-input").focus();
}

function closeChat() {
  state.activeId = null;
  state.activeGroupId = null;
  $("#app").classList.remove("in-chat");
  $("#chat").hidden = true;
  $("#chat-placeholder").hidden = false;
  renderChatList();
}
$("#back-button").addEventListener("click", closeChat);

/** A changed key blocks the chat until it's explained; there's no legitimate reason for one. */
function renderChatHeader() {
  if (!state.me) return;
  const chat = chatById(state.activeId);
  if (!chat) return;
  $("#chat-title").textContent = chatName(chat);
  $("#chat-title").setAttribute("aria-label", `${chatName(chat)}: view profile`);
  // The username is the identity; show it whenever the name on screen differs.
  const sub = [activeText(chat), chatName(chat) !== chat.username || chat.was ? `@${chat.username}` : "",
    chat.was ? `was @${chat.was}` : ""].filter(Boolean);
  $("#chat-sub").textContent = sub.join(" · ");
  $("#chat-sub").hidden = sub.length === 0;
  paintAvatar($("#chat-avatar"), chat);
  $("#key-warning").hidden = !chat.keyChanged;
  $("#key-warning-name").textContent = chat.username;
  $("#key-warning-why").textContent = chat.key_reset_at
    ? `napsack says an admin reset ${chat.username}'s account on ${longDate(chat.key_reset_at)}, which gives them a new key. Compare safety codes to be sure it's really them.`
    : "Keys only change when an admin resets an account, and napsack doesn't say this one was. Someone may be trying to read this chat.";
  resetAcceptButton();
  // A turned-off account (admin_users.rs) keeps its chat, but can't be sent
  // to; nor can Team Napsack (team.rs), which only sends.
  $("#deactivated-note").hidden = !(chat.deactivated || chat.system);
  $("#deactivated-note").textContent = chat.system
    ? "Messages from Team Napsack, for birthdays and other occasions. You can't reply here."
    : "This account has been turned off. You can read your chat, but nothing new can be sent.";
  $("#chat-title").classList.toggle("no-profile", Boolean(chat.system));
  const blocked = chat.keyChanged || chat.deactivated || chat.system;
  $("#composer-input").disabled = blocked;
  $("#composer .send").disabled = blocked;
  $("#camera-button").disabled = blocked;
}

function resetAcceptButton() {
  const btn = $("#key-accept");
  btn.textContent = "Accept without checking";
  delete btn.dataset.confirm;
}

// Accepting unchecked takes two taps, so it can't happen by accident.
$("#key-accept").addEventListener("click", () => {
  const btn = $("#key-accept");
  const chat = chatById(state.activeId);
  if (!chat?.keyChanged) return;
  if (!btn.dataset.confirm) {
    btn.dataset.confirm = "1";
    btn.textContent = "Tap again to accept the new key";
    return;
  }
  acceptNewKey(chat, false);
});

$("#key-compare").addEventListener("click", () => $("#safety-button").click());

$("#safety-trust").addEventListener("click", async () => {
  const chat = chatById(state.activeId);
  $("#safety-dialog").close();
  if (chat?.keyChanged) await acceptNewKey(chat, true);
});

$("#safety-button").addEventListener("click", async () => {
  const chat = chatById(state.activeId);
  if (!chat) return;
  $("#safety-name").textContent = chat.username;
  $("#safety-name-2").textContent = chat.username;
  $("#safety-name-3").textContent = chat.username;
  $("#safety-trust-row").hidden = !chat.keyChanged;
  $("#safety-code").textContent = "…";
  $("#safety-dialog").showModal();
  const code = await e2e.safetyCode(state.identity.publicKey, chat.public_key);
  $("#safety-code").textContent = code.replace(/^((?:\d+ ){2}\d+) /, "$1\n"); // two rows of three
});

/** Loads the page before the oldest loaded message, above what's in view (drawConversation keeps it in place). */
async function loadOlder(friendId) {
  const msgs = state.messages.get(friendId);
  const h = state.history.get(friendId);
  if (h?.loading) return h.running; // a second caller (showMessage) waits for the same page
  if (!msgs?.length || !h?.hasMore) return;
  h.loading = true;
  renderMessages();
  h.running = (async () => {
    try {
      const size = pageSize();
      const page = await getJSON(`/chats/${friendId}/messages?before=${msgs[0].id}&limit=${size}`);
      await Promise.all(page.map(decrypt));
      const have = new Set(msgs.map((m) => m.id));
      msgs.unshift(...page.filter((m) => !have.has(m.id)));
      h.hasMore = page.length === size;
    } catch (err) {
      report("warn", "loading older messages failed", { friend_id: friendId, ...errorFields(err) });
    } finally {
      h.loading = false;
    }
  })();
  await h.running;
  if (state.activeId !== friendId) return;
  renderMessages();
  fillViewport(friendId);
}

/** A short history that doesn't fill the screen can't be scrolled, so keep loading. */
function fillViewport(friendId) {
  const list = $("#messages");
  if (state.activeId === friendId && list.scrollHeight <= list.clientHeight + 40) loadOlder(friendId);
}

async function markRead(friendId) {
  const chat = chatById(friendId);
  // The texts here now: the server marks at least these.
  const sent = new Set((state.messages.get(friendId) || [])
    .filter((m) => m.sender_id === friendId && m.kind === "text" && !m.read_at).map((m) => m.id));
  if (!sent.size && !(chat && chat.unread)) return;
  await sendRead("d", async () => {
    try {
      const { updated } = await getJSON(`/chats/${friendId}/read`, { method: "POST" });
      return updated > 0; // only then does the server tell my devices
    } catch (err) {
      report("warn", "marking read failed", { friend_id: friendId, ...errorFields(err) });
      return false;
    }
  }, () => readByMe(friendId, sent), refreshChatsSoon);
}

function snapLabel(m, mine) {
  if (mine) {
    return { pending: `${capitalize(mediaWord(m))} sent`, opened: "Opened", expired: "Expired unopened" }[m.snap_state];
  }
  return { opened: "Viewed", expired: "Expired" }[m.snap_state];
}

// Videos (plan X28) travel like pics, in their own formats: 4 direct, 5 in groups.
const isVideo = (m) => m.format === e2e.VIDEO_FORMAT || m.format === e2e.GROUP_VIDEO_FORMAT;
const mediaWord = (m) => (isVideo(m) ? "video" : "pic");
const capitalize = (s) => s.charAt(0).toUpperCase() + s.slice(1);

function renderMessages() {
  drawWhoReacted(); // what it shows is part of the chat (F21)
  if (state.activeGroupId) return renderGroupMessages();
  const id = state.activeId;
  if (id == null) return;
  const msgs = state.messages.get(id) || [];
  const chat = chatById(id);
  const byId = new Map(msgs.map((m) => [m.id, m]));

  // "Seen" goes under my latest text if they've read it.
  let lastMineTextId = null;
  for (const m of msgs) if (m.sender_id === state.me.id && m.kind === "text") lastMineTextId = m.id;

  const items = [];
  const h = state.history.get(id);
  if (msgs.length && h) {
    if (h.loading) items.push(chatLine("edge", "msg-meta history-edge", "Loading earlier messages…"));
    else if (!h.hasMore) items.push(chatLine("edge", "msg-meta history-edge", `This is the beginning of your chat with ${chat ? chatName(chat) : "them"}.`));
  }
  let prevSender = null;
  // A friend's new username (X30): said where it happened in the chat.
  let renameNote = chat?.was && chat.renamed_at
    ? chatLine("rename", "msg-meta rename-note", `${chat.was} is now @${chat.username}`) : null;
  for (const m of msgs) {
    if (renameNote && m.created_at > chat.renamed_at) {
      items.push(renameNote);
      renameNote = null;
      prevSender = null;
    }
    const mine = m.sender_id === state.me.id;
    if (m.sender_id !== prevSender) {
      items.push(chatLine(`s:${msgKey(m)}`, `sender ${mine ? "mine" : ""}`, `${mine ? "Me" : chat ? chatName(chat) : ""}  ${clockTime(m.created_at)}`));
      prevSender = m.sender_id;
    }
    if (m.kind === "text") {
      if (m.text == null) {
        items.push(chatLine(`m:${msgKey(m)}`, `msg undecryptable ${mine ? "mine" : ""}`,
          m.unsupported ? "Sent from a newer version of napsack. Reload to read it."
            : m.beforeReset ? "Sent before your account was reset, so it can't be read."
            : "Couldn't decrypt this message."));
      } else {
        items.push(...bubbleItems(m, mine, bodyContent(m.text), byId));
      }
      if (m.id === lastMineTextId && m.read_at) items.push(chatLine("seen", "msg-meta", "Seen"));
    } else {
      items.push(...bubbleItems(m, mine, snapContent(m, mine), byId));
    }
  }
  if (renameNote && msgs.length) items.push(renameNote);
  const sending = outboxItems(`d:${id}`, prevSender);
  items.push(...sending);
  if (!msgs.length && !sending.length) items.push(...emptyChat(state.messages.has(id), `d:${id}`));
  drawConversation(`d:${id}`, items);
}

/** A text's words, for bubbleItems. */
const bodyContent = (text) => ({ sig: `body|${text}`, look: emojiLook(text), make: () => [el("span", { class: "msg-body" }, textNodes(text))] });

/** A text of only one to four emoji shows them large, without the bubble (X53); else nothing special. */
function emojiLook(text) {
  const n = emojiOnly(text, e2e.isReaction);
  return n === 1 ? "emoji-only one" : n ? "emoji-only" : "";
}

/** A direct pic or video: tap to view it, or what became of it. */
function snapContent(m, mine) {
  const canOpen = !mine && m.snap_state === "pending";
  const label = canOpen ? `Tap to view ${mediaWord(m)}` : snapLabel(m, mine);
  return {
    sig: JSON.stringify(["snap", canOpen, label ?? null]),
    make: () => [canOpen
      ? el("button", { type: "button", class: "snap-chip", onclick: () => openPics(liveMessage(m)) },
        el("span", { class: "marker snap", "aria-hidden": "true" }), label)
      : el("span", { class: "snap-chip done" },
        el("span", { class: "marker", "aria-hidden": "true" }), label)],
  };
}

/** What an empty chat shows: placeholders while its first page loads, a way
 * to try again if it couldn't, and "No messages yet." only once it's known. */
function emptyChat(loaded, key) {
  if (loaded) return [chatLine("empty", "msg-meta", "No messages yet.")];
  const failed = state.loadFailed.get(key);
  if (failed) {
    return [{ key: "empty-failed", sig: failed, make: () => el("li", { class: "msg-meta list-problem" },
      el("p", { text: `Couldn't load this chat. ${failed}` }),
      el("button", { type: "button", class: "button", onclick: () => {
        state.loadFailed.delete(key);
        if (key.startsWith("g:")) openGroup(Number(key.slice(2))); else openChat(Number(key.slice(2)));
      } }, "Try again")) }];
  }
  return [0, 1, 2, 3].map((i) => ({ key: `skeleton:${i}`, sig: "",
    make: () => el("li", { class: `msg-skeleton ${i % 2 ? "mine" : ""}`, "aria-hidden": "true" }) }));
}

async function upsertMessage(m) {
  await decrypt(m);
  const fid = friendOf(m);
  const msgs = state.messages.get(fid);
  if (!msgs) return; // chat not loaded yet; it'll fetch on open
  // They may have read it before this copy got here (the "read" event beat
  // the send's own response): it's read all the same.
  if (m.sender_id === state.me.id && m.kind === "text" && !m.read_at && m.created_at <= (state.readUpTo.get(fid) ?? -1)) {
    m.read_at = state.readUpTo.get(fid);
  }
  placeById(msgs, m);
}

/** Puts `m` into `msgs` (oldest first): over the one with its id, or where its id goes, which is nearly always the end. */
function placeById(msgs, m) {
  let lo = 0;
  let hi = msgs.length;
  if (hi && msgs[hi - 1].id < m.id) lo = hi;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (msgs[mid].id < m.id) lo = mid + 1;
    else hi = mid;
  }
  if (msgs[lo]?.id === m.id) msgs[lo] = m;
  else msgs.splice(lo, 0, m);
}

/** The copy of `m` the chat holds now (a later update may have replaced it), for what a tap does. */
function liveMessage(m) {
  const msgs = m.group_id ? state.groupMessages.get(m.group_id) : state.messages.get(friendOf(m));
  return msgs?.find((x) => x.id === m.id) ?? m;
}

$("#composer").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("#composer-input");
  if (state.editing) return sendEdit(input);
  const text = input.value.trim();
  if (text) toNewest(); // sending brings you back to the newest message: yours
  if (text && state.activeGroupId) return sendGroupText(state.activeGroupId, input, text);
  const friendId = state.activeId;
  if (!text || !friendId) return;
  input.value = "";
  fitComposer();
  const replyTo = state.replyTo && !state.replyTo.group ? state.replyTo.id : null;
  setReply(null);
  const clientId = newClientId();
  let ciphertext = null; // sealed once; every retry sends the same bytes and id
  queueSend({
    key: `d:${friendId}`, clientId, text, replyTo,
    send: async () => {
      ciphertext ??= await e2e.encryptText2(await keyFor(friendId), text, replyTo, state.me.id, friendId);
      return getJSON(`/chats/${friendId}/messages`, {
        method: "POST", json: { ciphertext, format: e2e.TEXT_FORMAT, client_id: clientId },
      });
    },
    done: async (m) => {
      state.plaintext.set(m.id, { text, replyTo });
      await upsertMessage(m);
      if (state.activeId === friendId) renderMessages();
    },
  });
});

// ---------- outbox ----------
// Every text goes through here, so a bad connection doesn't lose it. It shows
// at once as "Sending…" and is tried again a few times; each try carries the
// same message id, so the server never stores it twice. If it still can't
// go, it waits as "Not sent" with Try again, and goes by itself as soon as
// napsack is back online. (Unsent texts live only in this page: they're
// never written to the device unencrypted.)
//
// Each chat's texts reach the server in the order they were written, since
// the server's ids are the order everywhere (X40): a text goes only once the
// one before it in the same chat has its answer. Writing stays instant, and
// different chats still send side by side. One that fails holds the ones
// after it until it's sent again or removed. (Pics go on their own.)
const outbox = []; // { key: "d:<friend>" | "g:<group>", n, clientId, text, replyTo, status, error, send, done }
let outboxCount = 0; // each item's `n`, which names its rows on screen

function queueSend(item) {
  item.n = ++outboxCount;
  item.status = "queued";
  outbox.push(item);
  redrawOutbox(item);
  pumpOutbox(item.key);
}

/** Starts a chat's oldest text if it's waiting its turn; the rest wait for it. */
function pumpOutbox(key) {
  const first = outbox.find((x) => x.key === key);
  if (first?.status === "queued") attemptSend(first);
}

async function attemptSend(item) {
  if (item.status === "sending" || !outbox.includes(item)) return;
  item.status = "sending";
  item.error = null;
  redrawOutbox(item);
  for (let i = 0; i < 3; i++) {
    try {
      const m = await item.send();
      settleSend(item);
      await item.done(m);
      return;
    } catch (err) {
      if (!outbox.includes(item)) return; // it arrived another way meanwhile
      item.error = err;
      if (!retryable(err)) break;
      if (i < 2) await sleep(1000 * 3 ** i);
    }
  }
  if (!outbox.includes(item)) return;
  item.status = "failed";
  report("warn", "send failed", errorFields(item.error));
  redrawOutbox(item);
}

/** It's stored (or given up on): out of the outbox, and the chat's next one goes. */
function settleSend(item) {
  const i = outbox.indexOf(item);
  if (i < 0) return;
  outbox.splice(i, 1);
  redrawOutbox(item);
  pumpOutbox(item.key);
}

/** One of mine arrived over the socket: if it's still in the outbox, it went through. */
function arrivedFromMe(m, plain) {
  if (m.sender_id !== state.me.id || !m.client_id) return;
  const item = outbox.find((x) => x.clientId === m.client_id);
  if (!item) return;
  plain.set(m.id, { text: item.text, replyTo: item.replyTo });
  settleSend(item);
}

function redrawOutbox(item) {
  const open = state.activeGroupId ? `g:${state.activeGroupId}` : state.activeId ? `d:${state.activeId}` : null;
  if (item.key === open) renderMessages();
}

/** Back online, or reconnected: anything that failed for the connection's sake goes again. */
function flushOutbox() {
  for (const item of outbox) if (item.status === "failed" && retryable(item.error)) attemptSend(item);
}

/** Texts still on their way, at the bottom of a chat (as drawConversation items). */
function outboxItems(key, prevSender) {
  const waiting = outbox.filter((x) => x.key === key);
  const out = [];
  if (waiting.length && prevSender !== state.me.id) out.push(chatLine("sending-me", "sender mine", "Me"));
  let held = false; // behind one that didn't send
  for (const item of waiting) {
    out.push({ key: `sending:${item.n}`, sig: item.text,
      make: () => el("li", { class: `msg mine pending ${emojiLook(item.text)}` }, el("span", { class: "msg-body", text: item.text })) });
    if (item.status !== "failed") {
      out.push(chatLine(`sending:${item.n}:status`, "msg-meta", held ? "Waiting for the text above." : "Sending…"));
      continue;
    }
    held = true;
    const why = retryable(item.error) || !item.error?.message ? "Not sent: no connection." : `Not sent: ${item.error.message}`;
    const after = waiting.length - waiting.indexOf(item) - 1;
    const hold = after ? ` ${after === 1 ? "The text after it waits" : `The ${after} texts after it wait`} for it.` : "";
    out.push({ key: `sending:${item.n}:status`, sig: `failed|${why}|${hold}`,
      make: () => el("li", { class: "msg-meta send-failed" }, `${why}${hold} `,
        el("button", { type: "button", class: "link", onclick: () => attemptSend(item) }, "Try again"),
        " · ",
        el("button", { type: "button", class: "link", onclick: () => discardSend(item) }, "Remove")) });
  }
  return out;
}

/** Gives up on a send; the text goes back in the box if it's empty, so nothing's lost. */
function discardSend(item) {
  settleSend(item);
  const input = $("#composer-input");
  if (!input.value) {
    input.value = item.text;
    fitComposer();
  }
}

// The message box grows with what's typed; style.css caps it at four lines,
// past which it scrolls inside. It's measured at its natural height while the
// composer holds its own: letting the composer shrink for that moment let the
// chat above grow and lose its place, a few lines at a time, on every
// keystroke of a long message.
function fitComposer() {
  const input = $("#composer-input");
  const form = $("#composer");
  form.style.minHeight = `${form.offsetHeight}px`;
  input.style.height = "auto";
  input.style.height = `${input.scrollHeight + 2}px`; // + the borders (border-box)
  form.style.minHeight = "";
}
$("#composer-input").addEventListener("input", fitComposer);

// On a computer, Enter sends and Shift+Enter starts a new line. On a phone,
// Return starts a new line and the Send button sends, as phone keyboards expect.
const touchFirst = matchMedia("(hover: none) and (pointer: coarse)");
$("#composer-input").addEventListener("keydown", (e) => {
  if (e.key !== "Enter" || e.shiftKey || e.isComposing || touchFirst.matches) return;
  e.preventDefault();
  $("#composer").requestSubmit();
});

// Sending keeps the keyboard up: pressing Send never takes focus from the box.
$("#composer .send").addEventListener("mousedown", (e) => e.preventDefault());

// Dragging the chat down toward the keyboard puts it away, roughly like a
// native app (the web can't make the keyboard follow the finger).
let dragFrom = null;
$("#messages").addEventListener("touchstart", (e) => { dragFrom = e.touches[0].clientY; }, { passive: true });
$("#messages").addEventListener("touchmove", (e) => {
  const input = $("#composer-input");
  if (dragFrom == null || document.activeElement !== input) return;
  if (e.touches[0].clientY - dragFrom > 48) {
    input.blur();
    dragFrom = null;
  }
}, { passive: true });

// ---------- reactions and replies ----------

const msgKey = (m) => (m.group_id ? `g:${m.id}` : `d:${m.id}`);
const replyTarget = (m) => (m.group_id ? m.reply_to : m.replyTo) ?? null;

function whoSent(m) {
  if (m.sender_id === state.me.id) return "You";
  if (m.group_id) return personName(m.sender_id, m.sender_name);
  const chat = chatById(m.sender_id);
  return chat ? chatName(chat) : "";
}

function snippetOf(m) {
  if (m.kind === "snap" || m.pic) return capitalize(mediaWord(m));
  const text = m.group_id ? m.body : m.text;
  return text ? Array.from(text).slice(0, 80).join("") : "Message";
}

/** Who reacted with what: [{ user, emoji }], whether the chat is encrypted or not. */
const reactionsOf = (m) => (m.group_id ? (m.reactions || []).map((r) => ({ user: r.user_id, emoji: r.emoji })) : m.reactionList || []);
const myReaction = (m) => reactionsOf(m).find((r) => r.user === state.me.id)?.emoji ?? null;

/** Who reacted: "You", a friend by what I call them, anyone else in a group by their username. */
function reactorName(m, userId) {
  if (userId === state.me.id) return "You";
  if (!m.group_id) return personName(userId, "");
  return personName(userId, groupUsername(m.group_id, userId) ?? "Someone");
}

/** A group member's username, from whatever's loaded: the members, how far each has read, who sent what. */
function groupUsername(groupId, userId) {
  return groupMemberKeys.get(groupId)?.find((x) => x.id === userId)?.username
    ?? state.groupReads.get(groupId)?.get(userId)?.username
    ?? (state.groupMessages.get(groupId) || []).find((x) => x.sender_id === userId)?.sender_name
    ?? null;
}

/**
 * Each emoji on a message, in the order it was first given, with who gave it
 * (me first, then in the order they reacted): [{ emoji, users: [id] }].
 */
function reactionSummary(m) {
  const by = new Map();
  for (const r of reactionsOf(m)) by.set(r.emoji, [...(by.get(r.emoji) || []), r.user]);
  return [...by].map(([emoji, users]) => ({
    emoji, users: users.includes(state.me.id) ? [state.me.id, ...users.filter((u) => u !== state.me.id)] : users,
  }));
}

/**
 * A message's items for drawConversation: the bubble (with the message it
 * replies to, if any), its reactions, and, when tapped, a row to react or
 * reply. `content` ({ sig, make }) is what's inside the bubble; `byId` finds
 * the message a reply quotes. Taps act on the message as the chat holds it
 * then (liveMessage), since a row is kept as long as it looks the same.
 */
function bubbleItems(m, mine, content, byId) {
  const key = msgKey(m);
  const open = state.actionFor === key;
  const target = replyTarget(m);
  const quote = target != null ? quoteText(byId.get(target)) : null;
  const items = [{
    key: `m:${key}`,
    sig: JSON.stringify([mine, open, quote, content.sig, Boolean(m.edited)]),
    make: () => {
      const parts = [];
      if (target != null) parts.push(quoteButton(m, target, quote));
      parts.push(...content.make());
      if (m.edited) {
        parts.push(el("button", { type: "button", class: "edited-mark", "aria-label": "Edited. See every version", onclick: () => showEdits(liveMessage(m)) }, "Edited"));
      }
      return el("li", {
        class: `msg ${mine ? "mine" : ""} ${open ? "has-actions" : ""} ${content.look ?? ""}`,
        "data-key": key,
        onclick: (e) => {
          if (e.target.closest("button, a")) return;
          state.actionFor = state.actionFor === key ? null : key;
          renderMessages();
          if (state.actionFor === key) revealInChat(chatDrawn.nodes.get(`a:${key}`)?.node);
        },
      }, ...parts);
    },
  }];

  const reactions = reactionsOf(m);
  if (reactions.length) {
    // Each emoji, with who chose it (by the names I know them by, X47), shown on
    // hover; a tap shows them all, and every other emoji with theirs (F21).
    const who = reactionSummary(m).map((r) => [r.emoji, r.users.map((u) => reactorName(m, u))]);
    const me = myReaction(m);
    items.push({
      key: `r:${key}`,
      sig: JSON.stringify([mine, me, who]),
      make: () => el("li", { class: `reactions ${mine ? "mine" : ""}` },
        ...who.map(([emoji, names]) => el("button", {
          type: "button", class: `reaction ${me === emoji ? "is-mine" : ""}`, title: names.join(", "),
          "aria-label": `${emoji} from ${names.join(", ")}. Shows who reacted`,
          onclick: () => openWhoReacted(liveMessage(m), emoji),
        }, emoji, names.length > 1 ? String(names.length) : ""))),
    });
  }

  if (open) {
    const me = myReaction(m);
    const copy = textOf(m) != null;
    const edit = canEdit(m);
    const reportable = canReport(m);
    items.push({
      key: `a:${key}`,
      sig: JSON.stringify([mine, me, copy, edit, reportable]),
      make: () => el("li", { class: `msg-actions ${mine ? "mine" : ""}` },
        // The quick row, then mine if I picked another (a tap takes it back), then + for any emoji (X49).
        ...[...e2e.REACTIONS, ...(me && !e2e.REACTIONS.includes(me) ? [me] : [])].map((emoji) => el("button", {
          type: "button", class: me === emoji ? "is-mine" : "",
          "aria-label": me === emoji ? `Take back your ${emoji}` : `React ${emoji}`,
          onclick: () => react(liveMessage(m), emoji),
        }, emoji)),
        el("button", { type: "button", class: "more-reactions", "aria-label": "React with another emoji", title: "More emoji",
          onclick: () => openEmojiPicker(liveMessage(m)) }, "+"),
        el("button", { type: "button", class: "reply-button", onclick: () => startReply(liveMessage(m)) }, "Reply"),
        copy ? el("button", { type: "button", class: "text-action", onclick: () => copyText(liveMessage(m)) }, "Copy") : null,
        edit ? el("button", { type: "button", class: "text-action", onclick: () => startEdit(liveMessage(m)) }, "Edit") : null,
        reportable ? el("button", { type: "button", class: "text-action", onclick: () => reportMessage(liveMessage(m)) }, "Report") : null),
    });
  }
  return items;
}

// ---------- editing texts (X29) ----------
// Your own texts, for 15 minutes after sending. Every version is kept: an
// edit is a new encrypted row (edits.rs), and "Edited" shows them all.
const EDIT_WINDOW_S = 15 * 60;

/** The words a text shows now (its newest edit), or null for anything else. */
function textOf(m) {
  if (m.group_id) return m.kind === "text" && !m.pic && !m.undecryptable ? m.body : null;
  return m.kind === "text" ? m.text : null;
}

function canEdit(m) {
  if (m.sender_id !== state.me.id || textOf(m) == null) return false;
  if (m.group_id && m.format !== e2e.GROUP_FORMAT) return false; // only encrypted group texts
  return Date.now() / 1000 - m.created_at < EDIT_WINDOW_S;
}

async function copyText(m) {
  state.actionFor = null;
  renderMessages();
  try {
    await navigator.clipboard.writeText(textOf(m));
    showToast("Copied.");
  } catch {
    showToast("Couldn't copy here. Select the text instead.");
  }
}

function startEdit(m) {
  state.actionFor = null;
  setReply(null);
  setEditing({ group: Boolean(m.group_id), id: m.id, m });
  const input = $("#composer-input");
  input.value = textOf(m);
  fitComposer();
  renderMessages();
  input.focus();
}

function setEditing(editing) {
  state.editing = editing;
  $("#reply-bar").hidden = !editing && !state.replyTo;
  $("#reply-bar").classList.toggle("editing", Boolean(editing));
  if (editing) $("#reply-text").textContent = "Editing your message";
  else if (!state.replyTo) $("#reply-text").textContent = "";
}

/** Sends the composer's text as a new version of the one being edited. */
async function sendEdit(input) {
  const { m } = state.editing;
  const text = input.value.trim();
  if (!text) return;
  setEditing(null);
  input.value = "";
  fitComposer();
  if (text === textOf(m)) return renderMessages(); // nothing changed
  try {
    if (m.group_id) {
      const sealed = await sealEditFor(m, text);
      const updated = await withRetries(() => getJSON(`/groups/${m.group_id}/messages/${m.id}/edit`, {
        method: "PUT",
        json: { format: e2e.GROUP_FORMAT, content: e2e.toB64(sealed.content), client_id: sealed.clientId, recipients: sealed.recipients, wraps: sealed.wraps },
      }));
      upsertGroupMessage(updated);
    } else {
      const fid = friendOf(m);
      const ciphertext = await e2e.encryptEdit(await keyFor(fid), text, state.me.id, fid, m.id);
      const clientId = newClientId(); // the same on every try, so a retry isn't a second edit
      const updated = await withRetries(() => getJSON(`/chats/${fid}/messages/${m.id}/edit`, {
        method: "PUT", json: { ciphertext, format: 2, client_id: clientId },
      }));
      await upsertMessage(updated);
    }
    report("info", "text edited", { group: Boolean(m.group_id) });
  } catch (err) {
    report("warn", "editing failed", errorFields(err));
    input.value = text; // nothing lost: it's back in the box to try again
    fitComposer();
    showToast(retryable(err) ? "Couldn't save the edit: the connection dropped. Try again." : err.message);
  }
  renderMessages();
}

/** Seals a group edit for exactly the members the text went to. */
async function sealEditFor(m, text) {
  const members = await groupMembers(m.group_id);
  const wrapKeys = new Map();
  for (const id of m.recipients || []) {
    const member = members.find((x) => x.id === id);
    const pub = member ? await sendingKey(member) : id === state.me.id ? state.identity.publicKey : state.pins[id];
    if (!pub) throw new Error("This text can't be edited: napsack doesn't have the key of everyone it went to.");
    wrapKeys.set(id, await groupWrapKeyFor(id, pub));
  }
  return e2e.encryptGroupEdit(text, m.id, { groupId: m.group_id, senderId: state.me.id, wrapKeys });
}

/** Every version of an edited text, oldest first, each with when it was written. */
async function showEdits(m) {
  const list = $("#edits-list");
  const row = (text, at, label) => el("li", {},
    el("span", { class: "edit-when", text: `${label} · ${clockTime(at)}` }),
    el("span", { class: "edit-text", text: text ?? "Couldn't decrypt this version." }));
  list.replaceChildren(row(m.originalText, m.created_at, "Sent"), el("li", { class: "muted", text: "Loading…" }));
  $("#edits-dialog").showModal();
  try {
    const versions = [];
    if (m.group_id) {
      const edits = await getJSON(`/groups/${m.group_id}/messages/${m.id}/edits`);
      for (const e of edits) {
        let text = null;
        for (const pub of e.key ? await readingKeys(m.sender_id, m.sender_public_key) : []) {
          try {
            text = await e2e.decryptGroupEdit(e2e.fromB64(e.content), e.key, m.id, {
              groupId: m.group_id, senderId: m.sender_id, myId: state.me.id, clientId: e.client_id, recipients: m.recipients || [],
              wrapKey: await groupWrapKeyFor(m.sender_id, pub) });
            break;
          } catch {}
        }
        versions.push({ text, at: e.created_at });
      }
    } else {
      const fid = friendOf(m);
      for (const e of await getJSON(`/chats/${fid}/messages/${m.id}/edits`)) {
        let text = null;
        try {
          text = await withReadKey(fid, (k) => e2e.decryptEdit(k, e.ciphertext, m.sender_id, m.recipient_id, m.id));
        } catch {}
        versions.push({ text, at: e.created_at });
      }
    }
    list.replaceChildren(row(m.originalText, m.created_at, "Sent"), ...versions.map((v) => row(v.text, v.at, "Edited")));
  } catch (err) {
    list.replaceChildren(row(m.originalText, m.created_at, "Sent"), el("li", { class: "form-note", text: `Couldn't load the edits. ${err.message}` }));
  }
}

/** What a reply shows of the message it answers (`target`, if it's loaded). */
const quoteText = (target) => (target ? `${whoSent(target)}: ${snippetOf(target)}` : "Replying to an earlier message");

/** Tapping the quote goes to the message it answers, if it's loaded. */
function quoteButton(m, targetId, text) {
  return el("button", {
    type: "button", class: "quote",
    onclick: () => {
      const li = $(`#messages [data-key="${m.group_id ? "g" : "d"}:${targetId}"]`);
      if (li) showInChat(li, true);
    },
  }, text);
}

/** Same emoji again takes it back; another one replaces it. */
async function react(m, emoji) {
  const next = myReaction(m) === emoji ? null : emoji;
  if (next && !e2e.isReaction(next)) return; // one emoji, nothing else (the server refuses the rest in groups)
  state.actionFor = null;
  try {
    if (m.group_id) {
      const updated = await getJSON(`/groups/${m.group_id}/messages/${m.id}/reaction`, { method: "PUT", json: { emoji: next } });
      upsertGroupMessage(updated);
    } else {
      const fid = friendOf(m);
      const ciphertext = next ? await e2e.encryptReaction(await keyFor(fid), next, state.me.id, fid, m.id) : null;
      const updated = await getJSON(`/chats/${fid}/messages/${m.id}/reaction`, { method: "PUT", json: { ciphertext, format: 2 } });
      await upsertMessage(updated);
    }
  } catch (err) {
    report("warn", "reacting failed", errorFields(err));
    alert(err.message);
  }
  renderMessages();
}

// ---------- any emoji (X49) ----------
// + by the quick row opens every emoji, in Unicode's groups, with a search by
// name. The list (emoji.js) loads the first time it's opened, and the grid is
// built once and kept. Still one reaction per person: a pick replaces mine.
const emojiPicker = { m: null, groups: null, built: false };

function loadEmoji() {
  emojiPicker.groups ??= import("/emoji.js").then((mod) => mod.EMOJI_GROUPS.map(([name, list]) => ({
    name,
    items: list.split("|").map((entry) => {
      const at = entry.indexOf(" ");
      return { emoji: entry.slice(0, at), name: entry.slice(at + 1) };
    }),
  }))).catch((err) => {
    emojiPicker.groups = null; // tried again next time
    throw err;
  });
  return emojiPicker.groups;
}

// Each group's button in the bar: an emoji that says what's in it.
const EMOJI_GROUP_ICONS = {
  "Smileys & Emotion": "😀", "People & Body": "👋", "Animals & Nature": "🐻", "Food & Drink": "🍔",
  "Travel & Places": "🚗", "Activities": "⚽", "Objects": "💡", "Symbols": "🔣", "Flags": "🏁",
};

const emojiChoice = (item) => el("button", {
  type: "button", class: "emoji-choice", "data-emoji": item.emoji, "aria-label": item.name, title: item.name,
}, item.emoji);

async function openEmojiPicker(m) {
  emojiPicker.m = m;
  const dialog = $("#emoji-dialog");
  $("#emoji-search").value = "";
  $("#emoji-note").textContent = "";
  if (!dialog.open) dialog.showModal();
  if (!touchFirst.matches) $("#emoji-search").focus(); // on a phone, the keyboard would cover the list
  let groups;
  try {
    groups = await loadEmoji();
  } catch (err) {
    report("warn", "emoji list failed to load", errorFields(err));
    $("#emoji-note").textContent = "Couldn't load the emoji. Check your connection and try again.";
    return;
  }
  if (!emojiPicker.built) {
    emojiPicker.built = true;
    $("#emoji-groups").replaceChildren(...groups.map((g, i) => el("section", { class: "emoji-group", id: `emoji-group-${i}` },
      el("h3", { text: g.name }),
      el("div", { class: "emoji-grid" }, ...g.items.map(emojiChoice)))));
    $("#emoji-tabs").replaceChildren(...groups.map((g, i) => el("button", {
      type: "button", class: "emoji-tab", "aria-label": g.name, title: g.name,
      onclick: () => $(`#emoji-group-${i}`).scrollIntoView({ block: "start" }),
    }, EMOJI_GROUP_ICONS[g.name] ?? g.items[0]?.emoji ?? "?")));
  }
  $("#emoji-scroll").scrollTop = 0;
  showEmojiMatches();
}

/** The one I've reacted with stands out, so it's plain that picking it again takes it back. */
function markMyEmoji() {
  const mine = emojiPicker.m ? myReaction(liveMessage(emojiPicker.m)) : null;
  for (const b of $("#emoji-dialog").querySelectorAll(".emoji-choice")) {
    b.classList.toggle("is-mine", b.dataset.emoji === mine);
  }
}

/** Searching: the matches by name, in one grid; otherwise every group. */
async function showEmojiMatches() {
  const q = $("#emoji-search").value.trim().toLowerCase();
  $("#emoji-groups").hidden = Boolean(q);
  $("#emoji-tabs").hidden = Boolean(q);
  $("#emoji-results").hidden = !q;
  if (q) {
    const groups = await emojiPicker.groups?.catch(() => null);
    if (!groups || $("#emoji-search").value.trim().toLowerCase() !== q) return; // typed on meanwhile
    const words = q.split(/\s+/);
    const found = groups.flatMap((g) => g.items).filter((item) => words.every((w) => item.name.includes(w)));
    $("#emoji-results").replaceChildren(found.length
      ? el("div", { class: "emoji-grid" }, ...found.map(emojiChoice))
      : el("p", { class: "emoji-none", text: "No emoji by that name." }));
  }
  markMyEmoji();
}

$("#emoji-search").addEventListener("input", showEmojiMatches);
$("#emoji-dialog").addEventListener("click", (e) => {
  const choice = e.target.closest(".emoji-choice");
  if (!choice) return;
  const m = emojiPicker.m;
  $("#emoji-dialog").close();
  if (m) react(liveMessage(m), choice.dataset.emoji);
});
$("#emoji-dialog").addEventListener("close", () => { emojiPicker.m = null; });

// ---------- who reacted (F21) ----------
// A tap on a reaction under a message: who reacted with that emoji, and
// "All", every emoji with who gave it. Direct reactions are opened here (only
// the two of us can read them); a group's come from the server as they are.
// Drawn again with the chat (renderMessages), so a reaction arriving while
// it's open shows in it. A button reacts with the emoji shown, or takes mine back.
const whoReacted = { m: null, emoji: null, sig: null };

function openWhoReacted(m, emoji) {
  Object.assign(whoReacted, { m, emoji, sig: null });
  drawWhoReacted();
  const dialog = $("#reactions-dialog");
  if (whoReacted.m && !dialog.open) dialog.showModal();
}

/** Someone who reacted, for personRow: me, a friend, or a group member by username (null if not known). */
function reactorUser(m, userId) {
  if (userId === state.me.id) return state.me;
  const chat = chatById(userId);
  if (chat) return chat;
  const username = m.group_id ? groupUsername(m.group_id, userId) : null;
  return username ? { id: userId, username } : null;
}

function drawWhoReacted() {
  const dialog = $("#reactions-dialog");
  if (!whoReacted.m) return;
  const m = liveMessage(whoReacted.m);
  // Only over its own chat: another chat opened meanwhile (a notification, a link) closes it.
  if (m.group_id ? state.activeGroupId !== m.group_id : state.activeId !== friendOf(m)) {
    whoReacted.m = null;
    dialog.close();
    return;
  }
  const summary = reactionSummary(m);
  // Nobody has the emoji shown any more: everyone's, then.
  if (whoReacted.emoji && !summary.some((r) => r.emoji === whoReacted.emoji)) whoReacted.emoji = null;
  const shown = whoReacted.emoji;
  const mine = myReaction(m);
  const rows = shown
    ? summary.find((r) => r.emoji === shown).users.map((user) => ({ user, emoji: shown }))
    : summary.flatMap((r) => r.users.map((user) => ({ user, emoji: r.emoji })));
  const people = rows.map((r) => ({ ...r, who: reactorUser(m, r.user) }));
  const sig = JSON.stringify([shown, mine, summary,
    people.map((p) => p.who && [personName(p.who.id, p.who.username), p.who.username, p.who.avatar_id ?? null])]);
  if (sig === whoReacted.sig) return; // nothing it shows has changed (keeps the focus where it is)
  whoReacted.sig = sig;

  // Rebuilt, the focus goes back to the same tab or person.
  const focused = dialog.contains(document.activeElement) ? document.activeElement.dataset.focus : null;
  const total = summary.reduce((n, r) => n + r.users.length, 0);
  const tab = (emoji, label, count) => el("button", {
    type: "button", class: "reaction-tab", "data-focus": `tab:${emoji ?? ""}`, "aria-pressed": String(shown === emoji),
    "aria-label": emoji ? `${emoji}, ${count}` : `All reactions, ${count}`,
    onclick: () => { whoReacted.emoji = emoji; drawWhoReacted(); },
  }, label, el("span", { class: "reaction-count", text: String(count) }));
  $("#reaction-tabs").hidden = summary.length === 0;
  $("#reaction-tabs").replaceChildren(tab(null, "All", total), ...summary.map((r) => tab(r.emoji, r.emoji, r.users.length)));

  const leaving = () => dialog.close();
  $("#reaction-people").replaceChildren(...people.map(({ user, emoji, who }) => {
    const mark = shown ? null : el("span", { class: "reaction-of", text: emoji });
    if (!who) {
      // Someone no longer in the group, whose name isn't loaded: nothing to open.
      return el("li", { class: "person", "data-id": String(user) },
        el("span", { class: "person-open" },
          paintInitial(el("span", { class: "avatar small", "aria-hidden": "true" }), "", user),
          el("span", { class: "person-text" }, el("span", { class: "person-name", text: "Someone" }))),
        mark);
    }
    const li = personRow(who, { suffix: who.id === state.me.id ? " (you)" : "", leaving, controls: [mark] });
    li.querySelector(".person-open").dataset.focus = `person:${user}`;
    return li;
  }));
  $("#reactions-none").hidden = summary.length > 0;
  // Who else can see them (every client says so in each group, CLAUDE.md).
  $("#reactions-privacy").textContent = m.group_id
    ? "Reactions in groups aren't end-to-end encrypted yet: the napsack server can see them."
    : "End-to-end encrypted: only the two of you can see these.";

  // Mine: react with the emoji shown, or take mine back (shown, or on All).
  const button = $("#reaction-mine");
  const target = shown ?? mine;
  button.hidden = !target;
  if (target) {
    button.textContent = mine === target ? `Take back your ${target}` : mine ? `React ${target} instead` : `React ${target}`;
    button.dataset.emoji = target;
  }
  if (focused) dialog.querySelector(`[data-focus="${CSS.escape(focused)}"]`)?.focus();
}

$("#reaction-mine").addEventListener("click", async (e) => {
  const button = e.currentTarget;
  if (!whoReacted.m || button.disabled) return;
  button.disabled = true; // one tap, one change
  try {
    await react(liveMessage(whoReacted.m), button.dataset.emoji);
  } finally {
    button.disabled = false;
  }
});
$("#reactions-dialog").addEventListener("close", () => { whoReacted.m = null; });

function startReply(m) {
  state.actionFor = null;
  setReply({ group: Boolean(m.group_id), id: m.id, who: whoSent(m), snippet: snippetOf(m) });
  renderMessages();
  $("#composer-input").focus();
}

function setReply(reply) {
  state.replyTo = reply;
  if (reply && state.editing) setEditing(null);
  $("#reply-bar").hidden = !reply && !state.editing;
  $("#reply-text").textContent = reply ? `Replying to ${reply.who === "You" ? "yourself" : reply.who}: ${reply.snippet}` : "";
}
$("#reply-cancel").addEventListener("click", () => {
  if (state.editing) {
    setEditing(null);
    $("#composer-input").value = "";
    fitComposer();
  }
  setReply(null);
});

// ---------- typing and active now ----------

const TYPING_MS = 4000;
let lastTypingSent = 0;

const isTyping = (key) => (state.typing.get(key) ?? 0) > Date.now();

function stopTyping(key) {
  if (state.typing.delete(key)) renderTyping();
}

// Tell the friend (or group) at most every couple of seconds while typing.
$("#composer-input").addEventListener("input", (e) => {
  if (!e.target.value.trim() || Date.now() - lastTypingSent < 2000) return;
  lastTypingSent = Date.now();
  if (state.activeId) sendFrame({ type: "typing", to: state.activeId });
  else if (state.activeGroupId) sendFrame({ type: "typing", group: state.activeGroupId });
});

function renderTyping() {
  let names = [];
  if (state.activeId && isTyping(`d:${state.activeId}`)) {
    names = [chatName(chatById(state.activeId))];
  } else if (state.activeGroupId) {
    const prefix = `g:${state.activeGroupId}:`;
    for (const [key, until] of state.typing) {
      if (key.startsWith(prefix) && until > Date.now()) {
        const id = Number(key.slice(prefix.length));
        names.push(personName(id, groupMemberName(state.activeGroupId, id)));
      }
    }
  }
  const line = $("#typing-line");
  line.hidden = names.length === 0;
  line.textContent = names.length === 1 ? `${names[0]} is typing…`
    : names.length === 2 ? `${names[0]} and ${names[1]} are typing…`
    : names.length ? "Several people are typing…" : "";
  renderChatList();
}

/** A group member's username from the loaded messages, for people who aren't my friends. */
function groupMemberName(groupId, userId) {
  const m = (state.groupMessages.get(groupId) || []).find((x) => x.sender_id === userId);
  return m?.sender_name ?? "Someone";
}

/** "Active now", "Active 5m ago", or nothing (hidden, or not seen in a day). */
function activeText(chat) {
  if (chat.active_now) return "Active now";
  if (!chat.last_seen_at) return "";
  const ago = Date.now() / 1000 - chat.last_seen_at;
  if (ago > 86_400) return "";
  if (ago < 60) return "Active just now";
  if (ago < 3600) return `Active ${Math.floor(ago / 60)}m ago`;
  return `Active ${Math.floor(ago / 3600)}h ago`;
}

$("#share-activity").addEventListener("change", async (e) => {
  try {
    await api("/me/settings", { method: "PUT", json: { share_activity: e.target.checked } });
    await refreshMe();
    await refreshChats();
  } catch (err) {
    e.target.checked = !e.target.checked;
    showSecurityNote(err.message);
  }
});

// ---------- notifications ----------
// Push notifications go through the service worker (sw.js). On iPhone they
// work once napsack is added to the Home Screen and opened from there.

const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
const isIPhone = () => /iPhone|iPad|iPod/.test(navigator.userAgent);
const standalone = () => matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
const PUSH_NUDGE_KEY = "napsack.pushNudgeDismissed";

function vapidKey() {
  const b64 = state.config.vapid_public_key.replace(/-/g, "+").replace(/_/g, "/");
  return e2e.fromB64(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
}

async function currentSubscription() {
  if (!pushSupported()) return null;
  const reg = await navigator.serviceWorker.getRegistration();
  return reg ? reg.pushManager.getSubscription() : null;
}

async function turnOnPush() {
  const permission = await Notification.requestPermission();
  if (permission !== "granted") {
    throw new Error(permission === "denied"
      ? "Notifications are blocked for napsack. Allow them in your browser's site settings."
      : "Notifications weren't turned on.");
  }
  const reg = await navigator.serviceWorker.ready;
  const sub = (await reg.pushManager.getSubscription())
    || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: vapidKey() });
  await api("/push/subscriptions", { method: "POST", json: sub.toJSON() });
  report("info", "notifications turned on");
}

async function turnOffPush() {
  const sub = await currentSubscription();
  if (!sub) return;
  await api("/push/subscriptions/remove", { method: "POST", json: { endpoint: sub.endpoint } });
  await sub.unsubscribe();
  report("info", "notifications turned off");
}

/** After signing in, tie this browser's existing subscription to the new session. */
async function syncPush() {
  try {
    // Not `Notification?.permission`: where Notification doesn't exist at all
    // (iPhone Safari outside the Home Screen), naming it throws.
    const sub = pushSupported() && Notification.permission === "granted" ? await currentSubscription() : null;
    if (sub) await api("/push/subscriptions", { method: "POST", json: sub.toJSON() });
  } catch (err) {
    report("warn", "re-registering notifications failed", errorFields(err));
  }
  renderPushNudge();
}

function renderPushNudge() {
  let dismissed = false;
  try { dismissed = localStorage.getItem(PUSH_NUDGE_KEY) === "1"; } catch {}
  // One nudge at a time: the recovery key matters more.
  const show = !dismissed && state.me?.has_recovery_key
    && (pushSupported() ? Notification.permission === "default" : isIPhone() && !standalone());
  $("#push-nudge").hidden = !show;
  $("#push-nudge-text").textContent = pushSupported()
    ? "Get notified when friends message you."
    : "For notifications on iPhone: tap Share, then Add to Home Screen, and open napsack from there.";
  $("#push-nudge-button").hidden = !pushSupported();
}

$("#push-nudge-button").addEventListener("click", async () => {
  try {
    await turnOnPush();
  } catch (err) {
    alert(err.message);
  }
  renderPushNudge();
});
$("#push-nudge-dismiss").addEventListener("click", () => {
  try { localStorage.setItem(PUSH_NUDGE_KEY, "1"); } catch {}
  renderPushNudge();
});

async function renderPushStatus() {
  const btn = $("#push-toggle");
  if (!pushSupported()) {
    $("#push-status").textContent = isIPhone() && !standalone()
      ? "On iPhone, add napsack to your Home Screen (Share, then Add to Home Screen) and open it from there to turn on notifications."
      : "This browser can't show notifications.";
    btn.hidden = true;
    return;
  }
  const on = Notification.permission === "granted" && Boolean(await currentSubscription());
  $("#push-status").textContent = on
    ? "On for this device. They say who sent something, never what."
    : Notification.permission === "denied"
      ? "Blocked in this browser's site settings."
      : "Off for this device.";
  btn.hidden = Notification.permission === "denied";
  btn.textContent = on ? "Turn off notifications" : "Turn on notifications";
  btn.dataset.on = on ? "1" : "";
}

$("#push-toggle").addEventListener("click", async () => {
  try {
    if ($("#push-toggle").dataset.on) await turnOffPush();
    else await turnOnPush();
  } catch (err) {
    showSecurityNote(err.message);
  }
  renderPushStatus();
  renderPushNudge();
});

/** `#chat=7`, `#group=3`, `#friends`: where a notification tap leads; a
 * chat or group with `&message=9` (Team Napsack's warnings, a link in a
 * text) opens at that message. */
async function openFromLink(hash) {
  const m = IN_APP_ROUTE.exec(hash) || /^#(friends)$/.exec(hash);
  if (!m) return;
  history.replaceState(null, "", location.pathname);
  if (m[1] === "friends") return openFriends();
  const id = Number(m[2]);
  const group = m[1] === "group";
  if (!(group ? groupById(id) : chatById(id))) await (group ? refreshGroups() : refreshChats());
  if (!(group ? groupById(id) : chatById(id))) {
    showToast(group ? "That link is to a group you're not in." : "That link is to a chat you don't have.");
    return;
  }
  await (group ? openGroup(id) : openChat(id));
  if (m[3]) showMessage(group ? "g" : "d", id, Number(m[3]));
}

// A link to #chat=... on an open page only changes the hash.
window.addEventListener("hashchange", () => { if (state.me) openFromLink(location.hash); });

// Notifications stay on the lock screen until something closes them. Tapping
// one closes it (sw.js), but opening napsack any other way left the rest
// behind (bug report, 2026-10-28). Once napsack is on screen, they've done
// their job: the chat list shows what's new.
async function clearNotifications() {
  try {
    const reg = await navigator.serviceWorker?.getRegistration();
    for (const n of (await reg?.getNotifications?.()) ?? []) n.close();
  } catch (err) {
    report("debug", "clearing notifications failed", errorFields(err));
  }
}
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && state.me) clearNotifications();
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch((err) => report("warn", "service worker failed", errorFields(err)));
  navigator.serviceWorker.addEventListener("message", (e) => {
    if (e.data?.type === "open" && state.me) openFromLink(new URL(e.data.url).hash);
  });
}

// ---------- realtime ----------

function connectSocket() {
  clearTimeout(state.wsTimer); // a pending retry, if this call came from somewhere else
  if (!state.token) return;
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/api/ws`);
  state.ws = ws;
  ws.onopen = () => {
    report("debug", "socket connected", { retry: state.wsRetry });
    ws.send(JSON.stringify({ type: "auth", token: state.token }));
  };
  ws.onmessage = (e) => {
    try {
      handleEvent(JSON.parse(e.data)).catch((err) => report("error", "handling socket event failed", errorFields(err)));
    } catch (err) {
      report("error", "bad socket frame", errorFields(err));
    }
  };
  ws.onclose = (e) => {
    report("debug", "socket closed", { code: e.code });
    if (state.ws !== ws || !state.token) return;
    const delay = Math.min(30_000, 1000 * 2 ** state.wsRetry++);
    state.wsTimer = setTimeout(connectSocket, delay);
    // A short blip passes unnoticed; a longer one gets a note.
    clearTimeout(conn.bannerTimer);
    conn.bannerTimer = setTimeout(() => {
      if (state.token && navigator.onLine && state.ws?.readyState !== WebSocket.OPEN) setConnBanner("Reconnecting…");
    }, 4000);
  };
}

// ---------- connection ----------
// The live connection can die without saying so (a phone switching networks,
// a laptop waking up). While napsack is on screen it checks every 25 seconds,
// and when it comes back on screen; no answer within 10 seconds means start a
// new one. Going offline shows a note; coming back online reconnects at once
// and sends whatever was waiting.
const HEARTBEAT_MS = 25_000;
const PONG_WAIT_MS = 10_000;
const conn = { heartbeat: null, pongTimer: null, bannerTimer: null };

function startHeartbeat() {
  clearInterval(conn.heartbeat);
  conn.heartbeat = setInterval(checkAlive, HEARTBEAT_MS);
}

function checkAlive() {
  const ws = state.ws;
  if (!ws || ws.readyState !== WebSocket.OPEN || document.visibilityState !== "visible") return;
  clearTimeout(conn.pongTimer);
  ws.send(JSON.stringify({ type: "ping" }));
  conn.pongTimer = setTimeout(() => {
    if (state.ws !== ws) return;
    report("info", "socket unresponsive; reconnecting");
    reconnectNow();
  }, PONG_WAIT_MS);
}

/** Drops the current socket (without waiting on a dead one to close) and starts a new one. */
function reconnectNow() {
  const old = state.ws;
  state.ws = null;
  if (old) {
    old.onclose = null;
    try { old.close(); } catch {}
  }
  state.wsRetry = 0;
  connectSocket();
}

/** `kind` says who set it ("slow", "down" from netWatch; none from the socket). */
function setConnBanner(text, kind = "") {
  clearTimeout(conn.bannerTimer);
  $("#conn-banner").textContent = text ?? "";
  $("#conn-banner").dataset.kind = text ? kind : "";
  $("#conn-banner").hidden = !text || !state.token;
}

window.addEventListener("offline", () => {
  if (state.token) setConnBanner("You're offline. Messages will send when you're back.");
});
window.addEventListener("online", () => {
  if (!state.token) return;
  setConnBanner(null);
  if (state.ws?.readyState !== WebSocket.OPEN) reconnectNow();
  flushOutbox();
});

/** Sends a frame if the socket is open; these are hints, so dropping one is fine. */
function sendFrame(frame) {
  if (state.ws?.readyState === WebSocket.OPEN) state.ws.send(JSON.stringify(frame));
}

// The server holds back push notifications while napsack is on screen.
const sendVisibility = () => sendFrame({ type: "visibility", visible: document.visibilityState === "visible" });
document.addEventListener("visibilitychange", sendVisibility);

// Coming back to napsack with a chat open reads what came into it meanwhile,
// since it's on screen again (readingNow); going away, the tab counts what
// comes next.
document.addEventListener("visibilitychange", () => {
  if (!state.me) return;
  renderChatList();
  if (document.visibilityState !== "visible") return;
  if (state.activeId) markRead(state.activeId);
  if (state.activeGroupId) markGroupRead(state.activeGroupId);
});

// Coming back to a backgrounded tab: catch up instead of trusting a stale socket.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible" || !state.token) return;
  if (!state.ws || state.ws.readyState > WebSocket.OPEN) {
    state.wsRetry = 0;
    connectSocket();
  } else {
    checkAlive(); // it says it's open; make sure
  }
});

async function handleEvent(ev) {
  // A socket's last events can arrive after its session ended and we signed out.
  if (!state.me) return;
  switch (ev.type) {
    case "ready":
      state.wsRetry = 0;
      socketTurn++;
      echoes.clear(); // the last connection's echoes aren't coming
      setConnBanner(null);
      startHeartbeat();
      flushOutbox();
      sendVisibility();
      checkForUpdate();
      // Anything could have happened while disconnected (at the start too:
      // whatever happened between the first load and the socket joining).
      // An answer that hasn't changed costs a request and nothing else.
      refreshChats();
      loadAnnouncement();
      refreshGroups();
      refreshRequests();
      if (state.activeId) openChat(state.activeId, { keepScroll: true });
      else if (state.activeGroupId) openGroup(state.activeGroupId, { keepScroll: true });
      break;
    case "auth_failed":
      signOutLocally("Your session ended. Sign in again.");
      break;
    case "pong":
      clearTimeout(conn.pongTimer);
      break;
    case "message":
    case "message_updated": {
      const m = ev.message;
      const raw = structuredClone(m); // as sent, for the kept chat list (decrypting fills in `m`)
      // Their message arrived, so they're done typing (don't wait out the timer).
      if (ev.type === "message" && m.sender_id !== state.me.id) stopTyping(`d:${m.sender_id}`);
      if (ev.type === "message") arrivedFromMe(m, state.plaintext);
      await upsertMessage(m);
      const fid = friendOf(m);
      listEvent("chats", () => chatGotMessage(m, raw));
      if (fid === state.activeId) {
        renderMessages();
        if (ev.type === "message" && m.sender_id === fid && m.kind === "text" && document.visibilityState === "visible") {
          markRead(fid);
        }
      }
      break;
    }
    case "read": {
      if (ev.by === state.me.id) {
        // Mine: this device's own, applied already, or another device's, which doesn't say what it read.
        if (!ownEcho("d")) refreshChatsSoon();
        break;
      }
      state.readUpTo.set(ev.by, Math.max(ev.at, state.readUpTo.get(ev.by) ?? 0));
      for (const m of state.messages.get(ev.by) || []) {
        if (m.sender_id === state.me.id && m.kind === "text" && !m.read_at && m.created_at <= ev.at) m.read_at = ev.at;
      }
      listEvent("chats", () => friendRead(ev.by, ev.at));
      if (ev.by === state.activeId) renderMessages();
      break;
    }
    case "announcement":
      showAnnouncement(ev.announcement);
      break;
    case "friends_changed":
      friendsChanged();
      break;
    case "group_message": {
      const m = ev.message;
      const raw = structuredClone(m); // as sent, for the kept groups (opening fills in `m`)
      stopTyping(`g:${m.group_id}:${m.sender_id}`);
      arrivedFromMe(m, groupPlain);
      await openGroupMessage(m);
      upsertGroupMessage(m);
      listEvent("groups", () => groupGotMessage(m, raw));
      if (m.group_id === state.activeGroupId) {
        renderMessages();
        if (m.sender_id !== state.me.id && document.visibilityState === "visible") markGroupRead(m.group_id);
      }
      break;
    }
    case "typing": {
      const key = ev.group_id ? `g:${ev.group_id}:${ev.from}` : `d:${ev.from}`;
      state.typing.set(key, Date.now() + TYPING_MS);
      renderTyping();
      setTimeout(renderTyping, TYPING_MS + 50);
      break;
    }
    case "presence": {
      if (!chatById(ev.user_id)) break;
      listEvent("chats", () => {
        const chat = chatById(ev.user_id);
        if (!chat) return;
        chat.active_now = ev.active;
        chat.last_seen_at = ev.last_seen_at;
      });
      if (ev.active === false) state.typing.delete(`d:${ev.user_id}`);
      renderChatList();
      if (state.activeId === ev.user_id) renderChatHeader();
      break;
    }
    case "group_read": {
      const reads = state.groupReads.get(ev.group_id);
      const r = reads?.get(ev.user_id);
      if (r && ev.last_read_id > r.last) {
        r.last = ev.last_read_id;
        if (ev.group_id === state.activeGroupId) renderMessages();
      } else if (reads && !r && ev.group_id === state.activeGroupId) {
        loadGroupReads(ev.group_id); // someone new
      }
      break;
    }
    case "groups_changed":
      // This device's own read of the group comes back this way too: applied already.
      if (ownEcho(`g:${ev.group_id}`)) break;
      groupsChanged(ev.group_id);
      break;
  }
}

// The server says friendships, requests, names, or pictures changed: all of
// it at once rather than in turn. (A burst of these loads at most twice: reload.)
async function friendsChanged() {
  groupMemberKeys.clear(); // a friend's key may have changed (an admin reset): groups ask again before sending
  await Promise.all([refreshChats(), refreshRequests(), refreshMe()]);
  if ($("#group-dialog").open && state.groupDetail) drawGroupInfo();
  // A friend's profile, of someone no longer a friend (they blocked me, or I
  // them on another device), has nothing to show; my own lists who I block.
  const shown = $("#profile-dialog").open ? profileEdit.profile : null;
  if (shown?.kind === "friend" && !chatById(shown.id)) $("#profile-dialog").close();
  if (shown?.kind === "me") loadBlocks();
  if (state.activeGroupId) renderMessages(); // names in group chats come from the friends list
}

// ---------- groups ----------
// Group messages and pics are end-to-end encrypted (format 3,
// docs/implementation/group-encryption.md): each is sealed once with a fresh key, wrapped
// for every member with the key the sender shares with them. The group's name
// and picture aren't encrypted, and every group says so. Messages from before
// a group switched stay plain text (format 0).

const groupById = (id) => state.groups.find((g) => g.id === id);

// ---------- group encryption ----------

const groupWrapKeys = new Map();   // "<user id>:<public key>" -> (promised) wrap key with them
const groupPlain = new Map();      // message id -> { text, replyTo }, or null if it couldn't be opened
const groupEdits = new Map();      // "<message id>:<edit id>" -> the newest edit's text, or null (X29)
const groupMemberKeys = new Map(); // group id -> [{ id, username, public_key }] from the server

class KeyChangedError extends Error {}

/** Derived once per person and key, however many messages ask at the same moment. */
function groupWrapKeyFor(userId, pub) {
  return once(groupWrapKeys, `${userId}:${pub}`, () => e2e.groupWrapKey(state.identity.privateKey, pub, state.me.id, userId));
}

/**
 * The key I'll encrypt to for someone in a group: mine, the one I pinned for
 * them, or (the first time I see them, friend or not) the server's, which
 * gets pinned. If the server now says something else, their key changed:
 * refuse, exactly as a direct chat does.
 */
async function sendingKey(member) {
  if (member.id === state.me.id) return state.identity.publicKey;
  const pinned = state.pins[member.id];
  if (!pinned) {
    state.pins[member.id] = member.public_key;
    await keystore.saveLocal(pinsKey(), state.pins);
    return member.public_key;
  }
  if (pinned !== member.public_key) {
    report("warn", "group member key changed; group blocked", { user_id: member.id });
    throw new KeyChangedError(`${personName(member.id, member.username)}'s safety code changed, so napsack won't send to this group. `
      + "If you're friends, check it in your chat with them.");
  }
  return pinned;
}

/** Keys that could have sealed a message from `senderId`: mine, my pins (newest first), else the server's on first sight. */
async function readingKeys(senderId, serverPub) {
  if (senderId === state.me.id) return [state.identity.publicKey];
  const pinned = state.pins[senderId];
  if (pinned) return [pinned, ...[...(state.pastPins[senderId] || [])].reverse()];
  if (!serverPub) return [];
  state.pins[senderId] = serverPub;
  await keystore.saveLocal(pinsKey(), state.pins);
  return [serverPub];
}

/** Opens a format 3 text in place: `body` and `reply_to` become what the sender wrote. */
async function openGroupMessage(m) {
  if (m.format !== e2e.GROUP_FORMAT || m.kind !== "text") return m;
  if (m.pic) return m; // pics open when tapped
  if (!groupPlain.has(m.id)) {
    let body = null;
    const opts = { groupId: m.group_id, senderId: m.sender_id, myId: state.me.id, clientId: m.client_id, recipients: m.recipients || [] };
    for (const pub of m.key && m.content ? await readingKeys(m.sender_id, m.sender_public_key) : []) {
      try {
        body = await e2e.decryptGroupText(e2e.fromB64(m.content), m.key, { ...opts, wrapKey: await groupWrapKeyFor(m.sender_id, pub) });
        break;
      } catch {}
    }
    if (!body) report("warn", "group decrypt failed", { message_id: m.id, group_id: m.group_id, has_key: Boolean(m.key) });
    groupPlain.set(m.id, body);
  }
  const body = groupPlain.get(m.id);
  m.body = body?.text ?? "";
  m.originalText = m.body;
  m.reply_to = body?.replyTo ?? null;
  m.undecryptable = !body;
  // Edited (X29): the newest version, sealed for the same members with its own id.
  if (body && m.edit_content && m.edit_key) {
    const key = `${m.id}:${m.edit_client_id}`;
    if (!groupEdits.has(key)) {
      let text = null;
      const opts = { groupId: m.group_id, senderId: m.sender_id, myId: state.me.id, clientId: m.edit_client_id, recipients: m.recipients || [] };
      for (const pub of await readingKeys(m.sender_id, m.sender_public_key)) {
        try {
          text = await e2e.decryptGroupEdit(e2e.fromB64(m.edit_content), m.edit_key, m.id, { ...opts, wrapKey: await groupWrapKeyFor(m.sender_id, pub) });
          break;
        } catch {}
      }
      if (text == null) report("warn", "group edit decrypt failed", { message_id: m.id, group_id: m.group_id });
      groupEdits.set(key, text);
    }
    if (groupEdits.get(key) != null) {
      m.body = groupEdits.get(key);
      m.edited = true;
    }
  }
  return m;
}

/** Current members, with keys; `fresh` refetches (after the server said the group changed). */
async function groupMembers(groupId, fresh = false) {
  if (fresh || !groupMemberKeys.has(groupId)) {
    const g = await getJSON(`/groups/${groupId}`);
    groupMemberKeys.set(groupId, g.members);
  }
  return groupMemberKeys.get(groupId);
}

/** Seals something for everyone in the group (`fresh` refetches the members first). */
async function sealFor(groupId, seal, fresh = false) {
  const wrapKeys = new Map();
  for (const member of await groupMembers(groupId, fresh)) {
    wrapKeys.set(member.id, await groupWrapKeyFor(member.id, await sendingKey(member)));
  }
  return seal({ groupId, senderId: state.me.id, wrapKeys });
}

/**
 * A group send that survives a bad connection: sealed once, and every call
 * posts the same sealed message (same message id, so the server returns what
 * it already stored rather than a copy). If someone joined or left meanwhile,
 * the server says 409: seal again for the new members and post that.
 */
function groupSender(groupId, seal, post) {
  let sealed = null;
  return async () => {
    sealed ??= await sealFor(groupId, seal);
    try {
      return await post(sealed);
    } catch (err) {
      if (err.status !== 409) throw err;
      sealed = await sealFor(groupId, seal, true);
      return post(sealed);
    }
  };
}

const keysHeader = (s) => JSON.stringify({ client_id: s.clientId, recipients: s.recipients, wraps: s.wraps });

function refreshGroups() {
  return reload(loads.groups, loadGroups);
}

async function loadGroups() {
  if (!state.loaded.groups && !state.groups.length) await showKeptGroups();
  const me = state.me?.id;
  sinceSent.groups = [];
  let text, groups;
  try {
    text = await api("/groups", { as: "text" });
    groups = JSON.parse(text);
    await Promise.all(groups.map((g) => g.last_message && openGroupMessage(g.last_message)));
  } catch (err) {
    report("warn", "loading groups failed", errorFields(err));
    state.loaded.error = err.message;
    renderChatList();
    return;
  }
  if (!state.me || state.me.id !== me) return;
  const before = new Map(state.groups.map((g) => [g.id, g.member_count]));
  state.groups = groups;
  kept.groups = JSON.parse(text); // as sent: still sealed
  newInGroups.clear();
  const meanwhile = sinceSent.groups;
  sinceSent.groups = [];
  for (const apply of meanwhile) apply();
  if (meanwhile.length) keepListSoon("groups");
  else keepAnswer("groups", text, kept.groups);
  state.loaded.groups = true;
  // Someone joined or left: the members' keys come again before the next
  // send, and the open group's "Seen by" needs the new member list.
  for (const g of groups) {
    if (!before.has(g.id) || before.get(g.id) === g.member_count) continue;
    groupMemberKeys.delete(g.id);
    if (g.id === state.activeGroupId) loadGroupReads(g.id);
  }
  renderChatList();
  if (state.activeGroupId && !groupById(state.activeGroupId)) closeChat(); // removed or left
  else if (state.activeGroupId) renderGroupHeader();
}

let groupRefreshTimer = null;
function refreshGroupsSoon() {
  clearTimeout(groupRefreshTimer);
  groupRefreshTimer = setTimeout(refreshGroups, 150);
}

// The server says a group changed (its name, members, picture, a favorite,
// or my place in it, from another device). A burst loads at most twice (reload).
async function groupsChanged(groupId) {
  await refreshGroups();
  if ($("#group-dialog").open && state.groupDetail?.id === groupId) openGroupInfo(groupId);
}

/** "You added ben", "cal left", ... for membership and name changes. */
function groupEventText(m) {
  let e = {};
  try { e = JSON.parse(m.body); } catch {}
  const actor = m.sender_id === state.me.id ? "You" : personName(m.sender_id, m.sender_name);
  const target = e.target === state.me.id ? "you" : personName(e.target, e.target_name);
  switch (e.type) {
    case "created": return `${actor} created the group “${e.name}”`;
    case "added": return `${actor} added ${target}`;
    case "removed": return `${actor} removed ${target}`;
    case "left": return `${actor} left`;
    case "renamed": return `${actor} renamed the group to “${e.name}”`;
    case "owner": return e.target === state.me.id ? "You're now the owner" : `${personName(e.target, e.target_name)} is now the owner`;
    case "picture": return `${actor} changed the group picture`;
    case "encrypted": return "Messages and pics here are end-to-end encrypted from now on. The group's name and picture aren't.";
    default: return "The group changed";
  }
}

function groupStatus(g) {
  const m = g.last_message;
  if (!m) return { text: `${g.member_count} people` };
  if (m.pic) {
    const mine = m.sender_id === state.me.id;
    const waiting = !mine && !m.pic.discard_reason && !m.pic.viewers.includes(state.me.id);
    const what = `sent a ${mediaWord(m)}`;
    return { text: mine ? `You ${what}` : `${personName(m.sender_id, m.sender_name)} ${what}`, marker: waiting ? "snap" : g.unread && !readingNow("g", g.id) ? "text" : null };
  }
  const text = m.kind === "event"
    ? groupEventText(m)
    : `${m.sender_id === state.me.id ? "You" : personName(m.sender_id, m.sender_name)}: ${m.undecryptable ? "Encrypted message" : m.body}`;
  return { text, marker: g.unread && !readingNow("g", g.id) ? "text" : null };
}

/** Direct chats show the safety code and camera; groups show the notice instead. */
function setConversationMode(kind) {
  const group = kind === "group";
  $("#safety-button").hidden = group;
  $("#camera-button").hidden = false;
  $("#camera-button").disabled = false;
  $("#group-notice").hidden = !group;
  $("#chat-sub").hidden = !group;
  if (group) {
    $("#key-warning").hidden = true;
    $("#deactivated-note").hidden = true;
    $("#composer-input").disabled = false;
    $("#composer .send").disabled = false;
  }
}

function renderGroupHeader() {
  const g = groupById(state.activeGroupId);
  if (!g) return;
  $("#chat-title").textContent = g.name;
  $("#chat-title").setAttribute("aria-label", `${g.name}: group info`);
  $("#chat-sub").textContent = `${g.member_count} ${g.member_count === 1 ? "person" : "people"}`;
  paintGroupAvatar($("#chat-avatar"), g);
}

/** Opens a group, at its newest message (`keepScroll`: as openChat's). */
async function openGroup(groupId, { keepScroll = false } = {}) {
  if (!groupById(groupId)) return;
  if (state.activeGroupId !== groupId) {
    setReply(null);
    state.actionFor = null;
    groupMemberKeys.delete(groupId); // who's in it, with their keys, asked again before sending here
  }
  if (!keepScroll || state.activeGroupId !== groupId) toNewest();
  state.activeId = null;
  state.activeGroupId = groupId;
  setConversationMode("group");
  $("#app").classList.add("in-chat");
  closeProfileTab();
  $("#chat-placeholder").hidden = true;
  $("#chat").hidden = false;
  renderGroupHeader();
  renderChatList();
  renderMessages();
  if (!state.groupMessages.has(groupId)) {
    await showKeptPage(`group:${groupId}`, openGroupMessage, () => state.activeGroupId === groupId && !state.groupMessages.has(groupId), (page) => {
      state.groupMessages.set(groupId, page);
      state.groupHistory.set(groupId, { hasMore: page.length >= SLOW_PAGE, loading: false });
    });
  }
  try {
    const size = pageSize();
    const text = await api(`/groups/${groupId}/messages?limit=${size}`, { as: "text" });
    const page = JSON.parse(text);
    keepAnswer(`group:${groupId}`, text); // as sent: still encrypted
    await Promise.all(page.map(openGroupMessage));
    if (state.activeGroupId !== groupId) return;
    const loaded = state.groupMessages.get(groupId);
    if (loaded?.length && page.length && page[0].id <= loaded[loaded.length - 1].id) {
      for (const m of page) upsertGroupMessage(m);
    } else {
      state.groupMessages.set(groupId, page);
      state.groupHistory.set(groupId, { hasMore: page.length === size, loading: false });
    }
    renderMessages();
    fillGroupViewport(groupId);
    markGroupRead(groupId);
    loadGroupReads(groupId);
  } catch (err) {
    report("warn", "opening group failed", { group_id: groupId, ...errorFields(err) });
    if (!state.groupMessages.has(groupId)) {
      state.loadFailed.set(`g:${groupId}`, err.message);
      if (state.activeGroupId === groupId) renderGroupMessages();
    }
  }
  if (!keepScroll && matchMedia("(min-width: 760px)").matches) $("#composer-input").focus();
}

function upsertGroupMessage(m) {
  const msgs = state.groupMessages.get(m.group_id);
  if (!msgs) return; // not loaded yet; it'll fetch on open
  // However it arrived (a reaction's response, a pic's update), a sealed
  // message shows what it says: from what's already been opened, or by
  // opening it now and drawing again.
  if (m.format === e2e.GROUP_FORMAT && m.kind === "text" && !m.pic) {
    // Already opened, and not edited since: what it says is known. An edit
    // (X29) has to be opened too.
    if (groupPlain.has(m.id)) {
      const body = groupPlain.get(m.id);
      m.body = m.originalText = body?.text ?? "";
      m.reply_to = body?.replyTo ?? null;
      m.undecryptable = !body;
    }
    if (!groupPlain.has(m.id) || m.edit_content) {
      openGroupMessage(m).then(() => { if (state.activeGroupId === m.group_id) renderMessages(); });
    }
  }
  placeById(msgs, m);
}

async function loadOlderGroup(groupId) {
  const msgs = state.groupMessages.get(groupId);
  const h = state.groupHistory.get(groupId);
  if (h?.loading) return h.running; // as loadOlder's
  if (!msgs?.length || !h?.hasMore) return;
  h.loading = true;
  renderMessages();
  h.running = (async () => {
    try {
      const size = pageSize();
      const page = await getJSON(`/groups/${groupId}/messages?before=${msgs[0].id}&limit=${size}`);
      await Promise.all(page.map(openGroupMessage));
      const have = new Set(msgs.map((m) => m.id));
      msgs.unshift(...page.filter((m) => !have.has(m.id)));
      h.hasMore = page.length === size;
    } catch (err) {
      report("warn", "loading older group messages failed", { group_id: groupId, ...errorFields(err) });
    } finally {
      h.loading = false;
    }
  })();
  await h.running;
  if (state.activeGroupId !== groupId) return;
  renderMessages(); // above what's in view, which stays where it is (drawConversation)
  fillGroupViewport(groupId);
}

function fillGroupViewport(groupId) {
  const list = $("#messages");
  if (state.activeGroupId === groupId && list.scrollHeight <= list.clientHeight + 40) loadOlderGroup(groupId);
}

/** Where each member has read up to, for "Seen by". */
async function loadGroupReads(groupId) {
  try {
    const rows = await getJSON(`/groups/${groupId}/reads`);
    state.groupReads.set(groupId, new Map(rows.map((r) => [r.user_id, { username: r.username, last: r.last_read_id }])));
  } catch (err) {
    report("warn", "loading group reads failed", { group_id: groupId, ...errorFields(err) });
    return;
  }
  if (state.activeGroupId === groupId) renderMessages();
}

/** "Seen by Ana and Ben" under the newest message: who else has read that far. */
function seenByText(groupId, last) {
  const reads = state.groupReads.get(groupId);
  if (!reads || !last) return null;
  const others = [...reads].filter(([id]) => id !== state.me.id && id !== last.sender_id);
  const seen = others.filter(([, r]) => r.last >= last.id).map(([id, r]) => personName(id, r.username));
  if (!seen.length) return null;
  if (seen.length === others.length && others.length > 2) return "Seen by everyone";
  if (seen.length > 3) return `Seen by ${seen.slice(0, 2).join(", ")}, and ${seen.length - 2} others`;
  if (seen.length === 1) return `Seen by ${seen[0]}`;
  return `Seen by ${seen.slice(0, -1).join(", ")}${seen.length > 2 ? "," : ""} and ${seen[seen.length - 1]}`;
}

async function markGroupRead(groupId) {
  const g = groupById(groupId);
  if (!g?.unread) return;
  const upTo = g.last_message?.id ?? 0; // the newest when the read goes out: the server reads at least that far
  await sendRead(`g:${groupId}`, async () => {
    try {
      await api(`/groups/${groupId}/read`, { method: "POST" });
      return true; // the server always tells my devices (groups_changed)
    } catch (err) {
      report("warn", "marking group read failed", { group_id: groupId, ...errorFields(err) });
      return false;
    }
  }, () => groupReadByMe(groupId, upTo), () => groupsChanged(groupId));
}

function renderGroupMessages() {
  const groupId = state.activeGroupId;
  const msgs = state.groupMessages.get(groupId) || [];
  const g = groupById(groupId);
  const byId = new Map(msgs.map((m) => [m.id, m]));
  const items = [];
  const h = state.groupHistory.get(groupId);
  if (msgs.length && h) {
    if (h.loading) items.push(chatLine("edge", "msg-meta history-edge", "Loading earlier messages…"));
    else if (!h.hasMore) items.push(chatLine("edge", "msg-meta history-edge", `This is the beginning of ${g?.name ?? "the group"}, from when you joined.`));
  }
  let prevSender = null;
  for (const m of msgs) {
    if (m.kind === "event") {
      items.push(chatLine(`e:${msgKey(m)}`, "msg-meta group-event", groupEventText(m)));
      prevSender = null;
      continue;
    }
    const mine = m.sender_id === state.me.id;
    if (m.sender_id !== prevSender) {
      items.push(chatLine(`s:${msgKey(m)}`, `sender ${mine ? "mine" : ""}`, `${mine ? "Me" : personName(m.sender_id, m.sender_name)}  ${clockTime(m.created_at)}`));
      prevSender = m.sender_id;
    }
    if (m.undecryptable) {
      items.push(chatLine(`m:${msgKey(m)}`, `msg undecryptable ${mine ? "mine" : ""}`, "Couldn't decrypt this message."));
      continue;
    }
    items.push(...bubbleItems(m, mine, groupContent(m, mine), byId));
  }
  const seen = seenByText(groupId, msgs[msgs.length - 1]);
  if (seen) items.push(chatLine("seen-by", "msg-meta seen-by", seen));
  const sending = outboxItems(`g:${groupId}`, prevSender);
  items.push(...sending);
  if (!msgs.length && !sending.length) items.push(...emptyChat(state.groupMessages.has(groupId), `g:${groupId}`));
  drawConversation(`g:${groupId}`, items);
}

/** What's in a group bubble: a pic or video, its words, or both. */
function groupContent(m, mine) {
  const chip = m.pic ? groupPicLabel(m, mine) : null;
  return {
    sig: JSON.stringify(["group", chip, m.body ?? ""]),
    look: chip ? "" : emojiLook(m.body),
    make: () => [
      chip && (chip.canOpen
        ? el("button", { type: "button", class: "snap-chip", onclick: () => openPics(liveMessage(m)) },
          el("span", { class: "marker snap", "aria-hidden": "true" }), chip.label)
        : el("span", { class: "snap-chip done" }, el("span", { class: "marker", "aria-hidden": "true" }), chip.label)),
      m.body ? el("span", { class: "msg-body" }, textNodes(m.body)) : null,
    ].filter(Boolean),
  };
}

/** View-once per member. The sender sees how many have opened it. */
function groupPicLabel(m, mine) {
  const p = m.pic;
  const seen = p.viewers.includes(state.me.id);
  if (!mine && !seen && !p.discard_reason) return { canOpen: true, label: `Tap to view ${mediaWord(m)}` };
  const label = mine
    ? p.discard_reason === "opened" ? "Opened by everyone"
      : p.discard_reason === "expired" ? "Expired"
      : p.viewers.length ? `Opened by ${p.viewers.length}` : `${capitalize(mediaWord(m))} sent`
    : seen ? "Viewed" : "Expired";
  return { canOpen: false, label };
}

/** Fetches (and for formats 3 and 5, decrypts) one group pic or video: { blob, video, caption, from }. */
async function loadGroupPic(m) {
  const url = `/groups/${m.group_id}/pics/${m.pic.id}`;
  const from = `${personName(m.sender_id, m.sender_name)} · ${groupById(m.group_id)?.name ?? ""}`;
  if ([e2e.GROUP_FORMAT, e2e.GROUP_VIDEO_FORMAT, e2e.GROUP_IMAGE_FORMAT].includes(m.format)) {
    const sealed = await api(url, { as: "bytes" });
    const opts = { groupId: m.group_id, senderId: m.sender_id, myId: state.me.id, clientId: m.client_id, recipients: m.recipients || [] };
    for (const pub of m.key ? await readingKeys(m.sender_id, m.sender_public_key) : []) {
      try {
        const wrapKey = await groupWrapKeyFor(m.sender_id, pub);
        if (isVideo(m)) {
          const v = await e2e.decryptGroupVideo(sealed, m.key, { ...opts, wrapKey });
          return { blob: new Blob([v.media], { type: v.type }), video: true, caption: v.caption, y: v.y, from };
        }
        if (m.format === e2e.GROUP_IMAGE_FORMAT) {
          const p = await e2e.decryptGroupImage(sealed, m.key, { ...opts, wrapKey });
          return { blob: new Blob([p.media], { type: "image/jpeg" }), caption: p.caption, y: p.y, from };
        }
        const pic = await e2e.decryptGroupPic(sealed, m.key, { ...opts, wrapKey });
        return { blob: new Blob([pic.photo], { type: "image/jpeg" }), caption: pic.caption, from };
      } catch {}
    }
    report("warn", "group pic decrypt failed", { message_id: m.id, group_id: m.group_id, video: isVideo(m) });
    throw new PicProblem(`This ${mediaWord(m)} couldn't be decrypted.`);
  }
  if (m.format !== groupsPlainFormat) throw new PicProblem(`This ${mediaWord(m)} was sent from a newer version of napsack. Reload to open it.`);
  const res = await api(url);
  let caption = "";
  try { caption = decodeURIComponent(res.headers.get("X-Napsack-Caption") || ""); } catch {}
  return { blob: await res.blob(), caption, from };
}

/** Format 0: group pics from before a group's messages were encrypted. */
const groupsPlainFormat = 0;

/** What to say when a pic couldn't be sent. */
function sendProblem(err) {
  return retryable(err)
    ? `Couldn't send: the connection dropped. Your ${camera.videoType ? "video" : "pic"} is still here; tap Send to try again.`
    : err.message;
}

/** Square-cropped to 256px and kept small; group and profile pictures live in the database. */
async function squarePictureBlob(file) {
  const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  const side = Math.min(bitmap.width, bitmap.height);
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 256;
  canvas.getContext("2d").drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side, 0, 0, 256, 256);
  bitmap.close();
  for (const q of [0.85, 0.7, 0.55]) {
    const blob = await encodeJpeg(canvas, q);
    if (blob.size <= 100 * 1024) return blob;
  }
  throw new Error("Couldn't make that picture small enough.");
}

$("#group-picture-input").addEventListener("change", async (e) => {
  const file = e.target.files?.[0];
  e.target.value = "";
  const g = state.groupDetail;
  if (!file || !g) return;
  await groupAction(async () => {
    const blob = await squarePictureBlob(file);
    await api(`/groups/${g.id}/avatar`, { method: "POST", body: blob, headers: { "Content-Type": "image/jpeg" } });
  }, "Group picture updated.");
});

async function sendGroupText(groupId, input, text) {
  input.value = "";
  fitComposer();
  const replyTo = state.replyTo?.group ? state.replyTo.id : null;
  setReply(null);
  const item = { key: `g:${groupId}`, clientId: null, text, replyTo };
  item.send = groupSender(groupId,
    (opts) => e2e.encryptGroupText(text, replyTo, opts),
    (s) => {
      item.clientId = s.clientId; // so the socket's copy can settle it
      return getJSON(`/groups/${groupId}/messages`, { method: "POST", json: {
        format: e2e.GROUP_FORMAT, content: e2e.toB64(s.content), client_id: s.clientId, recipients: s.recipients, wraps: s.wraps,
      } });
    });
  item.done = async (m) => {
    groupPlain.set(m.id, { text, replyTo });
    await openGroupMessage(m);
    upsertGroupMessage(m);
    if (state.activeGroupId === groupId) renderMessages();
  };
  queueSend(item);
}

// New group: a name and some friends.

// A tap anywhere on a row picks them (it's a checkbox's label), so here the
// row doesn't open their profile as other lists of people do.
function friendPicker(friends, checked = new Set()) {
  return friends.map((f) => el("li", {},
    el("label", { class: "person pick" },
      el("input", { type: "checkbox", name: "member", value: String(f.id), checked: checked.has(f.id) || null }),
      personAvatar(f),
      personText(f))));
}

// The + in the chat list bar starts something new. Friends (adding, invites)
// has its own button, so this holds everything else. With one thing to start,
// + goes straight to it; when there's a second, + becomes a short menu of
// these, and the bar looks the same.
const START_ACTIONS = [{ label: "New group", run: openNewGroup }];
$("#start-button").addEventListener("click", () => START_ACTIONS[0].run());

function openNewGroup() {
  $("#new-group-form").reset();
  $("#new-group-note").textContent = "";
  // (Team Napsack isn't a friend: it can't be in a group.)
  const friends = state.chats.filter((c) => !c.system).sort((a, b) => chatName(a).localeCompare(chatName(b)));
  $("#new-group-friends").replaceChildren(...friendPicker(friends));
  if (!friends.length) $("#new-group-friends").append(el("li", { class: "muted", text: "Add some friends first." }));
  $("#new-group-dialog").showModal();
  $("#new-group-name").focus();
}

$("#new-group-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.currentTarget;
  const memberIds = [...form.querySelectorAll("input[name=member]:checked")].map((c) => Number(c.value));
  const btn = $("#new-group-submit");
  btn.disabled = true;
  try {
    const g = await getJSON("/groups", { method: "POST", json: { name: $("#new-group-name").value, member_ids: memberIds } });
    report("info", "group created", { group_id: g.id, members: g.members.length });
    $("#new-group-dialog").close();
    await refreshGroups();
    openGroup(g.id);
  } catch (err) {
    $("#new-group-note").textContent = err.message;
  } finally {
    btn.disabled = false;
  }
});

// Group info: rename, members, add, remove (owner), leave.

/** Opens the info sheet (or brings it up to date) with the group as the server has it now. */
async function openGroupInfo(groupId) {
  // A refresh of the open sheet that comes back after it was closed leaves it
  // closed: on a slow connection the answer can land after the tap on Close.
  const refreshing = $("#group-dialog").open;
  let g;
  try {
    g = await getJSON(`/groups/${groupId}`);
  } catch (err) {
    if ($("#group-dialog").open) $("#group-dialog").close();
    return;
  }
  if (refreshing && !$("#group-dialog").open) return;
  state.groupDetail = g;
  groupMemberKeys.set(groupId, g.members); // the same members, with keys, that sending seals for
  drawGroupInfo();
}

// What the open sheet shows, so an update that changes none of it leaves it
// as it is (a "Tap again to leave" on its way included).
let groupInfoShown = null;

/** The info sheet, from the group as last fetched and my friends and requests as they are now. */
function drawGroupInfo() {
  const g = state.groupDetail;
  if (!g) return;
  const opening = !$("#group-dialog").open;
  const inGroup = new Set(g.members.map((m) => m.id));
  const addable = state.chats.filter((f) => !f.system && !inGroup.has(f.id)).sort((a, b) => chatName(a).localeCompare(chatName(b)));
  const asked = (id) => (state.requests.outgoing.some((r) => r.id === id) ? "out" : state.requests.incoming.some((r) => r.id === id) ? "in" : "");
  const pictureOf = (m) => ((m.id === state.me.id ? state.me : chatById(m.id)) ?? m).avatar_id ?? null;
  const shows = JSON.stringify([g.id, g.name, g.role, g.avatar_id ?? null,
    g.members.map((m) => [m.id, m.role, m.username, personName(m.id, m.username), Boolean(chatById(m.id)), pictureOf(m), asked(m.id)]),
    addable.map((f) => [f.id, chatName(f), f.avatar_id ?? null])]);
  if (!opening && shows === groupInfoShown) return;
  groupInfoShown = shows;
  paintGroupAvatar($("#group-avatar"), g);
  $("#group-title").textContent = g.name;
  $("#group-sub").textContent = `${g.members.length} ${g.members.length === 1 ? "person" : "people"} · you're ${g.role === "owner" ? "the owner" : "a member"}`;
  if (document.activeElement !== $("#rename-input")) $("#rename-input").value = g.name;
  $("#group-members-title").textContent = `Members (${g.members.length})`;
  // Who can remove people: only the owner (the server enforces it). Saying so
  // saves everyone else from looking for a button that isn't there.
  const owner = g.members.find((m) => m.role === "owner");
  $("#group-remove-hint").textContent = g.role === "owner"
    ? "You're the owner, so you can remove people. Everything they sent stays in the chat."
    : `Only ${owner ? personName(owner.id, owner.username) : "the owner"} can remove people. You can add your friends.`;
  // Everyone opens their profile (X46): a friend's in full, anyone else's as
  // far as I may see it (openPerson). The sheet closes first.
  const leaving = () => $("#group-dialog").close();
  $("#group-members").replaceChildren(...g.members.map((m) => {
    const me = m.id === state.me.id;
    const friend = !me && chatById(m.id);
    return personRow(m, {
      suffix: me ? " (you)" : "",
      leaving,
      controls: [
        m.role === "owner" ? el("span", { class: "role-badge", text: "Owner" }) : null,
        !me && !friend ? befriendControl(g, m) : null,
        g.role === "owner" && !me
          ? el("button", { type: "button", class: "button", "aria-label": `Remove ${personName(m.id, m.username)}`,
            onclick: (e) => removeFromGroup(e.currentTarget, g, m) }, "Remove")
          : null,
      ],
    });
  }));
  $("#group-add-section").hidden = addable.length === 0;
  $("#group-add").replaceChildren(...addable.map((f) => personRow(f, {
    leaving,
    controls: [el("button", { type: "button", class: "button primary", "aria-label": `Add ${chatName(f)} to the group`,
      onclick: () => addToGroup(g, f) }, "Add")],
  })));
  const leave = $("#leave-group");
  leave.textContent = "Leave group";
  delete leave.dataset.confirm;
  if (opening) {
    $("#group-note").textContent = "";
    $("#group-dialog").showModal();
  }
}

async function groupAction(fn, done) {
  $("#group-note").textContent = "";
  try {
    await fn();
    if (done) $("#group-note").textContent = done;
  } catch (err) {
    $("#group-note").textContent = err.message;
  }
  if ($("#group-dialog").open && state.groupDetail) openGroupInfo(state.groupDetail.id);
}

const addToGroup = (g, f) => groupAction(
  () => api(`/groups/${g.id}/members`, { method: "POST", json: { user_id: f.id } }), `Added ${chatName(f)}.`);
/**
 * People in a group aren't always each other's friends. Next to anyone who
 * isn't mine yet: Add friend (an ordinary friend request), Requested once I've
 * asked, or Accept if they asked me. The sheet redraws when that changes.
 */
function befriendControl(g, m) {
  const name = personName(m.id, m.username);
  if (state.requests.outgoing.some((r) => r.id === m.id)) {
    return el("span", { class: "person-meta", text: "Requested" });
  }
  if (state.requests.incoming.some((r) => r.id === m.id)) {
    return el("button", { type: "button", class: "button primary", "aria-label": `Accept ${name}'s friend request`,
      onclick: () => groupFriendAction(g, () => api(`/friends/requests/${m.id}/accept`, { method: "POST" }), `You and ${name} are now friends.`) }, "Accept");
  }
  return el("button", { type: "button", class: "button", "aria-label": `Add ${name} as a friend`,
    onclick: () => groupFriendAction(g, async () => {
      const res = await getJSON("/friends/requests", { method: "POST", json: { username: m.username } });
      return res.status === "friends" ? `You and ${name} are now friends.` : `Request sent to ${name}.`;
    }) }, "Add friend");
}

async function groupFriendAction(g, fn, done) {
  try {
    const said = await fn();
    $("#group-note").textContent = typeof said === "string" ? said : done;
  } catch (err) {
    $("#group-note").textContent = err.message;
    return;
  }
  await Promise.all([refreshRequests(), refreshChats()]);
  // Who's in the group didn't change: only my friends and requests did.
  if ($("#group-dialog").open && state.groupDetail?.id === g.id) drawGroupInfo();
}

/** Removing someone takes two taps, like leaving. */
function removeFromGroup(btn, g, m) {
  if (!btn.dataset.confirm) {
    btn.dataset.confirm = "1";
    btn.textContent = "Tap again to remove";
    btn.classList.add("danger");
    return;
  }
  groupAction(() => api(`/groups/${g.id}/members/${m.id}`, { method: "DELETE" }), `Removed ${personName(m.id, m.username)}.`);
}

$("#rename-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const g = state.groupDetail;
  if (!g) return;
  groupAction(() => api(`/groups/${g.id}`, { method: "PATCH", json: { name: $("#rename-input").value } }), "Renamed.");
  $("#rename-input").blur();
});

// Leaving takes two taps, so it can't happen by accident.
$("#leave-group").addEventListener("click", async () => {
  const btn = $("#leave-group");
  const g = state.groupDetail;
  if (!g) return;
  if (!btn.dataset.confirm) {
    btn.dataset.confirm = "1";
    btn.textContent = "Tap again to leave";
    return;
  }
  try {
    $("#group-dialog").close();
    await leaveGroup(g.id);
  } catch (err) {
    $("#group-note").textContent = err.message;
  }
});

/** Leaves a group and drops what this browser had loaded for it. The group
 * and its messages stay on the server for the others (and its history). */
async function leaveGroup(groupId) {
  await api(`/groups/${groupId}/members/${state.me.id}`, { method: "DELETE" });
  report("info", "left group", { group_id: groupId });
  if (state.activeGroupId === groupId) closeChat();
  state.groupMessages.delete(groupId);
  state.groupHistory.delete(groupId);
  state.groupReads.delete(groupId);
  searchCache.delete(`g:${groupId}`);
  await refreshGroups();
}

// A deploy restarts the server, which drops every socket, so a reconnect is
// the moment to notice this tab is running an older build than the server.
async function checkForUpdate() {
  try {
    const { build } = await (await fetch("/api/config", { cache: "no-store" })).json();
    const loaded = state.config?.build;
    $("#update-banner").hidden = !(build && loaded && build !== loaded && loaded !== "dev");
  } catch {
    // Offline; the next reconnect checks again.
  }
}
$("#update-reload").addEventListener("click", () => location.reload());

// ---------- profiles ----------
// Yours: your friends and your own counts. A friend's: what you share.
// Counts and dates only; the server has no message content to show.

const longDate = (ts) => new Date(ts * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });

/** An initial on a tint picked from the id: the fallback for any picture. */
function paintInitial(node, label, id) {
  node.textContent = (Array.from(label || "?")[0] || "?").toUpperCase();
  node.dataset.tint = String(id % 6);
  node.dataset.picture = ""; // a picture still loading for this node is now stale
  node.classList.remove("group");
  return node;
}

// Pictures are fetched with the session (friends-only and members-only) and
// kept as object URLs, keyed by picture id, so each is downloaded once.
const pictureUrls = new Map();

function pictureUrl(key, path) {
  if (!pictureUrls.has(key)) {
    pictureUrls.set(key, api(path)
      .then((r) => r.blob())
      .then((b) => URL.createObjectURL(b))
      .catch((err) => { pictureUrls.delete(key); report("warn", "picture failed to load", { key, ...errorFields(err) }); return null; }));
  }
  return pictureUrls.get(key);
}

function showPicture(node, key, path) {
  node.dataset.picture = key;
  pictureUrl(key, path).then((url) => {
    if (url && node.dataset.picture === key) node.replaceChildren(el("img", { src: url, alt: "" }));
  });
}

/** A person's picture, or their initial. Friends and I are looked up for the newest one. */
function paintAvatar(node, user) {
  const known = user.id === state.me?.id ? state.me : chatById(user.id);
  paintInitial(node, personName(user.id, user.username), user.id);
  const avatarId = known ? known.avatar_id : user.avatar_id;
  if (avatarId) showPicture(node, `u${user.id}:${avatarId}`, `/users/${user.id}/avatar/${avatarId}`);
  return node;
}

// ---------- a picture, bigger (X24) ----------
// A profile or group picture opens large over the page, in its own shape.
// Only when there's a picture to see: an initial stays as it is.
function viewPicture(node) {
  const img = node.querySelector("img");
  if (!img) return;
  const big = $("#picture-big");
  big.classList.toggle("group", node.classList.contains("group"));
  big.replaceChildren(el("img", { src: img.src, alt: "" }));
  $("#picture-viewer").setAttribute("aria-label", node.dataset.label || "Picture");
  $("#picture-viewer").showModal();
}
for (const id of ["#profile-avatar", "#group-avatar"]) {
  const node = $(id);
  node.addEventListener("click", () => viewPicture(node));
  node.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); viewPicture(node); }
  });
  // Tappable (and announced) only while it holds a picture.
  new MutationObserver(() => {
    const has = Boolean(node.querySelector("img"));
    node.classList.toggle("viewable", has);
    node.toggleAttribute("aria-hidden", !has);
    if (has) {
      node.setAttribute("role", "button");
      node.tabIndex = 0;
      node.setAttribute("aria-label", "See the picture bigger");
    } else {
      node.removeAttribute("role");
      node.removeAttribute("tabindex");
      node.removeAttribute("aria-label");
    }
  }).observe(node, { childList: true });
}
// Tapping outside the picture (the backdrop) closes it.
$("#picture-viewer").addEventListener("click", (e) => {
  if (e.target === $("#picture-viewer")) $("#picture-viewer").close();
});

function paintGroupAvatar(node, g) {
  paintInitial(node, g.name, g.id);
  node.classList.add("group");
  if (g.avatar_id) showPicture(node, `g${g.id}:${g.avatar_id}`, `/groups/${g.id}/avatar/${g.avatar_id}`);
  return node;
}

const days = (n) => `${n} ${n === 1 ? "day" : "days"}`;

function stat(label, value) {
  return [el("dt", { text: label }), el("dd", { text: String(value) })];
}

// ---------- people in lists (X45, X46, X47) ----------
// Every list of people (a group's members and the friends to add to it,
// friend requests, the friends on a profile, Blocked) shows each one the same
// way: their picture, or the initial stand-in (pictures go only to friends),
// the name I know them by, and @username under it when that's different,
// since the username is who they are. Picture and name are one button that
// opens their profile.

const personAvatar = (user) => paintAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), user);

/** The name I know someone by (personName), then @username when it differs, and `meta` (when, who). */
function personText(user, { suffix = "", meta = "" } = {}) {
  const name = personName(user.id, user.username);
  const sub = [name !== user.username ? `@${user.username}` : "", meta].filter(Boolean).join(" · ");
  return el("span", { class: "person-text" },
    el("span", { class: "person-name", text: `${name}${suffix}` }),
    sub ? el("span", { class: "person-meta", text: sub }) : null);
}

/** Someone in a list: their picture and name, one button that opens their
 * profile (after `leaving()`, which closes the sheet the list is in), then `controls`. */
function personRow(user, { suffix, meta, controls = [], leaving = null } = {}) {
  return el("li", { class: "person", "data-id": String(user.id) },
    el("button", { type: "button", class: "person-open", onclick: () => { leaving?.(); openPerson(user); } },
      personAvatar(user), personText(user, { suffix, meta })),
    ...controls);
}

/** Anyone's profile (X46): mine or a friend's, as the server has it; anyone
 * else (in a group with me, a request either way, someone I block) as far as
 * I may see them: their username, and adding, reporting, or blocking them. */
function openPerson(user) {
  const chat = chatById(user.id);
  if (chat?.system) return; // Team Napsack has no profile (team.rs)
  if (user.id === state.me.id || chat) openProfile(user.id);
  else openStranger(user);
}

// Bumped by each profile shown, so an answer for one shown before is dropped.
let profileTurn = 0;

/** The profile sheet, emptied for someone new: never the last person's name or picture while this one loads (X23). */
function resetProfile(user) {
  const turn = ++profileTurn;
  for (const id of ["#profile-stats", "#profile-people", "#profile-actions", "#profile-safety"]) $(id).replaceChildren();
  hideProfileEdit();
  profileEdit.profile = null;
  $("#profile-people-section").hidden = true;
  $("#profile-account").hidden = user.id !== state.me?.id;
  disarmSignOut("#profile-sign-out");
  $("#profile-message").hidden = true;
  $("#profile-name").textContent = user.username ? personName(user.id, user.username) : "";
  if (user.username) paintAvatar($("#profile-avatar"), user);
  else paintInitial($("#profile-avatar"), "", user.id);
  $("#profile-sub").textContent = "";
  if (!$("#profile-dialog").open) $("#profile-dialog").showModal();
  return turn;
}

/** Someone who isn't my friend: the server shows me no profile of theirs (only friends see those), so this is what I know. */
function openStranger(user) {
  resetProfile(user);
  // Not a profile to edit, but who Block closes the sheet for.
  profileEdit.profile = { kind: "other", id: user.id, username: user.username };
  const blocked = blockedList.items?.some((b) => b.id === user.id);
  $("#profile-sub").textContent = blocked ? "You block them" : "Not your friend";
  $("#profile-message").textContent = "Only friends see each other's profiles, pictures, and names.";
  $("#profile-message").hidden = false;
  const who = { id: user.id, username: user.username };
  if (!blocked) $("#profile-actions").append(strangerFriendControl(user));
  $("#profile-safety").append(
    el("button", { type: "button", class: "button", onclick: () => reportPerson(who) }, "Report"),
    blocked ? null : el("button", { type: "button", class: "button danger", onclick: () => openBlock(who) }, "Block"));
}

/** Add friend, or Accept if they asked me, or that I've asked already. */
function strangerFriendControl(user) {
  if (state.requests.outgoing.some((r) => r.id === user.id)) {
    return el("span", { class: "person-meta", text: "Friend request sent" });
  }
  const accepting = state.requests.incoming.some((r) => r.id === user.id);
  const btn = el("button", { type: "button", class: "button primary", onclick: async () => {
    btn.disabled = true;
    $("#profile-edit-note").textContent = "";
    let friends = accepting;
    try {
      if (accepting) await api(`/friends/requests/${user.id}/accept`, { method: "POST" });
      else friends = (await getJSON("/friends/requests", { method: "POST", json: { username: user.username } })).status === "friends";
    } catch (err) {
      btn.disabled = false;
      $("#profile-edit-note").textContent = err.message;
      return;
    }
    await Promise.all([refreshRequests(), refreshChats()]);
    if (profileEdit.profile?.id !== user.id) return; // moved on meanwhile
    if (friends && chatById(user.id)) return openProfile(user.id);
    btn.replaceWith(el("span", { class: "person-meta", text: "Friend request sent" }));
    $("#profile-edit-note").textContent = `Request sent to ${user.username}.`;
  } }, accepting ? "Accept friend request" : "Add friend");
  return btn;
}

async function openProfile(userId) {
  const dialog = $("#profile-dialog");
  const msg = $("#profile-message");
  const known = userId === state.me?.id ? state.me : chatById(userId);
  const turn = resetProfile({ id: userId, username: known?.username ?? "" });
  $("#profile-stats").replaceChildren(el("p", { class: "muted", text: "Loading…" }));

  let p;
  try {
    p = await getJSON(`/users/${userId}/profile?tz=${tzOffset()}`);
    if (turn !== profileTurn) return; // another profile is showing now
  } catch (err) {
    if (turn !== profileTurn) return;
    $("#profile-name").textContent = "";
    $("#profile-sub").textContent = "";
    $("#profile-stats").replaceChildren(); // not "Loading…" under the problem
    msg.textContent = err.status === 404 ? "There's no profile to show." : err.message;
    msg.hidden = false;
    return;
  }
  const shown = p.kind === "me" ? p.display_name || p.username : p.nickname || p.display_name || p.username;
  paintAvatar($("#profile-avatar"), p);
  $("#profile-name").textContent = shown;
  renderProfileEdit(p);
  // Usernames are the identity, so they're always shown; and their own name, if I renamed them.
  const id = [`@${p.username}`];
  if (p.past_usernames?.length) id.push(`was ${p.past_usernames.map((n) => `@${n}`).join(", ")}`);
  if (p.kind === "friend" && p.nickname && p.display_name) id.push(`goes by “${p.display_name}”`);

  let people = [];
  if (p.kind === "me") {
    const s = p.stats;
    $("#profile-sub").textContent = [...id, `joined ${longDate(p.joined_at)}`].join(" · ");
    $("#profile-stats").replaceChildren(
      ...stat("Texts sent", s.texts_sent),
      ...stat("Texts received", s.texts_received),
      ...stat("Pics sent", s.pics_sent),
      ...stat("Pics received", s.pics_received),
      ...stat("Your pics opened", s.pics_sent ? `${s.pics_opened} of ${s.pics_sent}` : "—"),
      ...stat("Friends", p.friends.length),
      ...(p.longest_streak ? stat("Longest pic streak", days(p.longest_streak)) : []),
      ...(p.birthday ? stat("Birthday", birthdayText(p.birthday)) : []),
    );
    $("#profile-people-title").textContent = p.friends.length ? "Your friends" : "No friends yet";
    people = p.friends;
  } else {
    const t = p.together;
    $("#profile-sub").textContent = [...id, `friends since ${longDate(p.friends_since)}`].join(" · ");
    $("#profile-stats").replaceChildren(
      ...stat("Texts between you", t.texts),
      ...stat("Pics between you", t.pics),
      ...stat("First message", t.first_message_at ? longDate(t.first_message_at) : "—"),
      ...stat("Joined napsack", longDate(p.joined_at)),
      ...stat("Their friends", p.friend_count),
      ...(p.streak?.current >= STREAK_SHOWN
        ? stat("Pic streak", `🔥 ${days(p.streak.current)}${p.streak.expiring ? ", ends tonight ⌛" : ""}`) : []),
      ...(p.streak?.longest ? stat("Longest pic streak", days(p.streak.longest)) : []),
      ...(p.birthday ? stat("Birthday", birthdayText(p.birthday)) : []),
    );
    $("#profile-people-title").textContent = "Friends you share";
    people = p.mutual_friends;
    $("#profile-actions").append(el("button", {
      type: "button", class: "button primary",
      onclick: () => { dialog.close(); openChat(p.id); },
    }, `Message ${shown}`));
    const who = { id: p.id, username: p.username };
    $("#profile-safety").append(
      el("button", { type: "button", class: "button", onclick: () => reportPerson(who) }, "Report"),
      el("button", { type: "button", class: "button danger", onclick: () => openBlock(who) }, "Block"));
  }

  $("#profile-people-section").hidden = people.length === 0 && p.kind !== "me";
  $("#profile-people").replaceChildren(...people.map((f) => personRow(f, { meta: `since ${longDate(f.since)}` })));
}

// Your profile: your display name and picture. A friend's: your private nickname for them.
const profileEdit = { profile: null };

function renderProfileEdit(p) {
  profileEdit.profile = p;
  const mine = p.kind === "me";
  const input = $("#profile-name-input");
  $("#profile-name-form").hidden = false;
  $("#profile-name-label").textContent = mine ? "Your name" : "Nickname";
  input.placeholder = mine ? p.username : p.display_name || p.username;
  input.value = (mine ? p.display_name : p.nickname) ?? "";
  $("#profile-name-hint").textContent = mine
    ? "What your friends see. Your username stays the same."
    : `Only you see this. Leave it empty to use ${p.display_name ? "their name" : "their username"}.`;
  $("#profile-name-hint").hidden = false;
  $("#profile-picture-row").hidden = !mine;
  $("#profile-security").hidden = !mine;
  $("#security-note").textContent = "";
  $("#passkey-note").textContent = "";
  $("#blocked-note").textContent = "";
  if (mine) renderSecurity();
  if (mine) renderUsername(p);
  $("#profile-picture-clear").hidden = !p.avatar_id;
  $("#profile-birthday-form").hidden = !mine;
  if (mine) {
    $("#birthday-month").value = p.birthday ? String(p.birthday.month) : "";
    $("#birthday-day").value = p.birthday ? String(p.birthday.day) : "";
    $("#birthday-year").value = p.birthday?.year ? String(p.birthday.year) : "";
    $("#birthday-clear").hidden = !p.birthday;
  }
  $("#profile-edit-note").textContent = "";
}

function hideProfileEdit() {
  for (const id of ["#profile-name-form", "#profile-name-hint", "#profile-picture-row", "#profile-security", "#profile-birthday-form"]) $(id).hidden = true;
  $("#profile-edit-note").textContent = "";
}

async function profileAction(fn, done) {
  const p = profileEdit.profile;
  if (!p) return;
  try {
    await fn(p);
  } catch (err) {
    $("#profile-edit-note").textContent = err.message;
    return;
  }
  // The socket refreshes everything else; reopen to show what changed.
  if (p.kind === "me") await refreshMe();
  else await refreshChats();
  await openProfile(p.id);
  $("#profile-edit-note").textContent = done;
}

$("#profile-name-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const name = $("#profile-name-input").value;
  $("#profile-name-input").blur();
  profileAction((p) => p.kind === "me"
    ? api("/me/name", { method: "PUT", json: { name } })
    : api(`/friends/${p.id}/nickname`, { method: "PUT", json: { name } }), name.trim() ? "Saved." : "Cleared.");
});

$("#profile-picture-input").addEventListener("change", (e) => {
  const file = e.target.files?.[0];
  e.target.value = "";
  if (!file) return;
  profileAction(async () => {
    const blob = await squarePictureBlob(file);
    await api("/me/avatar", { method: "POST", body: blob, headers: { "Content-Type": "image/jpeg" } });
  }, "Picture updated.");
});

// ---------- birthday (F19) ----------
// Month and day, the year optional; friends see it, with a 🎂 on the day.

const MONTHS = Array.from({ length: 12 }, (_, i) => new Date(2000, i, 1).toLocaleDateString(undefined, { month: "long" }));
$("#birthday-month").append(...MONTHS.map((m, i) => el("option", { value: String(i + 1), text: m })));
$("#birthday-day").append(...Array.from({ length: 31 }, (_, i) => el("option", { value: String(i + 1), text: String(i + 1) })));

/** "March 9" or "March 9, 1994". */
function birthdayText(b) {
  return b.year ? `${MONTHS[b.month - 1]} ${b.day}, ${b.year}` : `${MONTHS[b.month - 1]} ${b.day}`;
}

/** Minutes east of UTC: streaks and birthdays count days in my own time zone. */
const tzOffset = () => -new Date().getTimezoneOffset();

// ---------- streaks (F15) ----------
// Days in a row we've both sent each other a pic, worked out by the server
// (streaks.rs). Shown from 3 days: 🔥 and the count, and ⌛ when it runs out
// tonight unless we both send one today.
const STREAK_SHOWN = 3;

function streakText(count, expiring) {
  return count >= STREAK_SHOWN ? ` 🔥${count}${expiring ? "⌛" : ""}` : "";
}

/** A friend's name in the list, with a 🔥 streak and a 🎂 on their birthday. */
function chatRowName(chat) {
  return `${chatName(chat)}${streakText(chat.streak ?? 0, chat.streak_expiring)}${chat.birthday === todayMD() ? " 🎂" : ""}`;
}

/** Today in my own time zone, as the chat list's "MM-DD". */
function todayMD() {
  const d = new Date();
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

$("#profile-birthday-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const month = Number($("#birthday-month").value) || null;
  const day = Number($("#birthday-day").value) || null;
  const yearText = $("#birthday-year").value.trim();
  if (!month || !day) {
    $("#profile-edit-note").textContent = "Pick a month and a day.";
    return;
  }
  if (yearText && !/^\d{4}$/.test(yearText)) {
    $("#profile-edit-note").textContent = "The year is four digits, or leave it empty.";
    return;
  }
  profileAction(() => api("/me/birthday", { method: "PUT", json: { month, day, year: yearText ? Number(yearText) : null } }),
    "Birthday saved.");
});

$("#birthday-clear").addEventListener("click", () =>
  profileAction(() => api("/me/birthday", { method: "PUT", json: {} }), "Birthday removed."));

$("#profile-picture-clear").addEventListener("click", () =>
  profileAction(() => api("/me/avatar", { method: "DELETE" }), "Picture removed."));

$("#my-profile").addEventListener("click", () => openProfile(state.me.id));
$("#chat-title").addEventListener("click", () => {
  // Team Napsack has no profile (team.rs).
  if (state.activeId && !chatById(state.activeId)?.system) openProfile(state.activeId);
  else if (state.activeGroupId) openGroupInfo(state.activeGroupId);
});

// ---------- report and block (F28; reports.rs, blocks.rs) ----------
// docs/design/report-and-block.md. A report carries ids only (whose message,
// which one, in which group), never what it said, decrypted or not: Admins
// see who sent it and when. Blocking ends the friendship and stops them
// reaching you; they aren't told. Group messages from someone you block stay.

const REPORT_REASONS = [
  ["spam", "Spam"], ["harassment", "Harassment or bullying"], ["nudity", "Nudity or sexual content"],
  ["violence", "Violence or threats"], ["hate", "Hate"], ["other", "Something else"],
];
$("#report-reasons").append(...REPORT_REASONS.map(([value, label]) =>
  el("label", { class: "check report-reason" }, el("input", { type: "radio", name: "reason", value }), label)));

/** Someone else's stored message, not Team Napsack's and not a group event: what Report is for. */
function canReport(m) {
  return m.id != null && m.sender_id !== state.me.id && !chatById(m.sender_id)?.system && m.kind !== "event";
}

let reportTarget = null; // { body: what the server is sent (ids only), who: { id, username }, noun }

function reportMessage(m) {
  state.actionFor = null;
  renderMessages();
  const media = m.group_id ? Boolean(m.pic) : m.kind === "snap";
  openReport({
    body: m.group_id ? { kind: "group_message", group_id: m.group_id, message_id: m.id } : { kind: "message", message_id: m.id },
    who: { id: m.sender_id, username: chatById(m.sender_id)?.username ?? m.sender_name ?? "" },
    noun: media ? mediaWord(m) : "text",
  });
}

function reportPerson(who) {
  openReport({ body: { kind: "person", user_id: who.id }, who, noun: null });
}

function openReport(target) {
  reportTarget = target;
  const { who, noun } = target;
  $("#report-title").textContent = noun ? `Report this ${noun}` : `Report @${who.username}`;
  $("#report-text").textContent = noun
    ? "An Admin will look at it. They'll see who sent it and when, but never what it said."
    : "An Admin will look at it. They'll see who you reported, but never what either of you said.";
  $("#report-reasons legend").textContent = noun ? "Why are you reporting it?" : "Why are you reporting them?";
  $("#report-form").reset();
  $("#report-form").hidden = false;
  $("#report-done").hidden = true;
  $("#report-error").textContent = "";
  $("#report-submit").disabled = false;
  $("#report-dialog").showModal();
}

$("#report-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const t = reportTarget;
  if (!t) return;
  const reason = $("#report-form").elements.reason.value;
  if (!reason) {
    $("#report-error").textContent = t.noun ? "Choose why you're reporting it." : "Choose why you're reporting them.";
    return;
  }
  const note = $("#report-note").value.trim();
  $("#report-error").textContent = "";
  $("#report-submit").disabled = true;
  let res;
  try {
    res = await getJSON("/reports", { method: "POST", json: { ...t.body, reason, ...(note ? { note } : {}) } });
  } catch (err) {
    report("warn", "report failed", { ...t.body, ...errorFields(err) }); // ids only: never the note
    $("#report-error").textContent = err.message;
    $("#report-submit").disabled = false;
    return;
  }
  if (reportTarget !== t) return;
  $("#report-form").hidden = true;
  $("#report-done").hidden = false;
  $("#report-done-text").textContent = res.already
    ? `You've reported this already. An Admin will look at it. Would you like to block @${t.who.username} too?`
    : `Report sent. Thank you for telling us. Would you like to block @${t.who.username} too?`;
  $("#report-block").textContent = `Block @${t.who.username}`;
});

$("#report-block").addEventListener("click", () => {
  const who = reportTarget?.who;
  $("#report-dialog").close();
  if (who) openBlock(who);
});

let blockTarget = null; // { id, username }

function openBlock(who) {
  blockTarget = who;
  $("#block-title").textContent = `Block @${who.username}?`;
  $("#block-error").textContent = "";
  $("#block-confirm").disabled = false;
  $("#block-dialog").showModal();
}

$("#block-confirm").addEventListener("click", async () => {
  const who = blockTarget;
  if (!who) return;
  $("#block-error").textContent = "";
  $("#block-confirm").disabled = true;
  let res;
  try {
    res = await getJSON(`/blocks/${who.id}`, { method: "POST" });
  } catch (err) {
    report("warn", "blocking failed", { user_id: who.id, ...errorFields(err) });
    $("#block-error").textContent = err.message;
    $("#block-confirm").disabled = false;
    return;
  }
  if (blockTarget !== who) return;
  $("#block-dialog").close();
  // Their profile and chat close; the socket's friends_changed takes their row
  // out of the list on every device, and this does at once.
  if ($("#profile-dialog").open && profileEdit.profile?.id === who.id) $("#profile-dialog").close();
  if (state.activeId === who.id) closeChat();
  forgetChat(who.id);
  showToast(res.already ? `You'd already blocked @${res.user.username}.` : `Blocked @${res.user.username}.`);
  refreshChats();
  refreshRequests();
});

// Profile › Blocked: who you block, newest first, each with Unblock.
const blockedList = { items: null, loads: 0 };
const BLOCKS_UNLOADED = "Couldn't load who you've blocked. Check your connection and open this again.";

async function loadBlocks() {
  const asked = ++blockedList.loads;
  let res;
  try {
    res = await getJSON("/blocks");
  } catch (err) {
    report("warn", "loading blocks failed", errorFields(err));
    if (asked === blockedList.loads && !blockedList.items) $("#blocked-note").textContent = BLOCKS_UNLOADED;
    return;
  }
  if (asked !== blockedList.loads) return; // a newer answer is on its way
  if ($("#blocked-note").textContent === BLOCKS_UNLOADED) $("#blocked-note").textContent = "";
  blockedList.items = res.blocks;
  renderBlocks();
}

function renderBlocks() {
  const list = $("#blocked-list");
  const items = blockedList.items;
  if (!items) {
    list.replaceChildren(); // nothing claimed before the server answers
    return;
  }
  if (!items.length) {
    list.replaceChildren(el("li", { class: "blocked-none", text: "You haven't blocked anyone." }));
    return;
  }
  // Merged into what's shown, so a "Tap again" already showing stays.
  const shown = new Map([...list.querySelectorAll("li[data-id]")].map((li) => [li.dataset.id, li]));
  list.replaceChildren(...items.map((b) => shown.get(String(b.id)) ?? blockedRow(b)));
}

function blockedRow(b) {
  const unblockButton = el("button", { type: "button", class: "button", onclick: () => unblock(unblockButton, b) }, "Unblock");
  return personRow(b, { meta: `Blocked ${dayName(b.blocked_at)}`, controls: [unblockButton] });
}

/** Two taps: the first says what unblocking does (and doesn't). */
async function unblock(btn, b) {
  if (!btn.dataset.confirm) {
    btn.dataset.confirm = "1";
    btn.textContent = "Tap again to unblock";
    $("#blocked-note").textContent = `Unblocking @${b.username} lets them reach you again. You stay unfriended: either of you can send a friend request.`;
    return;
  }
  btn.disabled = true;
  try {
    await api(`/blocks/${b.id}/remove`, { method: "POST" });
  } catch (err) {
    report("warn", "unblocking failed", { user_id: b.id, ...errorFields(err) });
    $("#blocked-note").textContent = err.message;
    btn.disabled = false;
    loadBlocks(); // it may be gone already
    return;
  }
  blockedList.items = blockedList.items?.filter((x) => x.id !== b.id) ?? null;
  renderBlocks();
  $("#blocked-note").textContent = `Unblocked @${b.username}. You're not friends: send a friend request if you'd like to be.`;
  loadBlocks();
}

// ---------- links in texts ----------
// Texts are shown as text, never as HTML. The one exception: a link to this
// site that opens one of its own chats or groups (Team Napsack's warnings
// link to the message they're about) becomes an in-app link. No other link
// is ever made clickable.
const IN_APP_ROUTE = /^#(chat|group)=(\d+)(?:&message=(\d+))?$/;

/** The site's own addresses: this page's, and the one the server names (`site_url`). */
function ownOrigins() {
  const out = new Set([location.origin]);
  try { if (state.config?.site_url) out.add(new URL(state.config.site_url).origin); } catch {}
  return out;
}

/** `#group=3&message=9` if `word` is a link to this site's chat or group, else null. */
function inAppRoute(word) {
  let url;
  try { url = new URL(word); } catch { return null; }
  if (!ownOrigins().has(url.origin) || url.pathname !== "/" || url.search || url.username || url.password) return null;
  return IN_APP_ROUTE.test(url.hash) ? url.hash : null;
}

/** A text as nodes: its words as text, with links to this site's chats and groups made in-app links. */
function textNodes(text) {
  const parts = [];
  let last = 0;
  for (const match of text.matchAll(/https?:\/\/[^\s<>"']+/g)) {
    const word = match[0].replace(/[.,!?;:)\]]+$/, ""); // the sentence's end isn't the link's
    const route = inAppRoute(word);
    if (!route) continue;
    if (match.index > last) parts.push(text.slice(last, match.index));
    parts.push(el("a", { class: "in-app-link", href: route, onclick: (e) => { e.preventDefault(); openFromLink(route); } }, word));
    last = match.index + word.length;
  }
  if (last < text.length) parts.push(text.slice(last));
  return parts;
}

// ---------- friends ----------

function refreshRequests() {
  return reload(loads.requests, loadRequests);
}

async function loadRequests() {
  try {
    state.requests = await getJSON("/friends/requests");
  } catch (err) {
    report("warn", "loading friend requests failed", errorFields(err));
    return;
  }
  if (!state.me) return;
  renderRequests();
}

function renderRequests() {
  const { incoming, outgoing } = state.requests;
  const badge = $("#request-badge");
  badge.hidden = incoming.length === 0;
  badge.textContent = incoming.length;

  $("#incoming-section").hidden = incoming.length === 0;
  // Tapping who it is opens what I may see of them (X46); this sheet closes first.
  const leaving = () => $("#friends-dialog").close();
  $("#incoming-list").replaceChildren(...incoming.map((r) => personRow(r, { leaving, controls: [
    el("button", { type: "button", class: "button primary", onclick: () => requestAction(r.id, "accept") }, "Accept"),
    el("button", { type: "button", class: "button", onclick: () => requestAction(r.id, "decline") }, "Decline"),
  ] })));

  $("#outgoing-section").hidden = outgoing.length === 0;
  $("#outgoing-list").replaceChildren(...outgoing.map((r) => personRow(r, { leaving, controls: [
    el("button", { type: "button", class: "button", onclick: () => requestAction(r.id, "cancel") }, "Cancel request"),
  ] })));
}

async function requestAction(userId, action) {
  try {
    if (action === "accept") await api(`/friends/requests/${userId}/accept`, { method: "POST" });
    else await api(`/friends/requests/${userId}`, { method: "DELETE" });
  } catch (err) {
    $("#add-friend-note").textContent = err.message;
  }
  refreshRequests();
  refreshChats();
}

function openFriends() {
  $("#add-friend-note").textContent = "";
  $("#friends-dialog").showModal();
  refreshRequests();
  loadMyLink();
}

// ---------- my personal link and code (X25) ----------
// One "add me" link per person (invites.rs), shown as a QR to people in
// person: someone with an account adds you with it, someone new signs up
// with it, and it never changes (X39).

function showMyLink(path) {
  const url = `${location.origin}${path}`;
  $("#my-link").textContent = url;
  $("#my-qr").replaceChildren(qrSvg(url, "Your add-me QR code"));
  $("#my-link-share").hidden = !navigator.share;
  $("#my-link-copy").textContent = "Copy link";
}

async function loadMyLink() {
  if (!$("#my-link").textContent) $("#my-qr").replaceChildren(el("p", { class: "muted", text: "Making your code…" }));
  try {
    showMyLink((await getJSON("/friend-link")).path);
  } catch (err) {
    $("#my-qr").replaceChildren(el("p", { class: "form-note", text: `Couldn't load your code. ${err.message}` }));
    report("warn", "loading my link failed", errorFields(err));
  }
}

$("#my-link-copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("#my-link").textContent);
    $("#my-link-copy").textContent = "Copied";
  } catch {
    $("#my-link-copy").textContent = "Select it and copy";
  }
});
$("#my-link-share").addEventListener("click", () => {
  navigator.share({ title: "napsack", text: "Add me on napsack", url: $("#my-link").textContent }).catch(() => {});
});
// ---------- invite links ----------
// A link (/i/<token>) signs a new person up and makes them friends with
// whoever made it, or adds someone who already has an account (invites.rs).

/** An invite link in the address bar: remember it, and tidy the address. */
async function readInviteLink() {
  const m = /^\/i\/([A-Za-z0-9_-]{22})$/.exec(location.pathname);
  if (!m) return;
  history.replaceState(null, "", "/");
  state.invite = { token: m[1], inviter: null, problem: null };
  try {
    state.invite.inviter = (await getJSON(`/invites/lookup/${m[1]}`)).inviter;
  } catch (err) {
    state.invite.problem = err.message;
  }
}

/** Signed out: the sign-up form, saying who invited you. */
function showInviteBanner() {
  const banner = $("#invite-banner");
  const inv = state.invite;
  banner.hidden = !inv;
  if (!inv) return;
  banner.classList.toggle("problem", !inv.inviter);
  banner.textContent = inv.inviter
    ? `${inv.inviter.username} invited you to napsack. Pick a username and password, and you'll be friends.`
    : inv.problem;
  if (inv.inviter) setAuthMode("register");
}

/** Signed in: "Add Ana?" */
function offerInvite() {
  const inv = state.invite;
  if (!inv) return;
  state.invite = null;
  if (!inv.inviter) {
    alert(inv.problem);
    return;
  }
  if (inv.inviter.id === state.me.id) {
    alert("That's your own invite link. Send it to a friend.");
    return;
  }
  if (chatById(inv.inviter.id)) {
    openChat(inv.inviter.id);
    return;
  }
  $("#invite-text").textContent = `This is ${inv.inviter.username}'s napsack link. Add them as a friend?`;
  $("#invite-error").textContent = "";
  $("#invite-dialog").dataset.token = inv.token;
  $("#invite-dialog").showModal();
}

$("#invite-accept").addEventListener("click", async () => {
  try {
    const res = await getJSON("/invites/accept", { method: "POST", json: { token: $("#invite-dialog").dataset.token } });
    $("#invite-dialog").close();
    report("info", "friends through an invite");
    await refreshChats();
    openChat(res.friend.id);
  } catch (err) {
    $("#invite-error").textContent = err.message;
  }
});

$("#friends-button").addEventListener("click", openFriends);
$("#empty-add").addEventListener("click", openFriends);

// ---------- friend map (docs/implementation/friend-graph.md) ----------
// You in the middle, your friends around you, lines between friends who know
// each other, and a ? for each person a friend knows that you don't. The
// server decides what's on it (graph.rs); the groups and layout come from
// /graph.js and the drawing from /graph-view.js.
let friendMap = null;
// Whether to add your group chats (off by default: then it's just friends).
const MAP_CHATS_KEY = "napsack.mapChats";
function mapChats() {
  try { return localStorage.getItem(MAP_CHATS_KEY) === "1"; } catch { return false; }
}

async function openFriendMap() {
  $("#friends-dialog").close();
  $("#graph-dialog").showModal();
  $("#graph-chats").checked = mapChats();
  await loadFriendMap();
}

async function loadFriendMap() {
  $("#graph-host").replaceChildren(el("p", { class: "muted", text: "Drawing your map…" }));
  try {
    friendMap = await getJSON($("#graph-chats").checked ? "/graph?chats=1" : "/graph");
    drawFriendMap();
  } catch (err) {
    friendMap = null;
    $("#graph-host").replaceChildren(el("p", { class: "form-note", text: `Couldn't load your map. ${err.message}` }));
    report("warn", "friend map failed", errorFields(err));
  }
}

function drawFriendMap() {
  const g = friendMap;
  if (!g || !$("#graph-dialog").open) return;
  const friends = g.nodes.filter((n) => n.kind === "friend").length;
  if (!friends) {
    $("#graph-host").replaceChildren(el("p", { class: "muted", text: "No friends yet, so no map. Add someone by their username, or send an invite link." }));
    return;
  }
  const unknown = g.nodes.filter((n) => n.kind === "unknown").length;
  const name = (n) => (n.kind === "self" ? "You" : n.kind === "friend" ? personName(n.user_id, "") : "");
  const { groups } = drawGraph($("#graph-host"), g, {
    center: `u${state.me.id}`,
    label: name,
    title: `Your friend map: ${friends} ${friends === 1 ? "friend" : "friends"}${unknown ? ` and ${unknown} people they know that you don't` : ""}.`,
    unknownNote: (count) => `${count} ${count === 1 ? "person" : "people"} your friends know that you don't`,
    describe: (n, { neighbors, group }) => {
      if (isChat(n)) {
        const who = [...neighbors].sort((a, b) => (b.kind === "self") - (a.kind === "self")).map(name).filter(Boolean);
        return [
          el("b", { text: mapChatName(n) }),
          ` · group chat · ${chatSummary(n)}: ${who.join(", ")}${n.others ? ` and ${n.others} ${n.others === 1 ? "person" : "people"} you aren't friends with` : ""}. `,
          n.group_id ? el("button", { type: "button", class: "link", onclick: () => { $("#graph-dialog").close(); openGroup(n.group_id); } }, "Open chat") : null,
        ];
      }
      const known = neighbors.filter((m) => m.kind === "friend");
      const strangers = neighbors.filter((m) => m.kind === "unknown").length;
      if (n.kind === "self") {
        const count = groups.groups.length;
        return `You · ${friends} ${friends === 1 ? "friend" : "friends"}${count ? `, in ${count} ${count === 1 ? "group" : "groups"}` : ""}.`;
      }
      if (n.kind === "unknown") {
        const by = known.map(name);
        return `Someone you don't know yet: a friend of ${by.length > 1 ? `${by.slice(0, -1).join(", ")} and ${by.at(-1)}` : by[0]}.`;
      }
      const parts = [
        known.length ? `knows ${known.length} of your friends` : "doesn't know your other friends",
        strangers ? `and ${strangers} ${strangers === 1 ? "person" : "people"} you don't` : null,
      ].filter(Boolean).join(" ");
      return [
        el("b", { text: name(n) }),
        `${group >= 0 ? ` · Group ${groupLetter(group)}` : ""} · ${parts}. `,
        el("button", { type: "button", class: "link", onclick: () => { $("#graph-dialog").close(); openChat(n.user_id); } }, "Message"),
      ];
    },
  });
}

$("#graph-open").addEventListener("click", openFriendMap);
$("#graph-chats").addEventListener("change", (e) => {
  try { localStorage.setItem(MAP_CHATS_KEY, e.target.checked ? "1" : "0"); } catch { /* just this time, then */ }
  loadFriendMap();
});
let graphResize = null;
window.addEventListener("resize", () => {
  clearTimeout(graphResize);
  graphResize = setTimeout(() => { if (widthChanged($("#graph-host"))) drawFriendMap(); }, 200);
});

$("#add-friend-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.currentTarget;
  const note = $("#add-friend-note");
  const username = form.username.value.trim();
  if (!username) return;
  try {
    const res = await getJSON("/friends/requests", { method: "POST", json: { username } });
    // An old username still finds them (X30): say what they're called now.
    const was = res.user.username.toLowerCase() !== username.toLowerCase() ? ` (was @${username})` : "";
    note.textContent = res.status === "friends"
      ? `You and ${res.user.username}${was} are now friends.`
      : `Request sent to ${res.user.username}${was}.`;
    form.reset();
  } catch (err) {
    note.textContent = err.message;
  }
  refreshRequests();
  refreshChats();
});

for (const btn of document.querySelectorAll("[data-close]")) {
  btn.addEventListener("click", () => btn.closest("dialog").close());
}

// ---------- camera ----------

const camera = {
  stream: null,
  attempt: 0,                  // bumped whenever the camera stops, so late answers are ignored
  problem: null,               // why the camera couldn't start, if it couldn't
  facing: "user",
  mirror: true,                // selfie view: preview and photo both flipped, like a mirror
  blob: null,
  previewUrl: null,
  to: [],                      // who it's going to: the open chat, or picked in Send to… (X26)
  picked: false,               // `to` came from Send to…
  sends: new Map(),            // per recipient: the pic's id (friends) or sealed copy (groups), kept for retries
  sent: new Set(),             // recipients that have it, so Send again skips them
  videoType: null,             // set when `blob` is a recorded video (X28)
  captionY: null,              // where the caption was put, 0 (top) to 1, once placed (X33)
  captionShownY: null,         // where it shows, kept inside the picture (stripOnPicture): what's sent
  audio: null,                 // the microphone, once asked for, while the camera is open
  zoom: 1,                     // 1 = no zoom (X27)
  hwZoom: null,                // the camera's own zoom range, where the browser offers one
  torchable: false,            // the camera in use has a light the browser can turn on (X50)
  torch: false,                // the flash button is on: off each time the camera opens
};

function cameraMessage(text) {
  const p = $("#camera-message");
  p.textContent = text || "";
  p.hidden = !text;
}

async function startStream() {
  stopStream();
  cameraMessage("");
  camera.problem = null;
  if (!navigator.mediaDevices?.getUserMedia) {
    cameraProblem("This browser can't open the camera here. Choose a photo instead.");
    return;
  }
  // The camera can take a while to answer. By then a photo may have been
  // picked, the camera closed, or switched: then this answer is out of date.
  const attempt = camera.attempt;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: camera.facing, width: { ideal: 1920 }, height: { ideal: 1080 } },
      audio: false,
    });
    if (attempt !== camera.attempt) {
      stream.getTracks().forEach((t) => t.stop());
      return;
    }
    camera.stream = stream;
    // Mirror whatever the browser says is a front camera, so the
    // photo matches the preview. Laptop webcams report no facing; treat them as front.
    const facing = camera.stream.getVideoTracks()[0]?.getSettings?.().facingMode;
    camera.mirror = (facing || camera.facing) !== "environment";
    const video = $("#camera-video");
    video.classList.toggle("mirrored", camera.mirror);
    video.srcObject = camera.stream;
    const range = camera.stream.getVideoTracks()[0]?.getCapabilities?.().zoom;
    camera.hwZoom = range && range.max > Math.max(1, range.min) ? range : null;
    camera.torchable = Boolean(camera.stream.getVideoTracks()[0]?.getCapabilities?.().torch);
    setZoom(1);
    $("#zoom-chip").hidden = !$("#camera-preview").hidden;
    renderTorch();
  } catch (err) {
    if (attempt !== camera.attempt) return;
    cameraProblem(err?.name === "NotFoundError" || err?.name === "OverconstrainedError"
      ? "No camera found. Choose a photo instead."
      : "Camera access is blocked. Allow it in your browser settings, or choose a photo instead.");
  }
}

/** The camera won't start. Said over the camera view, never over a photo being previewed (Retake shows it). */
function cameraProblem(text) {
  camera.problem = text;
  if ($("#camera-preview").hidden) cameraMessage(text);
}

function stopStream() {
  camera.attempt = (camera.attempt ?? 0) + 1; // any answer still on its way is out of date
  if (rec.recorder) {
    rec.discard = true; // closed while recording: nothing to show
    stopRecording();
  }
  camera.stream?.getTracks().forEach((t) => t.stop());
  camera.stream = null;
  camera.audio?.getTracks().forEach((t) => t.stop());
  camera.audio = null;
  $("#camera-video").srcObject = null;
  camera.hwZoom = null;
  camera.torchable = false; // a stopped camera's light is off
  setZoom(1);
  $("#zoom-chip").hidden = true;
  renderTorch();
}

// ---------- zoom (X27) ----------
// Pinch the camera view, or tap the 1× button for the next step. The camera's
// own zoom where the browser offers it (sharper, and it's what phones' back
// cameras do); otherwise the middle of the frame, enlarged in the preview and
// cropped when the photo is taken.
const CROP_ZOOM_MAX = 3; // past this, a cropped photo gets too small to look good
const zoomMax = () => (camera.hwZoom ? Math.min(camera.hwZoom.max, 10) : CROP_ZOOM_MAX);
const zoomText = (z) => `${z < 10 ? Math.round(z * 10) / 10 : Math.round(z)}×`;
let cameraApplying = null; // the camera takes a moment per change: send only the newest

/** What the camera itself is asked for: its own zoom and its light (X50), where it has them. */
function cameraWanted() {
  const want = {};
  if (camera.hwZoom) want.zoom = camera.zoom;
  if (camera.torchable) want.torch = torchLit();
  return want;
}

/** Asks the camera for cameraWanted(), one change at a time. Each change
 * replaces the one before, so the zoom and the light always go together. */
function applyToCamera() {
  const track = camera.stream?.getVideoTracks()[0];
  if (!track || cameraApplying || !(camera.hwZoom || camera.torchable)) return;
  cameraApplying = (async () => {
    let sent = null;
    while (camera.stream?.getVideoTracks()[0] === track) {
      const want = cameraWanted();
      if (JSON.stringify(want) === sent) break;
      sent = JSON.stringify(want);
      try {
        await track.applyConstraints({ advanced: [want] });
      } catch (err) {
        report("debug", "camera settings failed", { ...errorFields(err), zoom: want.zoom, torch: want.torch });
        break;
      }
    }
    cameraApplying = null;
    // Switched cameras meanwhile (while recording): the new one is asked too.
    const now = camera.stream?.getVideoTracks()[0];
    if (now && now !== track) applyToCamera();
  })();
}

function setZoom(z) {
  camera.zoom = Math.min(zoomMax(), Math.max(1, z));
  const chip = $("#zoom-chip");
  chip.textContent = zoomText(camera.zoom);
  chip.setAttribute("aria-label", `Zoom: ${zoomText(camera.zoom)}`);
  const video = $("#camera-video");
  if (camera.hwZoom) {
    video.style.transform = "";
    applyToCamera();
  } else {
    // In the preview: enlarged about the middle (a mirrored view stays mirrored).
    video.style.transform = camera.zoom === 1 ? "" : `${camera.mirror ? "scaleX(-1) " : ""}scale(${camera.zoom})`;
  }
}

/** The steps the button goes through: 1×, 2×, then the most there is (up to 5×). */
function nextZoomStep() {
  const steps = [...new Set([1, 2, Math.min(5, zoomMax())])].filter((s) => s <= zoomMax()).sort((a, b) => a - b);
  return steps.find((s) => s > camera.zoom + 0.05) ?? 1;
}

$("#zoom-chip").addEventListener("click", () => setZoom(nextZoomStep()));

const pinch = { start: 0, zoom: 1 };
const touchGap = (t) => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
$(".camera-stage").addEventListener("touchstart", (e) => {
  if (e.touches.length !== 2 || !camera.stream || $("#camera-video").hidden) return;
  pinch.start = touchGap(e.touches);
  pinch.zoom = camera.zoom;
}, { passive: true });
$(".camera-stage").addEventListener("touchmove", (e) => {
  if (e.touches.length !== 2 || !pinch.start || $("#camera-video").hidden) return;
  e.preventDefault(); // the camera zooms, not the page
  setZoom(pinch.zoom * (touchGap(e.touches) / pinch.start));
}, { passive: false });
$(".camera-stage").addEventListener("touchend", (e) => {
  if (e.touches.length < 2) pinch.start = 0;
});

// ---------- flash (X50) ----------
// The camera's own light, where the browser can turn it on (`torch`: Chrome
// on Android, for a back camera); everywhere else, no button. Off when the
// camera opens. On, it stays lit while the camera is taking pics, for a
// photo and all through a video, and goes off while looking at what was
// taken, on switching to a camera without one, and with the camera.
const torchLit = () => camera.torch && camera.torchable && !$("#capture-controls").hidden;

function renderTorch() {
  const btn = $("#torch");
  btn.hidden = !camera.torchable || $("#capture-controls").hidden;
  btn.setAttribute("aria-pressed", camera.torch ? "true" : "false");
  btn.setAttribute("aria-label", camera.torch ? "Flash on. Tap to turn it off" : "Flash off. Tap to turn it on");
  btn.classList.toggle("on", camera.torch);
  applyToCamera();
}

$("#torch").addEventListener("click", () => {
  camera.torch = !camera.torch;
  renderTorch();
});

// ---------- short videos (X28) ----------
// Press and hold the shutter to record, up to the server's limit (10 seconds
// by default); slide the finger up to zoom in. Frames go through a canvas, so
// the zoom's crop and a front camera's mirroring come out as the preview
// shows them, and the size stays small. The microphone is asked for the first
// time, then kept while the camera is open, so it isn't asked again per video.
const HOLD_MS = 350;
const ZOOM_SLIDE_PX = 110; // was 60, which zoomed too fast (Nate, 2026-10-29)
const VIDEO_EDGE = 1280;
const rec = { timer: null, held: false, pointerId: null, startY: 0, startZoom: 1, suppressClick: false,
  recorder: null, chunks: [], started: 0, stopDrawing: () => {}, tick: 0, discard: false, stopTimer: null, timedOut: false };

// Safari, and every browser on an iPhone (all WebKit): one recorder at a time.
// With a second one recording the silent copy alongside (X37, 0.41.0), the
// installed iPhone app's videos came out black and the ring stuck (Nate,
// 2026-10-29). There, a video has no "send without sound".
const ONE_RECORDER = /iPhone|iPad|iPod/.test(navigator.userAgent)
  || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1)
  || (/Safari\//.test(navigator.userAgent) && !/Chrome\/|Chromium\/|Edg\//.test(navigator.userAgent));
// A recorder that never says it stopped mustn't leave the camera stuck: after
// this long, the video finishes with what was recorded.
const STOP_WAIT_MS = 3000;

// MP4 where the browser can make it (Safari, newer Chrome): it plays
// everywhere. H.264 High first, then Main, then Baseline: the higher profiles
// look better at the same size and play wherever MP4 does (F20).
const VIDEO_TYPES = [
  "video/mp4;codecs=avc1.64001F,mp4a.40.2",
  "video/mp4;codecs=avc1.4D401F,mp4a.40.2",
  "video/mp4;codecs=avc1.42E01F,mp4a.40.2",
  "video/mp4;codecs=avc1.42E01E,mp4a.40.2",
  "video/mp4",
  "video/webm;codecs=vp8,opus",
  "video/webm",
];

function videoMime() {
  if (typeof MediaRecorder === "undefined") return null;
  return VIDEO_TYPES.find((t) => MediaRecorder.isTypeSupported(t)) ?? null;
}

// The video bitrate for the server's cap (F20, docs/design/video-quality.md):
// what fits in it over the longest video, less the sound and a fifth for
// encoders that overshoot on fast motion, at most 3 Mbit/s (past that, 720p
// gains little). The iOS app works it out the same way (VideoEncoder.swift).
function videoBitrate() {
  const max = state.config?.video_max_bytes ?? 4 * 1024 * 1024;
  const seconds = state.config?.video_max_seconds ?? 10;
  const total = (Math.max(max - 16 * 1024, 0) * 8) / Math.max(seconds, 1);
  return Math.round(Math.min(3_000_000, Math.max(250_000, total * 0.8 - 64_000)));
}

// Calls `draw` for each new camera frame where the browser says when one
// arrives, so each is drawn once (F20), or else at each screen refresh.
// Returns what stops it.
function eachFrame(video, draw) {
  let id;
  if (video.requestVideoFrameCallback) {
    const loop = () => { draw(); id = video.requestVideoFrameCallback(loop); };
    loop();
    return () => video.cancelVideoFrameCallback(id);
  }
  const loop = () => { draw(); id = requestAnimationFrame(loop); };
  loop();
  return () => cancelAnimationFrame(id);
}

$("#shutter").addEventListener("pointerdown", (e) => {
  rec.suppressClick = false;
  if (!camera.stream || e.button > 0 || !videoMime()) return;
  rec.held = true;
  rec.pointerId = e.pointerId;
  rec.downAt = e.timeStamp;
  rec.startY = e.clientY;
  try { $("#shutter").setPointerCapture?.(e.pointerId); } catch { /* the pointer's already gone: nothing to follow */ }
  clearTimeout(rec.timer);
  rec.timer = setTimeout(() => {
    rec.timer = null;
    startRecording();
  }, HOLD_MS);
});
$("#shutter").addEventListener("pointermove", (e) => {
  if (!rec.recorder || e.pointerId !== rec.pointerId) return;
  // Up zooms in, back down zooms out: a full step (1×) for about a thumb's length of travel.
  setZoom(rec.startZoom + Math.max(0, rec.startY - e.clientY) / ZOOM_SLIDE_PX);
});
function releaseShutter(e) {
  if (e.pointerId !== rec.pointerId) return;
  rec.held = false;
  // Tap or hold, by when the finger went down and came up (the events' own
  // times), not by which ran first: on a busy page the hold timer can run
  // before a quick let-go is handled, and a tap must still be a photo (D11).
  const tap = e.timeStamp - rec.downAt < HOLD_MS;
  if (rec.timer) {
    clearTimeout(rec.timer); // a tap: the click takes a photo
    rec.timer = null;
  } else if (tap) {
    if (rec.recorder) {
      rec.discard = true; // started too soon: not a video after all
      stopRecording();
    }
    rec.suppressClick = false; // the click takes the photo
  } else if (rec.recorder) {
    stopRecording();
  }
}
$("#shutter").addEventListener("pointerup", releaseShutter);
$("#shutter").addEventListener("pointercancel", releaseShutter);
$("#shutter").addEventListener("contextmenu", (e) => e.preventDefault()); // a long press records

async function startRecording() {
  const video = $("#camera-video");
  if (!camera.stream || !video.videoWidth || rec.recorder) return;
  rec.suppressClick = true;
  if (!camera.audio) {
    try {
      camera.audio = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      cameraMessage("Recording without sound: napsack can't use the microphone.");
      report("info", "video without sound", errorFields(err));
    }
    // Let go while the microphone was being asked for: no video this time.
    if (!rec.held || !camera.stream) return;
  }
  const scale = Math.min(1, VIDEO_EDGE / Math.max(video.videoWidth, video.videoHeight));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(video.videoWidth * scale / 2) * 2; // even sizes, for the encoder
  canvas.height = Math.round(video.videoHeight * scale / 2) * 2;
  const g = canvas.getContext("2d");
  g.imageSmoothingQuality = "high"; // the default "low" softens the shrink to 1280
  const draw = () => {
    const crop = camera.hwZoom ? 1 : camera.zoom;
    const w = video.videoWidth / crop, h = video.videoHeight / crop;
    g.save();
    if (camera.mirror) {
      g.translate(canvas.width, 0);
      g.scale(-1, 1);
    }
    g.drawImage(video, (video.videoWidth - w) / 2, (video.videoHeight - h) / 2, w, h, 0, 0, canvas.width, canvas.height);
    g.restore();
  };
  rec.stopDrawing = eachFrame(video, draw);
  const stream = canvas.captureStream(30);
  for (const t of camera.audio?.getAudioTracks() ?? []) stream.addTrack(t);
  rec.chunks = [];
  rec.discard = false;
  rec.startZoom = camera.zoom;
  try {
    rec.recorder = new MediaRecorder(stream, { mimeType: videoMime(), videoBitsPerSecond: videoBitrate(), audioBitsPerSecond: 64_000 });
  } catch (err) {
    rec.stopDrawing();
    cameraMessage("This browser can't record video here. Tap for a photo instead.");
    report("warn", "video recorder failed", errorFields(err));
    return;
  }
  rec.recorder.ondataavailable = (e) => { if (e.data.size) rec.chunks.push(e.data); };
  rec.recorder.onstop = finishRecording;
  rec.recorder.onerror = (e) => report("warn", "video recorder error", errorFields(e.error ?? e));
  // With sound, a silent copy records alongside (X37), so "send without
  // sound" leaves no sound in what's sent, and needs no waiting.
  rec.silent = null;
  rec.silentDone = null;
  if (stream.getAudioTracks().length && !ONE_RECORDER) {
    try {
      const silent = new MediaRecorder(new MediaStream(stream.getVideoTracks()), { mimeType: videoMime(), videoBitsPerSecond: videoBitrate() });
      const chunks = [];
      silent.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
      // Its last piece comes with "stop", so the copy is whole only then.
      rec.silentDone = new Promise((resolve) => {
        silent.onstop = () => resolve(new Blob(chunks, { type: silent.mimeType || videoMime() }));
      });
      silent.start(250);
      rec.silent = silent;
    } catch (err) {
      rec.silent = null; // the video can still go with its sound
      report("debug", "silent copy not recorded", errorFields(err));
    }
  }
  rec.recorder.start(250);
  rec.started = Date.now();
  $("#shutter").classList.add("recording");
  $("#shutter").setAttribute("aria-label", "Recording. Let go to stop");
  $("#capture-controls").classList.add("recording");
  recordingTick();
  rec.tick = setInterval(recordingTick, 100);
}

function recordingTick() {
  const max = state.config?.video_max_seconds ?? 10;
  const s = (Date.now() - rec.started) / 1000;
  $("#shutter").style.setProperty("--progress", String(Math.min(1, s / max)));
  $("#record-time").textContent = `0:${String(Math.min(max, Math.floor(s))).padStart(2, "0")}`;
  $("#record-time").hidden = false;
  if (s >= max) stopRecording(); // the longest a video can be
}

function stopRecording() {
  clearInterval(rec.tick);
  if (rec.silent?.state === "recording") rec.silent.stop();
  const recorder = rec.recorder;
  if (!recorder) return;
  if (recorder.state !== "recording") {
    // It stopped on its own (an error) without saying so: finish now.
    if (recorder.state === "inactive") finishRecording();
    return;
  }
  recorder.stop();
  clearTimeout(rec.stopTimer);
  rec.stopTimer = setTimeout(() => {
    if (rec.recorder !== recorder) return; // it finished
    report("warn", "video recorder never stopped", {
      type: (recorder.mimeType || "").split(";")[0], state: recorder.state, chunks: rec.chunks.length, silent: Boolean(rec.silent),
    });
    recorder.onstop = null;
    rec.timedOut = true;
    finishRecording();
  }, STOP_WAIT_MS);
}

/** The sound button on a recorded video: shown when there's a silent copy to send instead. */
function renderSound() {
  const btn = $("#video-sound");
  const muted = Boolean(camera.videoType) && camera.blob === camera.withoutSound && camera.withoutSound != null;
  btn.hidden = !camera.videoType || !camera.withoutSound;
  btn.setAttribute("aria-pressed", String(muted));
  btn.setAttribute("aria-label", muted ? "Sound off. Tap to send it with sound" : "Sound on. Tap to send it without sound");
  btn.classList.toggle("muted", muted);
  $("#camera-preview-video").muted = muted;
}

$("#video-sound").addEventListener("click", () => {
  if (!camera.videoType || !camera.withoutSound) return;
  const mute = camera.blob !== camera.withoutSound;
  // What's sent is a different file: one without any sound in it.
  camera.blob = mute ? camera.withoutSound : camera.withSound;
  camera.sends = new Map(); // a different video gets new ids, sealed afresh
  camera.sent = new Set();
  renderSound();
  report("debug", mute ? "video muted" : "video unmuted");
});

function finishRecording() {
  const recorder = rec.recorder;
  if (!recorder) return;
  clearTimeout(rec.stopTimer);
  const timedOut = rec.timedOut;
  rec.timedOut = false;
  const type = recorder.mimeType || videoMime();
  const seconds = (Date.now() - rec.started) / 1000;
  rec.stopDrawing();
  rec.recorder = null;
  $("#shutter").classList.remove("recording");
  $("#shutter").style.removeProperty("--progress");
  $("#shutter").setAttribute("aria-label", "Take photo. Hold for a video");
  $("#capture-controls").classList.remove("recording");
  $("#record-time").hidden = true;
  if (rec.discard) return;
  const blob = new Blob(rec.chunks, { type });
  rec.chunks = [];
  if (timedOut && !blob.size) {
    cameraMessage("Couldn't record that video. Try again, or tap for a photo.");
    return;
  }
  if (seconds < 0.5 || !blob.size) {
    cameraMessage("Hold the button a little longer to record a video.");
    return;
  }
  // The envelope and encryption add a little; leave room for them.
  if (state.config?.video_max_bytes && blob.size > state.config.video_max_bytes - 16 * 1024) {
    cameraMessage("That video is too large to send. Try a shorter one.");
    report("warn", "video too large", { bytes: blob.size, seconds: Math.round(seconds) });
    return;
  }
  report("debug", "video recorded", { seconds: Math.round(seconds * 10) / 10, bytes: blob.size, type });
  showPreview(blob, type);
  camera.withSound = blob;
  // The silent copy finishes a moment after; then the sound button shows.
  const silentDone = rec.silentDone;
  rec.silent = rec.silentDone = null;
  silentDone?.then((quiet) => {
    if (camera.withSound !== blob || !quiet.size) return; // retaken meanwhile, or nothing recorded
    camera.withoutSound = quiet;
    renderSound();
  });
  renderSound();
  // Said again over the preview, where it's decided whether to send it.
  if (!recorder.stream.getAudioTracks().length) cameraMessage("This video has no sound: napsack can't use the microphone.");
}

// Drawing on the pic before it's sent (draw.js).
const drawing = createDrawing({
  img: $("#camera-preview"), stage: $(".camera-stage"), canvas: $("#draw-layer"), layer: $("#sticker-layer"),
  penButton: $("#draw-pen"), colors: $("#draw-colors"), sizeButton: $("#draw-size"),
  stickerButton: $("#draw-sticker"), stickerTray: $("#sticker-tray"),
  bigger: $("#sticker-bigger"), smaller: $("#sticker-smaller"), undoButton: $("#draw-undo"),
  onView: () => layoutCaption(), // zoomed, moved, or resized: the caption spans what's on screen
});

/** `zoomable`: a photo from the library, which can be zoomed and moved before it's sent (X52). */
function showDrawing(on, zoomable = false) {
  for (const id of ["#draw-layer", "#sticker-layer", "#draw-tools"]) $(id).hidden = !on;
  drawing.reset({ zoomable });
}

/**
 * The photo to send: as taken, or (drawn on, or zoomed in) the part on
 * screen with the drawing flattened into it, compressed again. What's sent
 * is what the sender saw (docs/implementation/pic-framing.md).
 */
async function finalPhoto() {
  if (!drawing.hasMarks() && !drawing.cropped()) return new Uint8Array(await camera.blob.arrayBuffer());
  const flat = drawing.flatten(MAX_EDGE);
  const blob = await compressPhoto(flat, flat.width, flat.height);
  report("debug", "pic drawn on or cropped", { bytes: blob.size, size: `${flat.width}x${flat.height}` });
  return new Uint8Array(await blob.arrayBuffer());
}

function showCapture() {
  clearPreview();
  $("#camera-video").hidden = false;
  // Back from a photo (Retake) to a camera that couldn't start: say why now.
  if (!camera.stream && camera.problem) cameraMessage(camera.problem);
  $("#capture-controls").hidden = false;
  $("#send-controls").hidden = true;
  $("#zoom-chip").hidden = !camera.stream;
  if (camera.stream) setZoom(1); // each new pic or video starts at 1× (Nate, 2026-10-29)
  renderTorch(); // lit again, if it was on
  clearCaption();
  // A new pic from the camera tab: pick who it's for again.
  if (camera.picked) {
    camera.to = [];
    camera.picked = false;
  }
}

function clearPreview() {
  if (camera.previewUrl) URL.revokeObjectURL(camera.previewUrl);
  camera.previewUrl = null;
  camera.blob = null;
  camera.videoType = null;
  camera.withSound = camera.withoutSound = null;
  $("#video-sound").hidden = true;
  const played = $("#camera-preview-video");
  played.pause();
  played.removeAttribute("src");
  played.load();
  played.hidden = true;
  camera.sends = new Map(); // a new pic gets new ids and is sealed afresh...
  camera.sent = new Set();   // ...and hasn't gone to anyone
  const img = $("#camera-preview");
  img.removeAttribute("src");
  img.hidden = true;
  showDrawing(false);
}

/**
 * What was taken or picked, ready to send. `original`: a photo from the
 * library, shown from its own file (sharper when zoomed in, and what a crop
 * is cut from); `blob` is it made small, what's sent when it isn't cropped.
 */
function showPreview(blob, videoType = null, original = null) {
  clearPreview();
  camera.blob = blob;
  camera.videoType = videoType;
  camera.previewUrl = URL.createObjectURL(original ?? blob);
  if (videoType) {
    // Drawing and stickers are for photos; a video loops, with its sound.
    const played = $("#camera-preview-video");
    played.src = camera.previewUrl;
    played.hidden = false;
    played.play().catch(() => { played.muted = true; played.play().catch(() => {}); });
  } else {
    const img = $("#camera-preview");
    showDrawing(true, Boolean(original)); // only a photo from the library zooms: one just taken shows as the camera did
    img.src = camera.previewUrl;
    img.hidden = false;
  }
  $("#camera-video").hidden = true;
  cameraMessage("");
  $("#capture-controls").hidden = true;
  $("#send-controls").hidden = false;
  $("#zoom-chip").hidden = true;
  renderTorch(); // no light while looking at what was taken
  renderSendWho();
  $("#caption-hint").hidden = false; // until there's a caption
  fitCaption();
}

// Redrawing through a canvas downsizes the photo and strips EXIF (including GPS).
function drawScaled(source, width, height, edge, mirror) {
  const scale = Math.min(1, edge / Math.max(width, height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));
  const ctx = canvas.getContext("2d");
  if (mirror) {
    ctx.translate(canvas.width, 0);
    ctx.scale(-1, 1);
  }
  ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas;
}

const encodeJpeg = (canvas, quality) => new Promise((resolve, reject) =>
  canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("Couldn't encode the photo."))), "image/jpeg", quality));

/**
 * Every snap ends up a JPEG of at most SNAP_TARGET_BYTES: lower the quality
 * first, then shrink the picture, until it fits. Typical phone photos land
 * around 120-200 KB at 1280px.
 */
async function compressPhoto(source, width, height, mirror = false) {
  let edge = MAX_EDGE;
  while (edge >= 320) {
    const canvas = drawScaled(source, width, height, edge, mirror);
    for (const quality of [0.8, 0.68, 0.56]) {
      const blob = await encodeJpeg(canvas, quality);
      if (blob.size <= SNAP_TARGET_BYTES) {
        report("debug", "pic compressed", { from: `${width}x${height}`, to: `${canvas.width}x${canvas.height}`, quality, bytes: blob.size });
        return blob;
      }
    }
    edge = Math.round(edge * 0.75);
  }
  report("warn", "pic too large to compress", { from: `${width}x${height}` });
  throw new Error("Couldn't make that photo small enough to send.");
}

/** Opens the camera. `to` is who the pic goes to: the open chat, or nobody yet (Send to… asks). */
function openCamera(to) {
  camera.to = to;
  camera.picked = false;
  if (!to.length) showTab("camera");
  $("#camera-dialog").showModal();
  showCapture();
  startStream();
}

$("#camera-button").addEventListener("click", () => {
  if (state.activeGroupId) openCamera([{ kind: "group", id: state.activeGroupId }]);
  else if (state.activeId) openCamera([{ kind: "friend", id: state.activeId }]);
});
$("#list-camera").addEventListener("click", () => openCamera([]));
$("#tab-camera").addEventListener("click", () => openCamera([]));

$("#camera-dialog").addEventListener("close", () => {
  camera.torch = false; // the next time, the flash starts off
  stopStream();
  clearPreview();
  clearCaption(); // sent or abandoned, it shouldn't linger in the page
  camera.to = [];
  if (tabs.current === "camera") showTab(profileTabOpen() ? "profile" : "chats");
});

$("#flip-camera").addEventListener("click", () => {
  camera.facing = camera.facing === "user" ? "environment" : "user";
  if (rec.recorder) switchWhileRecording();
  else startStream();
});

/**
 * Recording, a double tap (another finger) switches cameras without stopping
 * (X37): recording draws frames from the preview, so it only needs the
 * preview to show the other camera. The microphone and the recorder stay.
 */
async function switchWhileRecording() {
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: camera.facing, width: { ideal: 1920 }, height: { ideal: 1080 } },
      audio: false,
    });
  } catch (err) {
    report("info", "switching cameras while recording failed", errorFields(err));
    return;
  }
  if (!rec.recorder || !camera.stream) {
    stream.getTracks().forEach((t) => t.stop()); // stopped meanwhile
    return;
  }
  const old = camera.stream;
  camera.stream = stream;
  const facing = stream.getVideoTracks()[0]?.getSettings?.().facingMode;
  camera.mirror = (facing || camera.facing) !== "environment";
  const video = $("#camera-video");
  video.classList.toggle("mirrored", camera.mirror);
  video.srcObject = stream;
  old.getVideoTracks().forEach((t) => t.stop());
  const range = stream.getVideoTracks()[0]?.getCapabilities?.().zoom;
  camera.hwZoom = range && range.max > Math.max(1, range.min) ? range : null;
  camera.torchable = Boolean(stream.getVideoTracks()[0]?.getCapabilities?.().torch);
  setZoom(camera.zoom);
  renderTorch(); // the other camera may have no light (a front one), or have one
}

// Double-tapping the live camera switches it, like the button. Counted from
// clicks rather than `dblclick`, which phones don't reliably send.
let lastStageTap = { at: 0, x: 0, y: 0 };
$(".camera-stage").addEventListener("click", (e) => {
  // While recording too: a second finger double-taps while the first holds the shutter.
  if ($("#camera-video").hidden || !camera.stream || e.target.closest("button, input, label")) return;
  const last = lastStageTap;
  if (e.timeStamp - last.at < DOUBLE_TAP_MS && Math.hypot(e.clientX - last.x, e.clientY - last.y) <= DOUBLE_TAP_PX) {
    lastStageTap = { at: 0, x: 0, y: 0 };
    $("#flip-camera").click();
  } else {
    lastStageTap = { at: e.timeStamp, x: e.clientX, y: e.clientY };
  }
});

$("#shutter").addEventListener("click", async () => {
  if (rec.suppressClick) {
    rec.suppressClick = false; // the end of a long press: that was a video
    return;
  }
  const video = $("#camera-video");
  if (!camera.stream || !video.videoWidth) return;
  try {
    // Freeze the frame first; the video keeps moving while we compress. Zoomed
    // without the camera's help: just the middle, as the preview shows it.
    const crop = camera.hwZoom ? 1 : camera.zoom;
    const w = video.videoWidth / crop, h = video.videoHeight / crop;
    const frame = crop === 1 ? await createImageBitmap(video)
      : await createImageBitmap(video, (video.videoWidth - w) / 2, (video.videoHeight - h) / 2, w, h);
    const blob = await compressPhoto(frame, frame.width, frame.height, camera.mirror);
    frame.close();
    showPreview(blob);
  } catch (err) {
    cameraMessage(err.message);
  }
});

$("#file-input").addEventListener("change", async (e) => {
  const file = e.target.files?.[0];
  e.target.value = "";
  if (!file) return;
  let bitmap;
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  } catch {
    cameraMessage("That file couldn't be read as a photo.");
    return;
  }
  try {
    showPreview(await compressPhoto(bitmap, bitmap.width, bitmap.height), null, file);
  } catch (err) {
    cameraMessage(err.message);
  } finally {
    bitmap.close();
  }
});

// The caption grows with what's typed, up to five lines at its size on the
// picture (anything that would make a sixth is refused), and says how much
// room is left of its 200 characters once there's little.
const CAPTION_MAX = 200;
const CAPTION_LINES = 5;
let captionKept = { value: "", at: 0 }; // the last caption that fit, and where the cursor was
function fitCaption() {
  const input = $("#snap-caption");
  // Enter finishes it, so a caption is one paragraph: pasted line breaks become spaces.
  if (/[\r\n]/.test(input.value)) {
    const at = input.value.slice(0, input.selectionStart).replace(/[\r\n]+/g, " ").length;
    input.value = input.value.replace(/[\r\n]+/g, " ");
    input.setSelectionRange(at, at);
  }
  input.style.height = "auto";
  if (input.offsetParent && captionLines(input) > CAPTION_LINES) {
    input.value = captionKept.value;
    input.setSelectionRange(captionKept.at, captionKept.at);
  }
  captionKept = { value: input.value, at: input.selectionStart };
  input.style.height = `${input.scrollHeight}px`;
  const used = [...input.value].length;
  const count = $("#snap-caption-count");
  count.hidden = used < CAPTION_MAX - 40;
  count.textContent = `${used}/${CAPTION_MAX}`;
  count.classList.toggle("full", used >= CAPTION_MAX);
}
/** How many lines the caption takes as it's drawn now (its height is "auto": one line, scrolling). */
function captionLines(input) {
  const css = getComputedStyle(input);
  const line = parseFloat(css.fontSize) * 1.25;
  return Math.round((input.scrollHeight - parseFloat(css.paddingTop) - parseFloat(css.paddingBottom)) / line);
}
function clearCaption() {
  $("#snap-caption").value = "";
  captionKept = { value: "", at: 0 };
  $("#snap-caption-box").hidden = true;
  $("#snap-caption-box").classList.remove("editing");
  $("#caption-hint").hidden = true;
  camera.captionY = camera.captionShownY = null;
  fitCaption();
}
// A line more or less changes the strip's height, so where it can sit inside the picture.
$("#snap-caption").addEventListener("input", () => layoutCaption());

// ---------- captions anywhere on the picture (X33) ----------
// Tap the picture where the caption should go, and type. Enter, or a tap
// anywhere else, finishes typing: the caption stays on the picture, nothing
// is sent (only the send buttons send). Drag it up or down to move it. Where
// it sits travels with the picture, sealed in with it (formats 4 to 7).
const CAPTION_EDGE = 0.08; // never so close to an edge it's cut off

/**
 * The picture as it shows on the stage, on screen: a video letterboxed, a
 * photo letterboxed and perhaps zoomed (then just the part on screen, which is
 * what's sent). `y` is a fraction of its height, as the viewer shows it.
 */
function previewRect() {
  const stage = $(".camera-stage").getBoundingClientRect();
  if (!camera.videoType) {
    const v = drawing.visible();
    return { left: stage.left + v.left, top: stage.top + v.top, width: v.width, height: v.height };
  }
  const media = $("#camera-preview-video");
  const box = media.getBoundingClientRect();
  const r = containedRect(media, box.width, box.height);
  return { left: box.left + r.left, top: box.top + r.top, width: r.width, height: r.height };
}

/** Where a letterboxed (object-fit: contain) picture or video is drawn in its box of `w` x `h`. */
function containedRect(media, w, h) {
  const nw = media.naturalWidth || media.videoWidth || w, nh = media.naturalHeight || media.videoHeight || h;
  const scale = Math.min(w / nw, h / nh);
  return { left: (w - nw * scale) / 2, top: (h - nh * scale) / 2, width: nw * scale, height: nh * scale };
}

/**
 * Draws a caption strip by the one rule every client follows
 * (docs/implementation/pic-framing.md, "The caption"): across the picture's
 * whole width, its middle at `y` of the picture's height but kept so the
 * whole strip stays inside the picture (centered if it's taller), its text
 * sized by that width (style.css reads --pic-w). `pic` is in `el`'s parent's
 * coordinates; `fit` sizes the strip's height once its width is set. Returns
 * where its middle ends up, as a fraction of the picture's height.
 */
function stripOnPicture(el, pic, y, fit = null) {
  el.style.left = `${pic.left}px`;
  el.style.width = `${pic.width}px`;
  el.style.setProperty("--pic-w", `${pic.width}px`);
  fit?.();
  const h = el.offsetHeight, H = pic.height;
  const middle = h >= H ? H / 2 : Math.min(H - h / 2, Math.max(h / 2, y * H));
  el.style.top = `${pic.top + middle}px`;
  return H ? middle / H : y;
}

function placeCaption(y) {
  camera.captionY = Math.min(1 - CAPTION_EDGE, Math.max(CAPTION_EDGE, y));
  layoutCaption();
}

/** The caption on the stage, where it sits on the picture; again as it's typed, and whenever the picture moves or changes size. */
function layoutCaption() {
  const box = $("#snap-caption-box");
  if (camera.captionY == null || box.hidden) return fitCaption();
  const pic = previewRect();
  const stage = $(".camera-stage").getBoundingClientRect();
  camera.captionShownY = stripOnPicture(box, { ...pic, left: pic.left - stage.left, top: pic.top - stage.top }, camera.captionY, fitCaption);
}
// A video's size, or the window's, can change while its caption is on it (a photo's is drawing's onView).
new ResizeObserver(() => { if (camera.videoType) layoutCaption(); }).observe($(".camera-stage"));
$("#camera-preview-video").addEventListener("loadedmetadata", () => layoutCaption());

function editCaption() {
  const box = $("#snap-caption-box");
  box.hidden = false;
  box.classList.add("editing");
  $("#caption-hint").hidden = true;
  layoutCaption();
  $("#snap-caption").focus();
}

/** Typing's done: the caption stays where it is, or goes away if it's empty. */
function finishCaption() {
  const box = $("#snap-caption-box");
  box.classList.remove("editing");
  if (!$("#snap-caption").value.trim()) {
    $("#snap-caption").value = "";
    box.hidden = true;
    camera.captionY = camera.captionShownY = null;
    $("#caption-hint").hidden = $("#send-controls").hidden;
  }
}

$("#snap-caption").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.isComposing) {
    e.preventDefault();
    $("#snap-caption").blur(); // finishes typing; never sends
  }
});
let captionBlurAt = 0;
$("#snap-caption").addEventListener("blur", () => {
  captionBlurAt = Date.now();
  finishCaption();
});

// A tap on the picture: places a caption there, or (while typing) finishes it.
$(".camera-stage").addEventListener("click", (e) => {
  if ($("#send-controls").hidden || e.target.closest("button, input, label, textarea, .snap-caption-box, .sticker, .draw-tools, .sticker-tray")) return;
  if (Date.now() - captionBlurAt < 400) return; // that tap ended the typing
  if (drawing.busy()) {
    drawing.settle(); // first, put the sticker down or close the tray
    return;
  }
  if (!$("#snap-caption-box").hidden) return; // one caption; drag it to move it
  const pic = previewRect();
  placeCaption((e.clientY - pic.top) / pic.height);
  editCaption();
});

// Dragging the caption up and down; a tap on it (no drag) edits it.
const captionDrag = { id: null, startY: 0, from: 0, moved: false };
$("#snap-caption-box").addEventListener("pointerdown", (e) => {
  if ($("#snap-caption-box").classList.contains("editing")) return;
  captionDrag.id = e.pointerId;
  captionDrag.startY = e.clientY;
  captionDrag.from = camera.captionShownY ?? camera.captionY ?? 0.7; // from where it shows
  captionDrag.moved = false;
  e.currentTarget.setPointerCapture?.(e.pointerId);
  e.preventDefault();
});
$("#snap-caption-box").addEventListener("pointermove", (e) => {
  if (captionDrag.id !== e.pointerId) return;
  const dy = e.clientY - captionDrag.startY;
  if (Math.abs(dy) > 6) captionDrag.moved = true;
  if (captionDrag.moved) placeCaption(captionDrag.from + dy / previewRect().height);
});
const endCaptionDrag = (e) => {
  if (captionDrag.id !== e.pointerId) return;
  captionDrag.id = null;
  // Dragged: it's put where it shows (kept inside the picture), so that's where it's sent.
  if (captionDrag.moved && camera.captionShownY != null) camera.captionY = camera.captionShownY;
  if (!captionDrag.moved && e.type === "pointerup") editCaption();
};
$("#snap-caption-box").addEventListener("pointerup", endCaptionDrag);
$("#snap-caption-box").addEventListener("pointercancel", endCaptionDrag);

$("#retake").addEventListener("click", () => {
  showCapture();
  if (!camera.stream) startStream();
});

$("#send-snap").addEventListener("click", () => {
  if (!camera.blob) return;
  if (!camera.to.length) return openSendTo();
  sendPics(camera.to);
});

// ---------- sending a pic to one or more chats (X26) ----------

const recipientKey = (r) => `${r.kind === "group" ? "g" : "d"}:${r.id}`;

function recipientName(r) {
  if (r.kind === "group") return groupById(r.id)?.name ?? "the group";
  const chat = chatById(r.id);
  return chat ? chatName(chat) : "them";
}

/** "Ana", "Ana and Ben", "Ana, Ben and Cal", "Ana, Ben, Cal and 2 others". */
function listNames(rs) {
  const names = rs.map(recipientName);
  if (names.length <= 1) return names[0] ?? "";
  if (names.length > 4) return `${names.slice(0, 3).join(", ")} and ${names.length - 3} others`;
  return `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

function sendLabel() {
  if (!camera.to.length) return "Send to…";
  return camera.to.length === 1 ? `Send to ${recipientName(camera.to[0])}` : `Send to ${camera.to.length}`;
}

/**
 * From inside a chat (X34), a button beside Send says who it's going to; a
 * tap opens Send to… with them ticked, to add friends or groups.
 */
function renderSendWho() {
  const who = $("#send-who");
  who.hidden = !camera.to.length || camera.picked;
  who.textContent = `To ${listNames(camera.to)} +`;
  who.setAttribute("aria-label", `Sending to ${listNames(camera.to)}. Add more people or groups`);
  // The button beside it says who; this one just sends.
  $("#send-snap").textContent = who.hidden ? sendLabel() : "Send";
}
$("#send-who").addEventListener("click", openSendTo);

/**
 * Sends the pic to each recipient in turn, each its own end-to-end encrypted
 * copy (format 2 to a friend, format 3 to a group). Send again after a
 * failure skips whoever has it and resends the same pic to the rest, so a
 * dropped response never makes a second one.
 */
async function sendPics(to) {
  const btn = $("#send-snap");
  btn.disabled = true;
  cameraMessage("Sending…");
  const failed = [];
  try {
    const media = camera.videoType
      ? { video: new Uint8Array(await camera.blob.arrayBuffer()), type: camera.videoType }
      : { photo: await finalPhoto() };
    const caption = $("#snap-caption").value.trim();
    media.y = caption ? camera.captionShownY ?? camera.captionY : null; // where it shows, inside the picture
    for (const r of to) {
      if (camera.sent.has(recipientKey(r))) continue;
      try {
        if (r.kind === "group") await sendGroupPicTo(r.id, media, caption);
        else await sendDirectPicTo(r.id, media, caption);
        camera.sent.add(recipientKey(r));
      } catch (err) {
        failed.push({ r, err });
        report("warn", "sending a pic failed", { to: r.kind, ...errorFields(err) });
      }
    }
  } catch (err) {
    cameraMessage(sendProblem(err));
    return;
  } finally {
    btn.disabled = false;
  }
  if (failed.length) {
    const sent = to.filter((r) => camera.sent.has(recipientKey(r)));
    const err = failed[0].err;
    cameraMessage(!sent.length && failed.length === 1 ? sendProblem(err)
      : `${sent.length ? `Sent to ${listNames(sent)}. ` : ""}Couldn't send to ${listNames(failed.map((f) => f.r))}. `
        + (retryable(err) ? "The connection dropped: tap Send to try again." : err.message));
    return;
  }
  const picked = camera.picked;
  const what = camera.videoType ? "Video" : "Pic";
  $("#camera-dialog").close();
  if (picked) {
    showToast(`${what} sent to ${listNames(to)}.`);
    refreshChats();
    refreshGroups();
  }
}

async function sendDirectPicTo(friendId, media, caption) {
  const slot = `d:${friendId}`;
  // The same id on every try (and on Send again), so a retry after a dropped
  // response isn't a second pic.
  if (!camera.sends.has(slot)) camera.sends.set(slot, newClientId());
  const clientId = camera.sends.get(slot);
  // Format 2 (a photo) or 4 (a video): the caption is sealed in with it, so only the friend sees it.
  const key = await keyFor(friendId);
  const sealed = media.video
    ? await e2e.encryptVideo(key, media.video, media.type, caption, state.me.id, friendId, media.y)
    : await e2e.encryptImage(key, media.photo, caption, state.me.id, friendId, media.y);
  const max = media.video ? state.config?.video_max_bytes : state.config?.snap_max_bytes;
  if (max && sealed.length > max) throw new Error(`That ${media.video ? "video" : "photo"} is too large to send.`);
  const format = media.video ? e2e.VIDEO_FORMAT : e2e.IMAGE_FORMAT;
  const m = await withRetries(() => getJSON(`/chats/${friendId}/snaps?format=${format}&client_id=${clientId}`, {
    method: "POST",
    body: sealed,
    headers: { "Content-Type": "application/octet-stream" },
  }));
  await upsertMessage(m);
  if (state.activeId === friendId) {
    toNewest(); // sent: the newest message, at the bottom
    renderMessages();
  }
}

async function sendGroupPicTo(groupId, media, caption) {
  const key = `g:${groupId}`;
  // Sealed once per pic and group, so Send again after a dropped connection
  // resends the same one (the server keeps one copy).
  if (!camera.sends.has(key)) {
    const format = media.video ? e2e.GROUP_VIDEO_FORMAT : e2e.GROUP_IMAGE_FORMAT;
    camera.sends.set(key, groupSender(groupId,
      (opts) => (media.video ? e2e.encryptGroupVideo(media.video, media.type, caption, opts, media.y)
        : e2e.encryptGroupImage(media.photo, caption, opts, media.y)),
      (s) => getJSON(`/groups/${groupId}/pics?format=${format}`, {
        method: "POST", body: s.content, headers: { "Content-Type": "application/octet-stream", "X-Napsack-Keys": keysHeader(s) },
      })));
  }
  const m = await withRetries(camera.sends.get(key));
  upsertGroupMessage(m);
  if (state.activeGroupId === groupId) {
    toNewest();
    renderMessages();
  }
}

// The picker: every chat a pic can go to, newest first. Not chats that can't
// take one (a changed key, a turned-off account, Team Napsack), and hidden
// chats only when searched for, as in the list.
const sendTo = { picked: new Set() };

function sendToEntries() {
  return [
    ...state.chats.filter((c) => !(c.keyChanged || c.deactivated || c.system)).map((c) => ({
      r: { kind: "friend", id: c.id },
      at: c.last_message?.created_at ?? 0,
      name: chatName(c),
      sub: chatName(c) !== c.username ? `@${c.username}` : "",
      hidden: c.hidden,
      search: `${chatName(c)} ${c.username}`.toLowerCase(),
      avatar: () => paintAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), c),
    })),
    ...state.groups.map((g) => ({
      r: { kind: "group", id: g.id },
      at: g.last_message?.created_at ?? 0,
      name: g.name,
      sub: "Group",
      hidden: false,
      search: g.name.toLowerCase(),
      avatar: () => paintGroupAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), g),
    })),
  ].sort((a, b) => b.at - a.at || a.name.localeCompare(b.name));
}

/** Who's picked, in the list's order (not the order they were tapped). */
function pickedRecipients() {
  const listed = sendToEntries().map((e) => e.r).filter((r) => sendTo.picked.has(recipientKey(r)));
  const keys = new Set(listed.map(recipientKey));
  const rest = [...sendTo.picked].filter((k) => !keys.has(k)).map((k) => ({ kind: k[0] === "g" ? "group" : "friend", id: Number(k.slice(2)) }));
  return [...listed, ...rest];
}

function renderSendTo() {
  const q = $("#send-to-search").value.trim().toLowerCase();
  const rows = sendToEntries().filter((e) => (q ? e.search.includes(q) : !e.hidden));
  $("#send-to-list").replaceChildren(...(rows.length ? rows.map((e) => {
    const key = recipientKey(e.r);
    const box = el("input", { type: "checkbox", value: key });
    box.checked = sendTo.picked.has(key);
    box.addEventListener("change", () => {
      if (box.checked) sendTo.picked.add(key);
      else sendTo.picked.delete(key);
      renderSendToFoot();
    });
    return el("li", {}, el("label", { class: "send-to-row" },
      e.avatar(),
      el("span", { class: "send-to-name" },
        el("span", { text: e.name }),
        e.sub ? el("span", { class: "send-to-sub", text: e.sub }) : null),
      box));
  }) : [el("li", { class: "send-to-empty", text: q ? "Nobody by that name." : "No chats yet: add a friend first." })]));
  renderSendToFoot();
}

function renderSendToFoot() {
  const picked = pickedRecipients();
  $("#send-to-go").disabled = picked.length === 0;
  $("#send-to-go").textContent = picked.length > 1 ? `Send to ${picked.length}` : "Send";
  $("#send-to-picked").textContent = picked.length ? listNames(picked) : "Pick one or more.";
}

function openSendTo() {
  // Starts from whoever it's already going to.
  sendTo.picked = new Set(camera.to.map(recipientKey));
  $("#send-to-search").value = "";
  renderSendTo();
  $("#send-to-dialog").showModal();
}

$("#send-to-search").addEventListener("input", renderSendTo);
$("#send-to-go").addEventListener("click", () => {
  camera.to = pickedRecipients();
  camera.picked = true;
  $("#send-to-dialog").close();
  $("#send-snap").textContent = sendLabel();
  sendPics(camera.to);
});

// ---------- tabs on phones (X26) ----------
// Along the bottom of the chat list: Chats, Camera, Profile. Profile shows
// your profile in place of the list; Camera opens the camera with no chat
// picked, and Send to… asks who it's for. Computers keep the side-by-side
// layout: a camera button in the list's bar, and the profile at the bottom.
const tabs = { current: "chats" };

function showTab(name) {
  tabs.current = name;
  for (const t of ["chats", "camera", "profile"]) $(`#tab-${t}`).setAttribute("aria-current", t === name ? "page" : "false");
}

const profileTabOpen = () => $("#profile-dialog").open && $("#profile-dialog").classList.contains("as-tab");

function closeProfileTab() {
  if (profileTabOpen()) $("#profile-dialog").close();
}

$("#tab-chats").addEventListener("click", () => {
  closeProfileTab();
  showTab("chats");
});
$("#tab-profile").addEventListener("click", () => {
  const dialog = $("#profile-dialog");
  // Not modal: the tabs stay usable underneath it.
  dialog.classList.add("as-tab");
  if (!dialog.open) dialog.show();
  dialog.scrollTop = 0;
  showTab("profile");
  openProfile(state.me.id);
});
$("#profile-dialog").addEventListener("close", () => {
  const dialog = $("#profile-dialog");
  if (!dialog.classList.contains("as-tab")) return;
  dialog.classList.remove("as-tab");
  if (tabs.current === "profile") showTab("chats");
});
// Grown to a computer's width: the profile goes back to being a sheet.
wideLayout.addEventListener("change", () => { if (wideLayout.matches) closeProfileTab(); });

// ---------- snap viewer ----------

// A `run` taps through every unopened pic in the chat: closing one opens the
// next. A pic counts as opened only once it's actually on screen: then the
// app tells the server (`confirmOpened`). So a dropped download, a slow
// decode, or a tap before it appears never loses one; it stays unopened, to
// try again. Stopping halfway (Escape, or leaving the app) leaves the rest
// unopened too.
const viewer = { url: null, timer: null, run: null, loading: false, shownAt: 0, after: null, captionY: null };
// Taps this soon after a pic appears don't count: a quick double tap
// shouldn't skip past a pic nobody saw.
const TAP_GUARD_MS = 600;

/** Whether a group message is a pic or video from someone else I haven't opened. */
const groupPicWaiting = (m) => Boolean(m.pic) && m.sender_id !== state.me.id
  && !m.pic.viewers.includes(state.me.id) && !m.pic.discard_reason;
/** Whether a direct message is a pic or video from them, unopened. */
const directPicWaiting = (m) => m.kind === "snap" && m.sender_id !== state.me.id && m.snap_state === "pending";

/** Unopened pics in the open chat (or, from the list, the chat they're in), oldest first. */
function waitingPics() {
  if (viewer.run?.fromList) return viewer.run.pics;
  if (state.activeGroupId) return (state.groupMessages.get(state.activeGroupId) || []).filter(groupPicWaiting);
  return (state.messages.get(state.activeId) || []).filter(directPicWaiting);
}

/** Tapping a pic opens it, then the others waiting in the chat, one by one. */
function openPics(first) {
  if (viewer.loading) return;
  viewer.run = { seen: new Set(), shown: new Set() };
  viewer.after = null;
  openPic(first);
}

// ---------- pics straight from the chat list (X41) ----------
// A tap on a chat whose newest message is a pic or video waiting from them
// shows that chat's waiting pics, back to back, without opening the chat; you
// are on the list after, as before. Which pics are the server's say, asked as
// the tap lands (the list may be out of date: opened on another device). Only
// pics are opened: a text of theirs from before stays unread for the chat, and
// the row keeps its dot (the server's count). If none was waiting after all,
// the tap opens the chat, as any other row's.

/** Formats of pics and videos this app opens (loadSnap, loadGroupPic). */
const DIRECT_PIC_FORMATS = [1, 2, e2e.VIDEO_FORMAT, e2e.IMAGE_FORMAT];
const GROUP_PIC_FORMATS = [e2e.GROUP_FORMAT, e2e.GROUP_VIDEO_FORMAT, e2e.GROUP_IMAGE_FORMAT];

/** Whether a tap on this chat's row shows its pics: its newest message is one waiting from them, that this app opens. */
function chatOpensPics(chat) {
  const m = chat?.last_message;
  // chatStatus says "New pic" only for one that can be opened (not a changed key, not a turned-off account).
  return Boolean(m) && chatStatus(chat).marker === "snap" && DIRECT_PIC_FORMATS.includes(m.format ?? 1);
}

/** The same for a group: its newest message a pic from someone else, not opened by me. */
function groupOpensPics(g) {
  const m = g?.last_message;
  if (!m || !groupPicWaiting(m)) return false;
  return m.format === groupsPlainFormat || (GROUP_PIC_FORMATS.includes(m.format) && Boolean(m.key));
}

/** What a screen reader hears of such a row, after its name and newest message. */
const picsHint = (m) => `Opens the ${mediaWord(m)}, not the chat`;

/**
 * Shows the pics waiting in a chat ("d") or group ("g") from the list.
 * `page` is the chat's newest messages, asked for as the tap landed.
 */
async function picsFromList(kind, id, page = null) {
  if (viewer.loading || !$("#viewer").hidden) return;
  const group = kind === "g";
  const chat = group ? groupById(id) : chatById(id);
  if (!chat) return;
  page ??= getJSON(`/${group ? "groups" : "chats"}/${id}/messages?limit=${pageSize()}`);
  const unread = chat.unread; // as the tap saw it: whether the group is read after
  const run = { seen: new Set(), shown: new Set(), fromList: true, pics: [], gone: false, openChat: false };
  viewer.run = run;
  viewer.after = () => afterPicsFromList(kind, id, run, unread);
  showOpening(group ? chat.name : chatName(chat));
  try {
    run.messages = await page;
  } catch (err) {
    if (viewer.run !== run) return; // closed meanwhile: nothing was opened
    report("warn", "opening pics from the list failed", { [group ? "group_id" : "friend_id"]: id, ...errorFields(err) });
    return showViewerProblem("Couldn't load this pic. It's still unopened: try again when your connection is better.");
  }
  if (viewer.run !== run) return;
  run.pics = run.messages.filter(group ? groupPicWaiting : directPicWaiting);
  if (!run.pics.length) { // opened elsewhere meanwhile
    run.openChat = true;
    return stopViewer();
  }
  openPic(run.pics[0]);
}

/** Once the viewer has closed: the chat, if nothing was waiting after all; a group read, if its pics were all that was unread. */
function afterPicsFromList(kind, id, run, unread) {
  if (run.openChat) return kind === "g" ? openGroup(id) : openChat(id);
  // A direct chat's pics are counted read as they're opened (the server's
  // `unread` counts them); its texts wait for the chat.
  if (kind !== "g" || !readAfterShowing(run.shown, unread, run.messages || [])) return;
  // Anything newer than what was asked for came while viewing, unseen.
  const newest = run.messages[run.messages.length - 1]?.id ?? 0;
  if ((groupById(id)?.last_message?.id ?? 0) <= newest) markGroupRead(id);
}

/**
 * Whether a group counts as read after its pics were shown from the list:
 * only if they were all that was unread, its newest `unread` messages from
 * others (groups.rs counts the same). Otherwise a text nobody saw would show
 * as seen ("Seen by"), so it stays unread. As the iPhone's (`readAfterShowing`).
 */
function readAfterShowing(shown, unread, messages) {
  if (!unread) return false;
  const theirs = messages.filter((m) => m.sender_id !== state.me.id && m.kind !== "event");
  return theirs.length >= unread && theirs.slice(-unread).every((m) => shown.has(m.id));
}

/** A pic that can't be shown for a reason other than the connection. */
class PicProblem extends Error {}

async function openPic(m) {
  const run = viewer.run;
  run.seen.add(m.id);
  viewer.loading = true;
  showOpening(personName(m.sender_id, m.sender_name ?? ""));
  let pic;
  try {
    pic = await (m.pic ? loadGroupPic(m) : loadSnap(m));
  } catch (err) {
    viewer.loading = false;
    if (viewer.run !== run) return;
    // Opened on another device, or expired: on to the next.
    if (err.status === 410 || err.status === 404) {
      run.gone = true;
      return nextPic();
    }
    report("warn", "opening a pic failed", { message_id: m.id, ...errorFields(err) });
    return showViewerProblem(err instanceof PicProblem ? err.message
      : "Couldn't load this pic. It's still unopened: try again when your connection is better.");
  }
  if (viewer.run !== run) {
    viewer.loading = false; // stopped while it loaded: still unopened
    return;
  }
  const shown = await showInViewer(pic);
  viewer.loading = false;
  if (shown) {
    run.shown.add(m.id);
    confirmOpened(m);
  }
  else if (viewer.run === run) showViewerProblem("This pic couldn't be shown. It's still unopened.");
}

function nextPic() {
  if (viewer.loading) return;
  if (viewer.url && Date.now() - viewer.shownAt < TAP_GUARD_MS) return;
  const run = viewer.run;
  const next = run && waitingPics().find((m) => !run.seen.has(m.id));
  if (!next) {
    // From the list, every one opened elsewhere before it showed: the chat instead.
    if (run?.fromList && run.gone && !run.shown.size) run.openChat = true;
    return stopViewer();
  }
  clearViewer(); // the viewer stays up, saying "Opening…", while the next one loads
  openPic(next);
}

/** Fetches and decrypts one direct pic or video: { blob, video, caption, from }. */
async function loadSnap(m) {
  if (![1, 2, e2e.VIDEO_FORMAT, e2e.IMAGE_FORMAT].includes(m.format ?? 1)) {
    throw new PicProblem(`This ${mediaWord(m)} was sent from a newer version of napsack. Reload to open it.`);
  }
  const sealed = await api(`/snaps/${m.id}`, { as: "bytes" });
  const from = personName(m.sender_id, "");
  try {
    if (isVideo(m)) {
      const v = await withReadKey(m.sender_id, (k) => e2e.decryptVideo(k, sealed, m.sender_id, m.recipient_id));
      return { blob: new Blob([v.media], { type: v.type }), video: true, caption: v.caption, y: v.y, from };
    }
    if (m.format === e2e.IMAGE_FORMAT) {
      const p = await withReadKey(m.sender_id, (k) => e2e.decryptImage(k, sealed, m.sender_id, m.recipient_id));
      return { blob: new Blob([p.media], { type: "image/jpeg" }), caption: p.caption, y: p.y, from };
    }
    const pic = await withReadKey(m.sender_id, (k) => e2e.decryptPic(k, sealed, m.format ?? 1, m.sender_id, m.recipient_id));
    return { blob: new Blob([pic.photo], { type: "image/jpeg" }), caption: pic.caption, from };
  } catch {
    throw new PicProblem(`This ${mediaWord(m)} couldn't be decrypted.`);
  }
}

/**
 * Tells the server the pic was seen, so it's now opened (and gone). Tried a
 * few times; if it never gets through, the server counts it as opened 15
 * minutes after the fetch anyway.
 */
async function confirmOpened(m) {
  const url = m.pic ? `/groups/${m.group_id}/pics/${m.pic.id}/opened` : `/snaps/${m.id}/opened`;
  for (let i = 0; i < 5; i++) {
    try {
      await api(url, { method: "POST" });
      return;
    } catch (err) {
      if (!retryable(err)) return;
      await sleep(2000 * 2 ** i);
    }
  }
  report("warn", "confirming a pic open failed", { message_id: m.id });
}

/** "2 of 3", counting pics that arrive while viewing. Returns how many are left after this one. */
function updateCount() {
  const run = viewer.run;
  const left = run ? waitingPics().filter((m) => !run.seen.has(m.id)).length : 0;
  const total = (run?.seen.size ?? 1) + left;
  $("#viewer-count").textContent = `${run?.seen.size ?? 1} of ${total}`;
  $("#viewer-count").hidden = total < 2;
  return left;
}

/** The viewer is up straight away, saying it's opening, so a slow connection doesn't look like nothing happened. */
function showOpening(from) {
  const v = $("#viewer");
  v.classList.add("opening");
  $("#viewer-error").hidden = true;
  $("#viewer-from").textContent = from;
  $("#viewer-caption").hidden = true;
  updateCount();
  setViewerHint("Opening…");
  v.hidden = false;
}

/** Shows a loaded pic (or plays a video) and starts its timer. True once it's on screen. */
async function showInViewer({ blob, video = false, from, caption = "", y = null }) {
  viewer.url = URL.createObjectURL(blob);
  const v = $("#viewer");
  const img = $("#viewer-image");
  const player = $("#viewer-video");
  let ms = VIEW_MS;
  if (video) {
    if (!await loadVideo(player, viewer.url)) return false;
    if (!viewer.url) return false; // closed while it loaded
    img.hidden = true;
    player.hidden = false;
    // A recorded video may not say how long it is: then it runs to its end,
    // or to the longest a video can be.
    const longest = (state.config?.video_max_seconds ?? 10) * 1000;
    ms = Number.isFinite(player.duration) && player.duration > 0 ? Math.min(player.duration * 1000, longest) : longest;
    player.onended = () => { if (viewer.url) nextPic(); };
    try {
      await player.play();
    } catch {
      player.muted = true; // the browser wants a tap for sound; plays silent rather than not at all
      await player.play().catch(() => {});
    }
  } else {
    img.src = viewer.url;
    try {
      await img.decode();
    } catch {
      return false;
    }
    if (!viewer.url) return false; // closed while it decoded
  }
  v.classList.remove("opening");
  v.classList.toggle("is-video", video);
  $("#viewer-from").textContent = from;
  $("#viewer-caption").textContent = caption;
  $("#viewer-caption").hidden = !caption;
  // Where the sender put it, on the picture itself (X33); else the lower third.
  placeViewerCaption(y);
  const left = updateCount();
  setViewerHint(left ? "Tap for the next one" : "Tap to close");
  v.style.setProperty("--view-ms", `${ms}ms`);
  v.classList.add("running");
  // A video moves on when it ends; this is the backstop if it stalls.
  viewer.timer = setTimeout(nextPic, video ? ms + 3000 : ms);
  viewer.shownAt = Date.now();
  return true;
}

/**
 * Puts the caption on the picture as shown, at `y` (0 top to 1 bottom), kept
 * inside it; a pic sent before there was a `y` has it at 0.8. The strip is drawn by the
 * rule every client follows (stripOnPicture), in the stage's own coordinates,
 * so it zooms with the picture.
 */
const CAPTION_Y = 0.8;
function placeViewerCaption(y) {
  viewer.captionY = y;
  const cap = $("#viewer-caption");
  if (cap.hidden) return;
  const media = $("#viewer-video").hidden ? $("#viewer-image") : $("#viewer-video");
  // The stage's layout before its zoom: offsets, not on-screen rects.
  const r = containedRect(media, media.offsetWidth, media.offsetHeight);
  stripOnPicture(cap, { ...r, left: media.offsetLeft + r.left, top: media.offsetTop + r.top }, y ?? CAPTION_Y);
}
window.addEventListener("resize", () => { if (viewer.url) placeViewerCaption(viewer.captionY); });

/** Loads a video far enough to play. False if it can't be played here. */
function loadVideo(player, url) {
  return new Promise((resolve) => {
    const done = (ok) => {
      player.oncanplay = player.onerror = null;
      resolve(ok);
    };
    player.oncanplay = () => done(true);
    player.onerror = () => done(false);
    player.muted = false;
    player.src = url;
    player.load();
  });
}

/** Something went wrong: say so in the viewer; a tap closes it, and the pic stays unopened. */
function showViewerProblem(text) {
  $("#viewer").classList.remove("opening");
  $("#viewer-error").textContent = text;
  $("#viewer-error").hidden = false;
  setViewerHint("Tap to close");
  viewer.run = null;
}

function clearViewer() {
  clearTimeout(viewer.timer);
  const v = $("#viewer");
  v.classList.remove("running", "opening");
  $("#viewer-error").hidden = true;
  const img = $("#viewer-image");
  img.removeAttribute("src");
  img.hidden = false;
  const player = $("#viewer-video");
  player.onended = null;
  player.pause();
  player.removeAttribute("src");
  player.load();
  player.hidden = true;
  v.classList.remove("is-video");
  resetZoom();
  placeViewerCaption(null);
  if (viewer.url) URL.revokeObjectURL(viewer.url);
  viewer.url = null;
}

function stopViewer() {
  viewer.run = null;
  clearViewer();
  $("#viewer").hidden = true;
  const after = viewer.after; // pics shown from the list: what follows (afterPicsFromList)
  viewer.after = null;
  after?.();
}

/** What the viewer says at its foot; while zoomed in, how to zoom back out. */
function setViewerHint(text) {
  viewer.hint = text;
  $("#viewer-hint").textContent = zoom.s > 1 ? "Tap to zoom out" : text;
}

// ---------- zooming into an opened pic ----------
// Pinch to zoom and drag to pan; on a computer, the wheel or a trackpad pinch
// zooms where the pointer is, and dragging pans. Let go, and it springs back
// within bounds: never smaller than it opened, never more than ZOOM_MAX, and
// no edge pulled in from the screen's. A pinch or a drag is never a tap, so
// it doesn't move on to the next pic; a tap on a zoomed pic zooms back out.
// The pic's timer runs on as it would: zooming doesn't keep it longer.
const ZOOM_MAX = 4;
// The stage's transform is translate(x, y) scale(s), about its center.
const zoom = { s: 1, x: 0, y: 0, pointers: new Map(), from: null, moved: false, gesture: null, tapped: false };

const zoomable = () => !!viewer.url && !$("#viewer").classList.contains("opening");

/** A point on screen, from the viewer's center (where the stage scales from). */
function fromCenter(clientX, clientY) {
  const r = $("#viewer").getBoundingClientRect();
  return { x: clientX - r.left - r.width / 2, y: clientY - r.top - r.height / 2 };
}

function applyZoom(settle = false) {
  const stage = $("#viewer-stage");
  stage.classList.toggle("settling", settle);
  stage.style.transform = zoom.s === 1 && !zoom.x && !zoom.y ? "" : `translate(${zoom.x}px, ${zoom.y}px) scale(${zoom.s})`;
  $("#viewer").classList.toggle("zoomed", zoom.s > 1);
  $("#viewer-hint").textContent = zoom.s > 1 ? "Tap to zoom out" : viewer.hint ?? "";
}

/** Back within bounds (see above). */
function boundZoom() {
  zoom.s = Math.min(ZOOM_MAX, Math.max(1, zoom.s));
  if (zoom.s < 1.02) zoom.s = 1; // all but out is out
  const media = $("#viewer-video").hidden ? $("#viewer-image") : $("#viewer-video");
  const v = $("#viewer");
  const room = (size, view) => Math.max(0, (size * zoom.s - view) / 2);
  // The picture as drawn, not its box: it fills the screen, letterboxed.
  const pic = containedRect(media, media.offsetWidth, media.offsetHeight);
  const rx = room(pic.width, v.clientWidth);
  const ry = room(pic.height, v.clientHeight);
  zoom.x = Math.min(rx, Math.max(-rx, zoom.x));
  zoom.y = Math.min(ry, Math.max(-ry, zoom.y));
}

/** Scales by `k` about `at` (from the center), keeping what's under it there. */
function zoomAbout(at, k, from = zoom) {
  const s = from.s * k;
  zoom.x = at.x - ((at.x - from.x) / from.s) * s;
  zoom.y = at.y - ((at.y - from.y) / from.s) * s;
  zoom.s = s;
}

function resetZoom() {
  zoom.s = 1;
  zoom.x = zoom.y = 0;
  zoom.pointers.clear();
  zoom.from = zoom.gesture = null;
  $("#viewer").classList.remove("dragging");
  applyZoom();
}

/** Where every finger (or the mouse) is now, as the gesture's starting point. */
function zoomBaseline() {
  const pts = [...zoom.pointers.values()];
  zoom.from = { s: zoom.s, x: zoom.x, y: zoom.y, pts: pts.map((p) => ({ ...p })) };
}

const midpoint = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

const viewerEl = $("#viewer");
viewerEl.addEventListener("pointerdown", (e) => {
  // The first finger of a new touch: any left from before lost their lift (a touch that
  // ended off the screen, an interruption), and would make this tap look like a pinch.
  if (e.isPrimary) zoom.pointers.clear();
  zoom.tapped = false; // a click that never came for the last tap mustn't swallow this one's
  if (!zoom.pointers.size) zoom.moved = false; // a new touch: a tap until it moves
  if (!zoomable() || (e.pointerType === "mouse" && e.button !== 0)) return;
  zoom.pointers.set(e.pointerId, fromCenter(e.clientX, e.clientY));
  if (zoom.pointers.size > 1) zoom.moved = true; // a second finger is a pinch, never a tap
  try {
    viewerEl.setPointerCapture?.(e.pointerId);
  } catch { /* a pointer the browser no longer tracks: nothing to capture */ }
  $("#viewer-stage").classList.remove("settling");
  zoomBaseline();
});
viewerEl.addEventListener("pointermove", (e) => {
  if (!zoom.pointers.has(e.pointerId) || !zoom.from) return;
  zoom.pointers.set(e.pointerId, fromCenter(e.clientX, e.clientY));
  const now = [...zoom.pointers.values()];
  const was = zoom.from.pts;
  if (now.length >= 2 && was.length >= 2) {
    // Pinch: scaled by how far apart the fingers are, about where they are.
    const k = distance(now[0], now[1]) / Math.max(1, distance(was[0], was[1]));
    const mid = midpoint(now[0], now[1]);
    const before = midpoint(was[0], was[1]);
    zoomAbout(before, k, zoom.from);
    zoom.x += mid.x - before.x;
    zoom.y += mid.y - before.y;
    // A little give past the limits while held; it springs back on letting go.
    zoom.s = Math.min(ZOOM_MAX * 1.5, Math.max(0.6, zoom.s));
  } else {
    const dx = now[0].x - was[0].x;
    const dy = now[0].y - was[0].y;
    if (!zoom.moved && Math.hypot(dx, dy) < 8) return; // still a tap
    zoom.moved = true;
    if (zoom.from.s <= 1) return; // nothing to pan
    viewerEl.classList.add("dragging");
    zoom.x = zoom.from.x + dx;
    zoom.y = zoom.from.y + dy;
  }
  applyZoom();
});
function zoomPointerEnd(e) {
  if (!zoom.pointers.delete(e.pointerId)) return;
  if (zoom.pointers.size) return zoomBaseline(); // fingers left: go on from here
  viewerEl.classList.remove("dragging");
  zoom.from = null;
  boundZoom();
  applyZoom(true);
  // A finger (or the mouse) let go where it came down: a tap, decided here rather than by
  // the click a browser may or may not send after it (some don't, after a touch), which is then ignored.
  if (e.type === "pointerup" && !zoom.moved) {
    zoom.tapped = true;
    viewerTap();
  }
}
viewerEl.addEventListener("pointerup", zoomPointerEnd);
viewerEl.addEventListener("pointercancel", zoomPointerEnd);

// The wheel, and a trackpad pinch (which browsers send as the wheel with Ctrl).
viewerEl.addEventListener("wheel", (e) => {
  if (viewerEl.hidden) return;
  e.preventDefault(); // never the page's zoom or scroll behind
  if (!zoomable() || zoom.pointers.size) return;
  const lines = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
  const k = Math.exp(-e.deltaY * lines * (e.ctrlKey ? 0.01 : 0.002));
  $("#viewer-stage").classList.remove("settling");
  zoomAbout(fromCenter(e.clientX, e.clientY), k);
  boundZoom();
  applyZoom();
}, { passive: false });

// Safari: a trackpad pinch comes as gesture events (and on an iPhone, a pinch
// would zoom the page): the stage zooms instead. On a touch screen the
// pointers above already do it.
viewerEl.addEventListener("gesturestart", (e) => {
  e.preventDefault();
  zoom.gesture = zoom.pointers.size || !zoomable() ? null : { s: zoom.s, x: zoom.x, y: zoom.y, at: fromCenter(e.clientX, e.clientY) };
});
viewerEl.addEventListener("gesturechange", (e) => {
  e.preventDefault();
  if (!zoom.gesture || zoom.pointers.size) return;
  zoomAbout(zoom.gesture.at, e.scale, zoom.gesture);
  boundZoom();
  applyZoom();
});
viewerEl.addEventListener("gestureend", (e) => {
  e.preventDefault();
  zoom.gesture = null;
});

/** A tap on the viewer: zoomed in, it zooms out; otherwise the next pic (or closing). */
function viewerTap() {
  if (zoom.s > 1) {
    zoom.s = 1;
    zoom.x = zoom.y = 0;
    applyZoom(true);
    return;
  }
  nextPic();
}
viewerEl.addEventListener("click", () => {
  if (zoom.tapped) return void (zoom.tapped = false); // already taken as a tap as the finger lifted
  if (zoom.moved) return; // the end of a pinch or a drag, not a tap
  viewerTap(); // a tap the pointer events didn't follow (a video, or a keyboard's click)
});
$("#viewer").addEventListener("contextmenu", (e) => e.preventDefault());
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("#viewer").hidden) stopViewer();
});

// Keep relative timestamps fresh.
setInterval(() => { if (state.me) renderChatList(); }, 60_000);

// ---------- boot ----------

/** A short, one-way tag of the session token: which session the kept "me" belongs to. */
async function tokenTag(token) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)));
  return [...digest.slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Signs in from what was kept, if this device still holds that account's key. */
async function loadIdentityFor(me) {
  state.me = me;
  if (await loadIdentity()) return true;
  state.me = null;
  return false;
}

(async function boot() {
  // The settings as kept last time (X31), if the server is slow to say.
  const keptConfig = await cache.get("config");
  const fresh = fetch("/api/config").then((r) => r.json()).then((c) => {
    cache.put("config", c);
    state.config = c; // the server's, whenever it arrives
    renderPasskeySignIn(); // a kept copy may be from before passkeys
    return c;
  });
  fresh.catch(() => {});
  try {
    state.config = keptConfig ? await Promise.race([fresh, sleep(1500).then(() => keptConfig)]) : await fresh;
  } catch {
    state.config = keptConfig ?? { invite_required: false };
  }
  APP_NAME = withEnvironment(APP_NAME, state.config);
  document.title = APP_NAME;
  markEnvironment(state.config);
  await readInviteLink();
  if (state.token) {
    // Opened before: start from who you were, as kept, while the server
    // confirms (an ended session still signs out when it answers).
    const tag = await tokenTag(state.token);
    const kept = await cache.get("me");
    if (kept?.tag === tag && kept.me && await loadIdentityFor(kept.me)) {
      enterApp();
      offerInvite();
      getJSON("/me").then((me) => {
        if (!state.me || state.me.id !== me.id) return;
        state.me = me;
        cache.put("me", { tag, me });
        renderAccountBar();
      }).catch((err) => report("debug", "confirming me failed", errorFields(err)));
      return;
    }
    try {
      state.me = await getJSON("/me");
      cache.put("me", { tag, me: state.me });
      // A session without its key (cleared site data, another account) can't
      // read anything, so start over with the password.
      if (await loadIdentity()) {
        enterApp();
        offerInvite();
        return;
      }
    } catch {
      // fall through to sign in
    }
    await signOutLocally();
    return;
  }
  // Signed out, nothing of anyone's should be here: what an older napsack
  // left (the pins it kept at sign-out, before 2026-11-06), or what a tab
  // still wrote as another signed out. Only the public settings stay.
  leftovers = Promise.allSettled([dropDatabases({ except: [cache.DB_NAME] }), cache.keepOnly((k) => k === "config")]);
  showAuth();
  showInviteBanner();
  // Why the last session ended, carried across signing out's reload.
  try {
    const notice = sessionStorage.getItem(SIGNED_OUT_NOTICE_KEY);
    sessionStorage.removeItem(SIGNED_OUT_NOTICE_KEY);
    if (notice) $("#auth-error").textContent = notice;
  } catch { /* nothing to say, then */ }
})();
