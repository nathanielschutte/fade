// napsack web client. Plain ES module: no framework, no build step.
// Every API call here is what the future mobile app will make too.
// Texts and snaps are encrypted here before upload; see crypto.js.

import * as e2e from "/crypto.js";
import * as keystore from "/keystore.js";
import { qrSvg } from "/qr.js";
import { markEnvironment, withEnvironment } from "/env.js";
import { createDrawing } from "/draw.js";
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
  readKeys: new Map(),         // friend id -> chat keys for reading: pinned, then past
  reactionText: new Map(),     // reaction cache key -> decrypted emoji, or null
  actionFor: null,             // "d:<id>" or "g:<id>": the message whose reaction/reply row is open
  replyTo: null,               // { group, id, who, snippet } while composing a reply
  typing: new Map(),           // "d:<friend>" or "g:<group>:<user>" -> when the "typing" hint ends
  invite: null,                // { token, inviter, problem } from an /i/<token> link
  pairKeys: new Map(),         // friend id -> AES key shared with them
  plaintext: new Map(),        // message id -> decrypted text, or null if it couldn't be
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
// outbox does that, with ids that make a resend safe. `as: "json"` or
// `as: "bytes"` reads the body inside the same time limit.
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
        signOutLocally();
        throw new ApiError("Your session ended. Sign in again.", 401);
      }

      if (!res.ok) {
        let msg = `Request failed (${res.status}).`;
        try { msg = (await res.json()).error || msg; } catch {}
        throw new ApiError(msg, res.status);
      }

      let out = res;
      if (as === "json") out = await res.json();
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
  
  if (state.activeId === chat.id) openChat(chat.id);
}

/** Keys that can read this chat's messages: the pinned key, then any I accepted before it. */
async function readKeysFor(friendId) {
  const cached = state.readKeys.get(friendId);
  if (cached) return cached;
  if (!chatById(friendId)) await refreshChats();
  const pinned = state.pins[friendId] || chatById(friendId)?.public_key;
  if (!pinned) throw new Error("Not a friend.");
  const publics = [pinned, ...[...(state.pastPins[friendId] || [])].reverse()];
  const keys = await Promise.all(publics.map((pub) => e2e.pairKey(state.identity.privateKey, pub, state.me.id, friendId)));
  state.readKeys.set(friendId, keys);
  return keys;
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
  const cached = state.pairKeys.get(friendId);
  if (cached) return cached;
  if (!chatById(friendId)) await refreshChats();
  const chat = chatById(friendId);
  if (!chat) throw new Error("Not a friend.");
  if (chat.keyChanged) throw new Error(`${chat.username}'s safety code changed. Messages are blocked.`);
  const key = await e2e.pairKey(state.identity.privateKey, chat.public_key, state.me.id, friendId);
  state.pairKeys.set(friendId, key);
  return key;
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
  m.replyTo = body?.replyTo ?? null;
  m.beforeReset = m.text == null && beforeMyReset(m);
  return m;
}

/** Reactions are encrypted too, bound to the message they're on. */
async function decryptReactions(m) {
  const out = [];
  for (const r of m.reactions || []) {
    const cacheKey = `${m.id}:${r.sender_id}:${r.created_at}`;
    if (!state.reactionText.has(cacheKey)) {
      let emoji = null;
      try {
        const to = r.sender_id === state.me.id ? friendOf(m) : state.me.id;
        emoji = await withReadKey(friendOf(m), (k) => e2e.decryptReaction(k, r.ciphertext, r.sender_id, to, m.id));
      } catch {
        // unreadable reactions are just not shown
      }
      state.reactionText.set(cacheKey, e2e.REACTIONS.includes(emoji) ? emoji : null);
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
  await loadPins();
  return true;
}

// ---------- auth ----------

let authMode = "login";

function showAuth() {
  $("#app").hidden = true;
  $("#auth").hidden = false;
  showRecover(false);
  setAuthMode("login");
}

function setAuthMode(mode) {
  authMode = mode;
  const register = mode === "register";
  $("#auth-submit").textContent = register ? "Create account" : "Sign in";
  $("#auth-toggle").textContent = register
    ? "Have an account? Sign in"
    : "New here? Create an account";
  $("#invite-field").hidden = !(register && state.config?.invite_required && !state.invite?.inviter);
  $("#password-hint").hidden = !register;
  $("#auth-form").password.autocomplete = register ? "new-password" : "current-password";
  $("#auth-error").textContent = "";
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
    if (recoveryKey) await showRecoveryKey(recoveryKey);
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

/** Shows the key until the person says they saved it. */
function showRecoveryKey(recoveryKey) {
  const dialog = $("#recovery-dialog");
  $("#recovery-key").textContent = recoveryKey;
  $("#recovery-saved").checked = false;
  $("#recovery-done").disabled = true;
  $("#recovery-copy").textContent = "Copy";
  dialog.showModal();
  return new Promise((resolve) => dialog.addEventListener("close", () => {
    $("#recovery-key").textContent = ""; // don't leave it in the page
    resolve();
  }, { once: true }));
}

$("#recovery-saved").addEventListener("change", (e) => { $("#recovery-done").disabled = !e.target.checked; });
$("#recovery-done").addEventListener("click", () => $("#recovery-dialog").close());
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
  $("#password-form").reset();
  $("#password-error").textContent = "";
  $("#password-title").textContent = change ? "Change password" : "Recovery key";
  $("#password-text").textContent = change
    ? "Your messages stay readable: your key is locked again under the new password. Other devices will be signed out."
    : state.me.has_recovery_key
      ? "Making a new recovery key replaces your old one, which stops working. Enter your password to continue."
      : "Enter your password to make a recovery key.";
  $("#password-new-field").hidden = !change;
  $("#password-confirm-field").hidden = !change;
  $("#password-submit").textContent = change ? "Change password" : "Make a recovery key";
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

async function renderSecurity() {
  $("#share-activity").checked = Boolean(state.me.share_activity);
  renderPushStatus();
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

function signOutLocally() {
  state.token = null;
  state.me = null;
  clearNotifications(); // they name friends; not for whoever uses the device next
  for (const d of document.querySelectorAll("dialog[open]")) d.close();
  state.loaded = { chats: false, groups: false, error: null };
  state.loadFailed.clear();
  state.identity = null;
  state.pins = {};
  state.pastPins = {};
  state.readKeys.clear();
  state.readUpTo.clear();
  state.pairKeys.clear();
  state.plaintext.clear();
  state.activeId = null;
  state.messages.clear();
  state.history.clear();
  state.groups = [];
  state.activeGroupId = null;
  state.groupMessages.clear();
  state.groupReads.clear();
  state.groupHistory.clear();

  localStorage.removeItem(TOKEN_KEY);

  // IndexedDB napsack bucket - delete "identity"
  keystore.deleteLocal(IDENTITY_KEY).catch(() => {});
  
  const ws = state.ws;
  state.ws = null;
  ws?.close();
  clearInterval(conn.heartbeat);
  clearTimeout(conn.pongTimer);
  setConnBanner(null);
  outbox.length = 0; // unsent texts were this account's
  $("#friends-dialog").close();
  showAuth();
}

$("#sign-out").addEventListener("click", async () => {
  try { await api("/auth/logout", { method: "POST" }); } catch {}
  signOutLocally();
});

// ---------- app shell ----------

function enterApp() {
  $("#auth").hidden = true;
  $("#app").hidden = false;
  renderAccountBar();
  // System (the admin panel) is for PowerUsers and Admins (roles.md); the server checks again.
  $("#admin-link").hidden = !(state.me.role === "power" || state.me.role === "admin" || state.me.is_admin);
  $("#profile-admin-link").hidden = $("#admin-link").hidden;
  showTab("chats");
  syncPush();
  clearNotifications();
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
  $("#my-name").textContent = personName(state.me.id);
  paintAvatar($("#my-avatar"), state.me);
  paintAvatar($("#tab-avatar"), state.me);
  $("#recovery-nudge").hidden = Boolean(state.me.has_recovery_key);
  renderPushNudge();
}

/** My display name or picture may have changed in another tab. */
async function refreshMe() {
  try {
    state.me = await getJSON("/me");
  } catch (err) {
    report("warn", "loading me failed", errorFields(err));
    return;
  }
  renderAccountBar();
}

async function refreshChats() {
  try {
    const chats = await getJSON(`/friends?tz=${tzOffset()}`);
    await checkPins(chats);
    state.chats = chats;
    await Promise.all(chats.map((c) => c.last_message && decrypt(c.last_message)));
    state.loaded.chats = true;
    state.loaded.error = null;
  } catch (err) {
    report("warn", "loading chats failed", errorFields(err));
    state.loaded.error = err.message;
    renderChatList();
    return;
  }
  if (!state.me) return; // signed out while it loaded (an ended session, an account turned off)
  renderChatList();
  renderChatHeader();
  if (state.activeId && !chatById(state.activeId)) closeChat(); // unfriended
  else if (state.activeId) renderMessages(); // sender names follow renames
}

let refreshTimer = null;
function refreshChatsSoon() {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refreshChats, 150);
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
    if (!mine && m.snap_state === "pending") return { text: "New pic", marker: "snap" };
    const label = mine
      ? { pending: "Sent a pic", opened: "Pic opened", expired: "Pic expired unopened" }
      : { opened: "Pic viewed", expired: "Pic expired" };
    return { text: label[m.snap_state] || "Pic" };
  }
  const body = m.text ?? "Encrypted message";
  if (!mine && !m.read_at) return { text: body, marker: "text" };
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
// just a click. Phones wait a moment first (`tapOnPhone`).
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

function disarmCameraTap() {
  clearTimeout(cameraTap.timer);
  if (cameraTap.up) document.removeEventListener("pointerup", cameraTap.up, true);
  if (cameraTap.click) document.removeEventListener("click", cameraTap.click, true);
  cameraTap.up = cameraTap.click = null;
}

function chatRow({ name, status, time, current, onclick, group, avatar, actions = [], muted = false }) {
  const cls = ["chat-item"];
  // Muted: no unread dot or bold, and a 🔕 by the name.
  if (muted) {
    status = { ...status, marker: null };
    name = `${name} 🔕`;
    cls.push("is-muted");
  }
  if (status.marker === "snap") cls.push("has-unread", "has-snap");
  else if (status.marker === "text") cls.push("has-unread");
  if (group) cls.push("is-group");
  // While a row is swiped open, a tap anywhere on the list just closes it.
  const open = (e) => {
    if (rowSwipe.open) return closeSwipedRow();
    if (e.detail > 0 && !wideLayout.matches) return tapOnPhone(e.currentTarget, `${group ? "g" : "d"}:${name}`, onclick, e);
    const opening = onclick();
    if (e.detail > 0) armCameraTap(opening, e); // a tap or click, not the keyboard
  };
  return el("li", { class: "chat-row" },
    el("button", { type: "button", class: cls.join(" "), "aria-current": current ? "true" : null, onclick: open },
      el("span", { class: `marker ${status.marker || ""}`, "aria-hidden": "true" }),
      avatar,
      el("span", { class: "chat-text" },
        group ? el("span", { class: "visually-hidden", text: "Group: " }) : null,
        el("span", { class: "chat-name", text: name }),
        el("span", { class: "chat-status", text: preview(status.text) })),
      el("span", { class: "chat-time", text: time ? relTime(time) : "" }),
    ),
    actions.length ? el("div", { class: "row-actions" }, ...actions.map((a) =>
      el("button", { type: "button", class: `row-action ${a.cls ?? ""}`, "aria-label": a.aria, title: a.aria, onclick: a.run },
        rowIcon(a.icon), el("span", { class: "row-action-label", text: a.label })))) : null);
}

// Row action icons. A computer shows just these (small, over the time); a
// phone shows the words behind the swiped row.
const ROW_ICONS = {
  star: "M12 3.5l2.6 5.3 5.9.9-4.25 4.1 1 5.85L12 16.9l-5.25 2.75 1-5.85L3.5 9.7l5.9-.9z",
  archive: "M4 6.5h16v3.5H4zM5.5 10v8.5h13V10M10 13.5h4",
  leave: "M14 4.5h4.5v15H14M10 8l-4 4 4 4M6 12h9",
  bell: "M6.5 16.5V11a5.5 5.5 0 0 1 9-4.25M17.5 10.5v6l1.5 1.5H8.5M10 20.5a2 2 0 0 0 4 0M4 4l16 16",
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

/** Favorites first, then everything else, each newest first. Hidden direct
 * chats sit out of the list behind a "Hidden chats" link. */
function renderChatList() {
  if (!state.me) return;
  const entries = [
    ...state.chats.map((chat) => ({
      at: chat.last_message?.created_at ?? 0,
      name: chatName(chat),
      favorite: chat.favorite,
      hidden: chat.hidden,
      row: chatRow({
        name: chatRowName(chat),
        status: isTyping(`d:${chat.id}`) ? { text: "typing…" } : chatStatus(chat),
        time: chat.last_message?.created_at,
        current: chat.id === state.activeId, onclick: () => openChat(chat.id),
        avatar: el("span", { class: `avatar-wrap ${chat.active_now ? "online" : ""}` },
          paintAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), chat)),
        muted: chat.muted,
        actions: chat.hidden
          ? [{ label: "Unhide", icon: "archive", aria: `Show your chat with ${chatName(chat)} again`, run: () => unhideChat(chat.id) }]
          : [favoriteAction(chat, chatName(chat), () => setFavorite("chats", chat.id, !chat.favorite)),
            muteAction("chats", chat, chatName(chat)),
            { label: "Hide", icon: "archive", aria: `Hide your chat with ${chatName(chat)}`, run: () => hideChat(chat.id) }],
      }),
      search: `${chatName(chat)} ${chat.username}`.toLowerCase(),
    })),
    ...state.groups.map((g) => ({
      at: g.last_message?.created_at ?? 0,
      name: g.name,
      favorite: g.favorite,
      hidden: false,
      row: chatRow({
        name: g.name, status: groupStatus(g), time: g.last_message?.created_at, group: true,
        current: g.id === state.activeGroupId, onclick: () => openGroup(g.id),
        avatar: el("span", { class: "avatar-wrap" },
          paintGroupAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), g)),
        muted: g.muted,
        actions: [favoriteAction(g, g.name, () => setFavorite("groups", g.id, !g.favorite)),
          muteAction("groups", g, g.name),
          { label: "Leave", icon: "leave", cls: "danger", aria: `Leave ${g.name}`, run: (e) => leaveFromList(e.currentTarget, g) }],
      }),
      search: g.name.toLowerCase(),
    })),
  ].sort((a, b) => b.at - a.at || a.name.localeCompare(b.name));

  const heading = (text) => el("li", { class: "list-heading", text });
  const items = [];
  const q = state.search.q.trim().toLowerCase();
  if (q) {
    // Searching: chats whose name matches (hidden ones too), then messages that do.
    const named = entries.filter((e) => e.search.includes(q));
    items.push(heading("Chats"), ...(named.length ? named.map((e) => e.row) : [el("li", { class: "search-note", text: "No chats by that name." })]));
    if (q.length >= 2) items.push(heading("Messages"), ...searchResults(q));
  }
  const shown = q ? [] : entries.filter((e) => !e.hidden);
  const favorites = shown.filter((e) => e.favorite);
  const rest = shown.filter((e) => !e.favorite);
  const hidden = q ? [] : entries.filter((e) => e.hidden);
  if (favorites.length) items.push(heading("Favorites"), ...favorites.map((e) => e.row), heading("Chats"));
  items.push(...rest.map((e) => e.row));
  if (hidden.length) {
    items.push(el("li", { class: "hidden-toggle" }, el("button", {
      type: "button", class: "link", "aria-expanded": state.showHidden ? "true" : "false",
      onclick: () => { state.showHidden = !state.showHidden; renderChatList(); },
    }, state.showHidden ? "Hide hidden chats" : `Hidden chats (${hidden.length})`)));
    if (state.showHidden) items.push(...hidden.map((e) => e.row));
  }
  rowSwipe.open = null;
  $("#chat-list").replaceChildren(...items);
  // Until both lists have answered, an empty list means "not here yet", not "no friends".
  const loaded = state.loaded.chats && state.loaded.groups;
  $("#chat-empty").hidden = entries.length > 0 || !loaded;
  if (!loaded && !entries.length) {
    $("#chat-list").replaceChildren(...(state.loaded.error
      ? [el("li", { class: "list-problem" },
        el("p", { text: `Couldn't load your chats. ${state.loaded.error}` }),
        el("button", { type: "button", class: "button", onclick: () => { state.loaded.error = null; renderChatList(); refreshChats(); refreshGroups(); } }, "Try again"))]
      : Array.from({ length: 5 }, () => el("li", { class: "skeleton-row", "aria-hidden": "true" },
        el("span", { class: "skeleton-dot" }), el("span", { class: "skeleton-lines" }, el("span"), el("span"))))));
    $("#chat-list").setAttribute("aria-busy", state.loaded.error ? "false" : "true");
    return;
  }
  $("#chat-list").setAttribute("aria-busy", "false");
  const unread = state.chats.reduce((n, c) => n + (c.hidden || c.muted ? 0 : c.unread), 0)
    + state.groups.reduce((n, g) => n + (g.muted ? 0 : g.unread), 0);
  document.title = unread ? `(${unread}) ${APP_NAME}` : APP_NAME;
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
  state.messages.delete(friendId);
  state.history.delete(friendId);
  state.typing.delete(`d:${friendId}`);
}

/** Leaving from the list takes two taps, like the group's info sheet. */
async function leaveFromList(btn, g) {
  if (!btn.dataset.confirm) {
    btn.dataset.confirm = "1";
    btn.querySelector(".row-action-label").textContent = "Tap to leave";
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
  return item.muted
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
const searchCache = new Map(); // "d:<id>" or "g:<id>" -> { at, msgs }
let searchTimer = null;

$("#chat-search").addEventListener("input", (e) => {
  state.search = { q: e.target.value, hits: null };
  renderChatList();
  clearTimeout(searchTimer);
  const q = e.target.value.trim();
  if (q.length >= 2) searchTimer = setTimeout(() => runSearch(q), 250);
});
$("#chat-search").addEventListener("keydown", (e) => {
  if (e.key === "Escape") clearSearch();
});

function clearSearch() {
  $("#chat-search").value = "";
  state.search = { q: "", hits: null };
  renderChatList();
}

async function searchHistory(src) {
  const cached = searchCache.get(src.key);
  if (cached && Date.now() - cached.at < 60_000) return cached.msgs;
  const msgs = await getJSON(src.url);
  await Promise.all(msgs.map(src.decrypt));
  searchCache.set(src.key, { at: Date.now(), msgs });
  return msgs;
}

async function runSearch(q) {
  const needle = q.toLowerCase();
  const sources = [
    ...state.chats.map((c) => ({
      key: `d:${c.id}`, name: chatName(c), open: () => openChat(c.id),
      url: `/chats/${c.id}/messages?limit=${SEARCH_DEPTH}`, decrypt, text: (m) => (m.kind === "text" ? m.text : null),
    })),
    ...state.groups.map((g) => ({
      key: `g:${g.id}`, name: g.name, open: () => openGroup(g.id),
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

/** The "Messages" part of the list while searching. */
function searchResults(q) {
  const hits = state.search.hits;
  if (!hits) return [el("li", { class: "search-note", text: "Looking through your messages…" })];
  if (!hits.length) return [el("li", { class: "search-note", text: "No messages with that in the last 200 of each chat." })];
  return hits.map((h) => {
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
  });
}

/** Opens the chat and, if the message is in what's loaded, brings it into view. */
async function openHit(h) {
  await h.src.open();
  const li = $(`#messages [data-key="${h.src.key[0]}:${h.m.id}"]`);
  if (!li) return;
  li.scrollIntoView({ block: "center" });
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
  rowSwipe.open = null;
}

// ---------- conversation ----------

async function openChat(friendId) {
  const chat = chatById(friendId);
  if (!chat) return;
  if (chat.hidden) unhideChat(friendId); // opening a hidden chat brings it back
  if (state.activeId !== friendId) {
    setReply(null);
    state.actionFor = null;
  }
  state.activeId = friendId;
  state.activeGroupId = null;
  setConversationMode("direct");
  $("#app").classList.add("in-chat");
  closeProfileTab();
  $("#chat-placeholder").hidden = true;
  $("#chat").hidden = false;
  const switching = $("#messages").dataset.friend !== String(friendId);
  if (switching) {
    $("#messages").dataset.friend = String(friendId);
    delete $("#messages").dataset.scrolled; // a newly opened chat starts at the bottom
  }
  renderChatHeader();
  renderChatList();
  renderMessages();
  try {
    const page = await getJSON(`/chats/${friendId}/messages?limit=${PAGE}`);
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
      state.history.set(friendId, { hasMore: page.length === PAGE, loading: false });
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
  if (matchMedia("(min-width: 760px)").matches) $("#composer-input").focus();
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
  const sub = [activeText(chat), chatName(chat) !== chat.username ? `@${chat.username}` : ""].filter(Boolean);
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

/** Loads the page before the oldest loaded message, keeping the view in place. */
async function loadOlder(friendId) {
  const msgs = state.messages.get(friendId);
  const h = state.history.get(friendId);
  if (!msgs?.length || !h?.hasMore || h.loading) return;
  h.loading = true;
  renderMessages();
  try {
    const page = await getJSON(`/chats/${friendId}/messages?before=${msgs[0].id}&limit=${PAGE}`);
    await Promise.all(page.map(decrypt));
    const have = new Set(msgs.map((m) => m.id));
    msgs.unshift(...page.filter((m) => !have.has(m.id)));
    h.hasMore = page.length === PAGE;
  } catch (err) {
    report("warn", "loading older messages failed", { friend_id: friendId, ...errorFields(err) });
  } finally {
    h.loading = false;
  }
  if (state.activeId !== friendId) return;
  const list = $("#messages");
  const fromBottom = list.scrollHeight - list.scrollTop;
  renderMessages();
  list.scrollTop = list.scrollHeight - fromBottom;
  fillViewport(friendId);
}

/** A short history that doesn't fill the screen can't be scrolled, so keep loading. */
function fillViewport(friendId) {
  const list = $("#messages");
  if (state.activeId === friendId && list.scrollHeight <= list.clientHeight + 40) loadOlder(friendId);
}

$("#messages").addEventListener("scroll", () => {
  if ($("#messages").scrollTop >= 200) return;
  if (state.activeId) loadOlder(state.activeId);
  else if (state.activeGroupId) loadOlderGroup(state.activeGroupId);
});

async function markRead(friendId) {
  const chat = chatById(friendId);
  const hasUnreadText = (state.messages.get(friendId) || [])
    .some((m) => m.sender_id === friendId && m.kind === "text" && !m.read_at);
  if (!hasUnreadText && !(chat && chat.unread)) return;
  try {
    await api(`/chats/${friendId}/read`, { method: "POST" });
  } catch (err) {
    report("warn", "marking read failed", { friend_id: friendId, ...errorFields(err) });
  }
}

function snapLabel(m, mine) {
  if (mine) {
    return { pending: "Pic sent", opened: "Opened", expired: "Expired unopened" }[m.snap_state];
  }
  return { opened: "Viewed", expired: "Expired" }[m.snap_state];
}

function renderMessages() {
  if (state.activeGroupId) return renderGroupMessages();
  const list = $("#messages");
  const msgs = state.messages.get(state.activeId) || [];
  const chat = chatById(state.activeId);
  const nearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 80;

  // "Seen" goes under my latest text if they've read it.
  let lastMineTextId = null;
  for (const m of msgs) if (m.sender_id === state.me.id && m.kind === "text") lastMineTextId = m.id;

  const items = [];
  const h = state.history.get(state.activeId);
  if (msgs.length && h) {
    if (h.loading) items.push(el("li", { class: "msg-meta history-edge", text: "Loading earlier messages…" }));
    else if (!h.hasMore) items.push(el("li", { class: "msg-meta history-edge", text: `This is the beginning of your chat with ${chat ? chatName(chat) : "them"}.` }));
  }
  let prevSender = null;
  for (const m of msgs) {
    const mine = m.sender_id === state.me.id;
    if (m.sender_id !== prevSender) {
      items.push(el("li", {
        class: `sender ${mine ? "mine" : ""}`,
        text: `${mine ? "Me" : chat ? chatName(chat) : ""}  ${clockTime(m.created_at)}`,
      }));
      prevSender = m.sender_id;
    }
    if (m.kind === "text") {
      if (m.text == null) {
        items.push(el("li", {
          class: `msg undecryptable ${mine ? "mine" : ""}`,
          text: m.unsupported ? "Sent from a newer version of napsack. Reload to read it."
            : m.beforeReset ? "Sent before your account was reset, so it can't be read."
            : "Couldn't decrypt this message.",
        }));
      } else {
        items.push(...bubble(m, mine, [el("span", { class: "msg-body", text: m.text })]));
      }
      if (m.id === lastMineTextId && m.read_at) {
        items.push(el("li", { class: "msg-meta", text: "Seen" }));
      }
    } else {
      const canOpen = !mine && m.snap_state === "pending";
      const chip = canOpen
        ? el("button", { type: "button", class: "snap-chip", onclick: () => openPics(m) },
            el("span", { class: "marker snap", "aria-hidden": "true" }), "Tap to view pic")
        : el("span", { class: "snap-chip done" },
            el("span", { class: "marker", "aria-hidden": "true" }), snapLabel(m, mine));
      items.push(...bubble(m, mine, [chip]));
    }
  }
  const sending = outboxItems(`d:${state.activeId}`, prevSender);
  items.push(...sending);
  if (!msgs.length && !sending.length) items.push(...emptyChat(state.messages.has(state.activeId), `d:${state.activeId}`));
  list.replaceChildren(...items);
  if (nearBottom || !list.dataset.scrolled) {
    list.scrollTop = list.scrollHeight;
    list.dataset.scrolled = "1";
  }
}

/** What an empty chat shows: placeholders while its first page loads, a way
 * to try again if it couldn't, and "No messages yet." only once it's known. */
function emptyChat(loaded, key) {
  if (loaded) return [el("li", { class: "msg-meta", text: "No messages yet." })];
  const failed = state.loadFailed.get(key);
  if (failed) {
    return [el("li", { class: "msg-meta list-problem" },
      el("p", { text: `Couldn't load this chat. ${failed}` }),
      el("button", { type: "button", class: "button", onclick: () => {
        state.loadFailed.delete(key);
        if (key.startsWith("g:")) openGroup(Number(key.slice(2))); else openChat(Number(key.slice(2)));
      } }, "Try again"))];
  }
  return [0, 1, 2, 3].map((i) => el("li", { class: `msg-skeleton ${i % 2 ? "mine" : ""}`, "aria-hidden": "true" }));
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
  const i = msgs.findIndex((x) => x.id === m.id);
  if (i >= 0) msgs[i] = m;
  else msgs.push(m);
  msgs.sort((a, b) => a.id - b.id);
}

$("#composer").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("#composer-input");
  const text = input.value.trim();
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
const outbox = []; // { key: "d:<friend>" | "g:<group>", clientId, text, replyTo, status, error, send, done }

function queueSend(item) {
  outbox.push(item);
  attemptSend(item);
}

async function attemptSend(item) {
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

function settleSend(item) {
  const i = outbox.indexOf(item);
  if (i >= 0) outbox.splice(i, 1);
  redrawOutbox(item);
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

/** Texts still on their way, at the bottom of a chat. */
function outboxItems(key, prevSender) {
  const items = outbox.filter((x) => x.key === key);
  const out = [];
  if (items.length && prevSender !== state.me.id) out.push(el("li", { class: "sender mine", text: "Me" }));
  for (const item of items) {
    out.push(el("li", { class: "msg mine pending" }, el("span", { class: "msg-body", text: item.text })));
    if (item.status === "sending") {
      out.push(el("li", { class: "msg-meta", text: "Sending…" }));
      continue;
    }
    const why = retryable(item.error) || !item.error?.message ? "Not sent: no connection." : `Not sent: ${item.error.message}`;
    out.push(el("li", { class: "msg-meta send-failed" }, `${why} `,
      el("button", { type: "button", class: "link", onclick: () => attemptSend(item) }, "Try again"),
      " · ",
      el("button", { type: "button", class: "link", onclick: () => discardSend(item) }, "Remove")));
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
// past which it scrolls inside.
function fitComposer() {
  const input = $("#composer-input");
  input.style.height = "auto";
  input.style.height = `${input.scrollHeight + 2}px`; // + the borders (border-box)
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
  if (m.kind === "snap" || m.pic) return "Pic";
  const text = m.group_id ? m.body : m.text;
  return text ? Array.from(text).slice(0, 80).join("") : "Message";
}

/** Who reacted with what: [{ user, emoji }], whether the chat is encrypted or not. */
const reactionsOf = (m) => (m.group_id ? (m.reactions || []).map((r) => ({ user: r.user_id, emoji: r.emoji })) : m.reactionList || []);
const myReaction = (m) => reactionsOf(m).find((r) => r.user === state.me.id)?.emoji ?? null;

/**
 * A message's list items: the bubble (with the message it replies to, if
 * any), its reactions, and, when tapped, a row to react or reply.
 */
function bubble(m, mine, content) {
  const key = msgKey(m);
  const parts = [];
  const target = replyTarget(m);
  if (target != null) parts.push(quoteFor(m, target));
  parts.push(...content);
  const open = state.actionFor === key;
  const items = [el("li", {
    class: `msg ${mine ? "mine" : ""} ${open ? "has-actions" : ""}`,
    "data-key": key,
    onclick: (e) => {
      if (e.target.closest("button, a")) return;
      state.actionFor = open ? null : key;
      renderMessages();
    },
  }, ...parts)];

  const reactions = reactionsOf(m);
  if (reactions.length) {
    const counts = new Map();
    for (const r of reactions) counts.set(r.emoji, (counts.get(r.emoji) || 0) + 1);
    const me = myReaction(m);
    items.push(el("li", { class: `reactions ${mine ? "mine" : ""}` },
      ...[...counts].map(([emoji, n]) => el("button", {
        type: "button", class: `reaction ${me === emoji ? "is-mine" : ""}`,
        "aria-label": `${emoji} ${n}${me === emoji ? ", including you. Tap to take yours back" : ". Tap to react"}`,
        onclick: () => react(m, emoji),
      }, emoji, n > 1 ? String(n) : ""))));
  }

  if (open) {
    const me = myReaction(m);
    items.push(el("li", { class: `msg-actions ${mine ? "mine" : ""}` },
      ...e2e.REACTIONS.map((emoji) => el("button", {
        type: "button", class: me === emoji ? "is-mine" : "", "aria-label": `React ${emoji}`,
        onclick: () => react(m, emoji),
      }, emoji)),
      el("button", { type: "button", class: "reply-button", onclick: () => startReply(m) }, "Reply")));
  }
  return items;
}

function quoteFor(m, targetId) {
  const msgs = m.group_id ? state.groupMessages.get(m.group_id) : state.messages.get(friendOf(m));
  const target = msgs?.find((x) => x.id === targetId);
  const text = target ? `${whoSent(target)}: ${snippetOf(target)}` : "Replying to an earlier message";
  return el("button", {
    type: "button", class: "quote",
    onclick: () => {
      const key = m.group_id ? `g:${targetId}` : `d:${targetId}`;
      $(`#messages [data-key="${key}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" });
    },
  }, text);
}

/** Same emoji again takes it back; another one replaces it. */
async function react(m, emoji) {
  const next = myReaction(m) === emoji ? null : emoji;
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

function startReply(m) {
  state.actionFor = null;
  setReply({ group: Boolean(m.group_id), id: m.id, who: whoSent(m), snippet: snippetOf(m) });
  renderMessages();
  $("#composer-input").focus();
}

function setReply(reply) {
  state.replyTo = reply;
  $("#reply-bar").hidden = !reply;
  $("#reply-text").textContent = reply ? `Replying to ${reply.who === "You" ? "yourself" : reply.who}: ${reply.snippet}` : "";
}
$("#reply-cancel").addEventListener("click", () => setReply(null));

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

/** `#chat=7`, `#group=3`, `#friends`: where a notification tap leads. */
async function openFromLink(hash) {
  const m = /^#(chat|group)=(\d+)$/.exec(hash) || /^#(friends)$/.exec(hash);
  if (!m) return;
  if (m[1] === "chat") {
    if (!chatById(Number(m[2]))) await refreshChats();
    openChat(Number(m[2]));
  } else if (m[1] === "group") {
    if (!groupById(Number(m[2]))) await refreshGroups();
    openGroup(Number(m[2]));
  } else {
    openFriends();
  }
  history.replaceState(null, "", location.pathname);
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
      setConnBanner(null);
      startHeartbeat();
      flushOutbox();
      sendVisibility();
      checkForUpdate();
      // Anything could have happened while disconnected.
      refreshChats();
      loadAnnouncement();
      refreshGroups();
      refreshRequests();
      if (state.activeId) openChat(state.activeId);
      else if (state.activeGroupId) openGroup(state.activeGroupId);
      break;
    case "auth_failed":
      signOutLocally();
      break;
    case "pong":
      clearTimeout(conn.pongTimer);
      break;
    case "message":
    case "message_updated": {
      const m = ev.message;
      // Their message arrived, so they're done typing (don't wait out the timer).
      if (ev.type === "message" && m.sender_id !== state.me.id) stopTyping(`d:${m.sender_id}`);
      if (ev.type === "message") arrivedFromMe(m, state.plaintext);
      await upsertMessage(m);
      const fid = friendOf(m);
      if (fid === state.activeId) {
        renderMessages();
        if (ev.type === "message" && m.sender_id === fid && m.kind === "text" && document.visibilityState === "visible") {
          markRead(fid);
        }
      }
      refreshChatsSoon();
      break;
    }
    case "read": {
      if (ev.by === state.me.id) {
        refreshChatsSoon();
      } else {
        state.readUpTo.set(ev.by, Math.max(ev.at, state.readUpTo.get(ev.by) ?? 0));
        const msgs = state.messages.get(ev.by) || [];
        for (const m of msgs) {
          if (m.sender_id === state.me.id && m.kind === "text" && !m.read_at && m.created_at <= ev.at) m.read_at = ev.at;
        }
        if (ev.by === state.activeId) renderMessages();
        refreshChatsSoon();
      }
      break;
    }
    case "announcement":
      showAnnouncement(ev.announcement);
      break;
    case "friends_changed":
      await refreshChats();
      await refreshRequests();
      if ($("#group-dialog").open && state.groupDetail) openGroupInfo(state.groupDetail.id);
      refreshMe();
      refreshGroups(); // names in group lists come from the friends list
      if (state.activeGroupId) renderMessages();
      break;
    case "group_message": {
      const m = ev.message;
      stopTyping(`g:${m.group_id}:${m.sender_id}`);
      arrivedFromMe(m, groupPlain);
      await openGroupMessage(m);
      upsertGroupMessage(m);
      if (m.group_id === state.activeGroupId) {
        renderMessages();
        if (m.sender_id !== state.me.id && document.visibilityState === "visible") markGroupRead(m.group_id);
      }
      refreshGroupsSoon();
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
      const chat = chatById(ev.user_id);
      if (chat) {
        chat.active_now = ev.active;
        chat.last_seen_at = ev.last_seen_at;
        if (ev.active === false) state.typing.delete(`d:${ev.user_id}`);
        renderChatList();
        if (state.activeId === chat.id) renderChatHeader();
      }
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
    case "groups_changed": {
      groupMemberKeys.delete(ev.group_id);
      const members = groupById(ev.group_id)?.member_count;
      await refreshGroups();
      // Someone joined or left: "Seen by" needs the new member list.
      if (ev.group_id === state.activeGroupId && groupById(ev.group_id)?.member_count !== members) loadGroupReads(ev.group_id);
      if (ev.group_id === state.activeGroupId) renderGroupHeader();
      if ($("#group-dialog").open && state.groupDetail?.id === ev.group_id) openGroupInfo(ev.group_id);
      break;
    }
  }
}

// ---------- groups ----------
// Group messages and pics are end-to-end encrypted (format 3,
// docs/implementation/group-encryption.md): each is sealed once with a fresh key, wrapped
// for every member with the key the sender shares with them. The group's name
// and picture aren't encrypted, and every group says so. Messages from before
// a group switched stay plain text (format 0).

const groupById = (id) => state.groups.find((g) => g.id === id);

// ---------- group encryption ----------

const groupWrapKeys = new Map();   // "<user id>:<public key>" -> wrap key with them
const groupPlain = new Map();      // message id -> { text, replyTo }, or null if it couldn't be opened
const groupMemberKeys = new Map(); // group id -> [{ id, username, public_key }] from the server

class KeyChangedError extends Error {}

async function groupWrapKeyFor(userId, pub) {
  const k = `${userId}:${pub}`;
  if (!groupWrapKeys.has(k)) groupWrapKeys.set(k, await e2e.groupWrapKey(state.identity.privateKey, pub, state.me.id, userId));
  return groupWrapKeys.get(k);
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
  m.reply_to = body?.replyTo ?? null;
  m.undecryptable = !body;
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

async function refreshGroups() {
  try {
    const groups = await getJSON("/groups");
    await Promise.all(groups.map((g) => g.last_message && openGroupMessage(g.last_message)));
    state.groups = groups;
    state.loaded.groups = true;
  } catch (err) {
    report("warn", "loading groups failed", errorFields(err));
    state.loaded.error = err.message;
    renderChatList();
    return;
  }
  if (!state.me) return;
  renderChatList();
  if (state.activeGroupId && !groupById(state.activeGroupId)) closeChat(); // removed or left
}

let groupRefreshTimer = null;
function refreshGroupsSoon() {
  clearTimeout(groupRefreshTimer);
  groupRefreshTimer = setTimeout(refreshGroups, 150);
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
    return { text: mine ? "You sent a pic" : `${personName(m.sender_id, m.sender_name)} sent a pic`, marker: waiting ? "snap" : g.unread ? "text" : null };
  }
  const text = m.kind === "event"
    ? groupEventText(m)
    : `${m.sender_id === state.me.id ? "You" : personName(m.sender_id, m.sender_name)}: ${m.undecryptable ? "Encrypted message" : m.body}`;
  return { text, marker: g.unread ? "text" : null };
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

async function openGroup(groupId) {
  if (!groupById(groupId)) return;
  if (state.activeGroupId !== groupId) {
    setReply(null);
    state.actionFor = null;
  }
  state.activeId = null;
  state.activeGroupId = groupId;
  setConversationMode("group");
  $("#app").classList.add("in-chat");
  closeProfileTab();
  $("#chat-placeholder").hidden = true;
  $("#chat").hidden = false;
  renderGroupHeader();
  const key = `g${groupId}`;
  if ($("#messages").dataset.friend !== key) {
    $("#messages").dataset.friend = key;
    delete $("#messages").dataset.scrolled;
  }
  renderChatList();
  renderMessages();
  try {
    const page = await getJSON(`/groups/${groupId}/messages?limit=${PAGE}`);
    await Promise.all(page.map(openGroupMessage));
    if (state.activeGroupId !== groupId) return;
    const loaded = state.groupMessages.get(groupId);
    if (loaded?.length && page.length && page[0].id <= loaded[loaded.length - 1].id) {
      for (const m of page) upsertGroupMessage(m);
    } else {
      state.groupMessages.set(groupId, page);
      state.groupHistory.set(groupId, { hasMore: page.length === PAGE, loading: false });
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
  if (matchMedia("(min-width: 760px)").matches) $("#composer-input").focus();
}

function upsertGroupMessage(m) {
  const msgs = state.groupMessages.get(m.group_id);
  if (!msgs) return; // not loaded yet; it'll fetch on open
  // However it arrived (a reaction's response, a pic's update), a sealed
  // message shows what it says: from what's already been opened, or by
  // opening it now and drawing again.
  if (m.format === e2e.GROUP_FORMAT && m.kind === "text" && !m.pic) {
    if (groupPlain.has(m.id)) {
      const body = groupPlain.get(m.id);
      m.body = body?.text ?? "";
      m.reply_to = body?.replyTo ?? null;
      m.undecryptable = !body;
    } else {
      openGroupMessage(m).then(() => { if (state.activeGroupId === m.group_id) renderMessages(); });
    }
  }
  const i = msgs.findIndex((x) => x.id === m.id);
  if (i >= 0) msgs[i] = m;
  else msgs.push(m);
  msgs.sort((a, b) => a.id - b.id);
}

async function loadOlderGroup(groupId) {
  const msgs = state.groupMessages.get(groupId);
  const h = state.groupHistory.get(groupId);
  if (!msgs?.length || !h?.hasMore || h.loading) return;
  h.loading = true;
  renderMessages();
  try {
    const page = await getJSON(`/groups/${groupId}/messages?before=${msgs[0].id}&limit=${PAGE}`);
    await Promise.all(page.map(openGroupMessage));
    const have = new Set(msgs.map((m) => m.id));
    msgs.unshift(...page.filter((m) => !have.has(m.id)));
    h.hasMore = page.length === PAGE;
  } catch (err) {
    report("warn", "loading older group messages failed", { group_id: groupId, ...errorFields(err) });
  } finally {
    h.loading = false;
  }
  if (state.activeGroupId !== groupId) return;
  const list = $("#messages");
  const fromBottom = list.scrollHeight - list.scrollTop;
  renderMessages();
  list.scrollTop = list.scrollHeight - fromBottom;
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
  if (!groupById(groupId)?.unread) return;
  try {
    await api(`/groups/${groupId}/read`, { method: "POST" });
  } catch (err) {
    report("warn", "marking group read failed", { group_id: groupId, ...errorFields(err) });
  }
}

function renderGroupMessages() {
  const list = $("#messages");
  const msgs = state.groupMessages.get(state.activeGroupId) || [];
  const g = groupById(state.activeGroupId);
  const nearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
  const items = [];
  const h = state.groupHistory.get(state.activeGroupId);
  if (msgs.length && h) {
    if (h.loading) items.push(el("li", { class: "msg-meta history-edge", text: "Loading earlier messages…" }));
    else if (!h.hasMore) items.push(el("li", { class: "msg-meta history-edge", text: `This is the beginning of ${g?.name ?? "the group"}, from when you joined.` }));
  }
  let prevSender = null;
  for (const m of msgs) {
    if (m.kind === "event") {
      items.push(el("li", { class: "msg-meta group-event", text: groupEventText(m) }));
      prevSender = null;
      continue;
    }
    const mine = m.sender_id === state.me.id;
    if (m.sender_id !== prevSender) {
      items.push(el("li", { class: `sender ${mine ? "mine" : ""}`, text: `${mine ? "Me" : personName(m.sender_id, m.sender_name)}  ${clockTime(m.created_at)}` }));
      prevSender = m.sender_id;
    }
    if (m.undecryptable) {
      items.push(el("li", { class: `msg undecryptable ${mine ? "mine" : ""}`, text: "Couldn't decrypt this message." }));
      continue;
    }
    const content = [];
    if (m.pic) content.push(groupPicChip(m, mine));
    if (m.body) content.push(el("span", { class: "msg-body", text: m.body }));
    items.push(...bubble(m, mine, content));
  }
  const seen = seenByText(state.activeGroupId, msgs[msgs.length - 1]);
  if (seen) items.push(el("li", { class: "msg-meta seen-by", text: seen }));
  const sending = outboxItems(`g:${state.activeGroupId}`, prevSender);
  items.push(...sending);
  if (!msgs.length && !sending.length) items.push(...emptyChat(state.groupMessages.has(state.activeGroupId), `g:${state.activeGroupId}`));
  list.replaceChildren(...items);
  if (nearBottom || !list.dataset.scrolled) {
    list.scrollTop = list.scrollHeight;
    list.dataset.scrolled = "1";
  }
}

/** View-once per member. The sender sees how many have opened it. */
function groupPicChip(m, mine) {
  const p = m.pic;
  const seen = p.viewers.includes(state.me.id);
  if (!mine && !seen && !p.discard_reason) {
    return el("button", { type: "button", class: "snap-chip", onclick: () => openPics(m) },
      el("span", { class: "marker snap", "aria-hidden": "true" }), "Tap to view pic");
  }
  const label = mine
    ? p.discard_reason === "opened" ? "Opened by everyone"
      : p.discard_reason === "expired" ? "Expired"
      : p.viewers.length ? `Opened by ${p.viewers.length}` : "Pic sent"
    : seen ? "Viewed" : "Expired";
  return el("span", { class: "snap-chip done" }, el("span", { class: "marker", "aria-hidden": "true" }), label);
}

/** Fetches (and for format 3, decrypts) one group pic: { blob, caption, from }. */
async function loadGroupPic(m) {
  const url = `/groups/${m.group_id}/pics/${m.pic.id}`;
  const from = `${personName(m.sender_id, m.sender_name)} · ${groupById(m.group_id)?.name ?? ""}`;
  if (m.format === e2e.GROUP_FORMAT) {
    const sealed = await api(url, { as: "bytes" });
    const opts = { groupId: m.group_id, senderId: m.sender_id, myId: state.me.id, clientId: m.client_id, recipients: m.recipients || [] };
    for (const pub of m.key ? await readingKeys(m.sender_id, m.sender_public_key) : []) {
      try {
        const pic = await e2e.decryptGroupPic(sealed, m.key, { ...opts, wrapKey: await groupWrapKeyFor(m.sender_id, pub) });
        return { blob: new Blob([pic.photo], { type: "image/jpeg" }), caption: pic.caption, from };
      } catch {}
    }
    report("warn", "group pic decrypt failed", { message_id: m.id, group_id: m.group_id });
    throw new PicProblem("This pic couldn't be decrypted.");
  }
  const res = await api(url);
  let caption = "";
  try { caption = decodeURIComponent(res.headers.get("X-Napsack-Caption") || ""); } catch {}
  return { blob: await res.blob(), caption, from };
}

/** What to say when a pic couldn't be sent. */
function sendProblem(err) {
  return retryable(err)
    ? "Couldn't send: the connection dropped. Your pic is still here; tap Send to try again."
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

function friendPicker(friends, checked = new Set()) {
  return friends.map((f) => {
    const avatar = el("span", { class: "avatar small", "aria-hidden": "true" });
    paintAvatar(avatar, f);
    return el("li", {},
      el("label", { class: "person pick" },
        el("input", { type: "checkbox", name: "member", value: String(f.id), checked: checked.has(f.id) || null }),
        avatar,
        el("span", { class: "person-name", text: chatName(f) })));
  });
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

async function openGroupInfo(groupId) {
  let g;
  try {
    g = await getJSON(`/groups/${groupId}`);
  } catch (err) {
    if ($("#group-dialog").open) $("#group-dialog").close();
    return;
  }
  state.groupDetail = g;
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
  $("#group-members").replaceChildren(...g.members.map((m) => {
    const me = m.id === state.me.id;
    const avatar = el("span", { class: "avatar small", "aria-hidden": "true" });
    paintAvatar(avatar, m);
    const friend = !me && chatById(m.id);
    return el("li", { class: "person" },
      avatar,
      friend
        ? el("button", { type: "button", class: "person-name link-name", onclick: () => { $("#group-dialog").close(); openProfile(m.id); } }, personName(m.id, m.username))
        : el("span", { class: "person-name", text: me ? `${personName(m.id, m.username)} (you)` : m.username }),
      m.role === "owner" ? el("span", { class: "role-badge", text: "Owner" }) : null,
      !me && !friend ? befriendControl(g, m) : null,
      g.role === "owner" && !me
        ? el("button", { type: "button", class: "button", "aria-label": `Remove ${personName(m.id, m.username)}`,
          onclick: (e) => removeFromGroup(e.currentTarget, g, m) }, "Remove")
        : null);
  }));
  const inGroup = new Set(g.members.map((m) => m.id));
  const addable = state.chats.filter((f) => !f.system && !inGroup.has(f.id)).sort((a, b) => chatName(a).localeCompare(chatName(b)));
  $("#group-add-section").hidden = addable.length === 0;
  $("#group-add").replaceChildren(...addable.map((f) => {
    const avatar = el("span", { class: "avatar small", "aria-hidden": "true" });
    paintAvatar(avatar, f);
    return el("li", { class: "person" }, avatar,
      el("span", { class: "person-name", text: chatName(f) }),
      el("button", { type: "button", class: "button primary", onclick: () => addToGroup(g, f) }, "Add"));
  }));
  const leave = $("#leave-group");
  leave.textContent = "Leave group";
  delete leave.dataset.confirm;
  if (!$("#group-dialog").open) {
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
  if ($("#group-dialog").open && state.groupDetail?.id === g.id) openGroupInfo(g.id);
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

async function openProfile(userId) {
  const dialog = $("#profile-dialog");
  const msg = $("#profile-message");
  for (const id of ["#profile-stats", "#profile-people", "#profile-actions"]) $(id).replaceChildren();
  hideProfileEdit();
  $("#profile-people-section").hidden = true;
  $("#profile-account").hidden = userId !== state.me?.id;
  msg.hidden = true;
  // Never the last person's name while this one loads (X23).
  const known = userId === state.me?.id ? state.me : chatById(userId);
  $("#profile-name").textContent = known ? personName(userId, known.username) : "";
  $("#profile-sub").textContent = "";
  $("#profile-stats").replaceChildren(el("p", { class: "muted", text: "Loading…" }));
  if (!dialog.open) dialog.showModal();

  let p;
  try {
    p = await getJSON(`/users/${userId}/profile?tz=${tzOffset()}`);
  } catch (err) {
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
  }

  $("#profile-people-section").hidden = people.length === 0 && p.kind !== "me";
  $("#profile-people").replaceChildren(...people.map((f) => {
    const avatar = el("span", { class: "avatar small", "aria-hidden": "true" });
    paintAvatar(avatar, f);
    return el("li", {},
      el("button", { type: "button", class: "person person-link", onclick: () => openProfile(f.id) },
        avatar,
        el("span", { class: "person-name", text: personName(f.id, f.username) }),
        el("span", { class: "person-meta", text: `since ${longDate(f.since)}` })));
  }));
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
  if (mine) renderSecurity();
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

// ---------- friends ----------

async function refreshRequests() {
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
  $("#incoming-list").replaceChildren(...incoming.map((r) =>
    el("li", { class: "person" },
      el("span", { class: "person-name", text: r.username }),
      el("button", { type: "button", class: "button primary", onclick: () => requestAction(r.id, "accept") }, "Accept"),
      el("button", { type: "button", class: "button", onclick: () => requestAction(r.id, "decline") }, "Decline"),
    )));

  $("#outgoing-section").hidden = outgoing.length === 0;
  $("#outgoing-list").replaceChildren(...outgoing.map((r) =>
    el("li", { class: "person" },
      el("span", { class: "person-name", text: r.username }),
      el("button", { type: "button", class: "button", onclick: () => requestAction(r.id, "cancel") }, "Cancel request"),
    )));
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
  $("#invite-made").hidden = true;
  $("#invite-note").textContent = "";
  $("#my-link-note").textContent = "";
  $("#friends-dialog").showModal();
  refreshRequests();
  renderInvites();
  loadMyLink();
}

// ---------- my personal link and code (X25) ----------
// One "add me" link per person (invites.rs), shown as a QR to people in
// person: it keeps working until reset.

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
// Two taps: the old link and code stop working for everyone.
$("#my-link-reset").addEventListener("click", async (e) => {
  const btn = e.currentTarget;
  if (!btn.dataset.confirm) {
    btn.dataset.confirm = "1";
    btn.textContent = "Tap again: your old code stops working";
    return;
  }
  delete btn.dataset.confirm;
  btn.textContent = "Reset my link";
  try {
    showMyLink((await getJSON("/friend-link/reset", { method: "POST" })).path);
    $("#my-link-note").textContent = "Done: you have a new link and code. The old ones don't work any more.";
    report("info", "personal link reset");
  } catch (err) {
    $("#my-link-note").textContent = err.message;
  }
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

async function renderInvites() {
  let invites = [];
  try {
    invites = await getJSON("/invites");
  } catch (err) {
    report("warn", "loading invites failed", errorFields(err));
    return;
  }
  $("#invite-list").replaceChildren(...invites.slice(0, 5).map((inv) => {
    const used = `${inv.joined.length} of ${inv.max_uses} used`;
    const state_ = inv.live ? `until ${longDate(inv.expires_at)}` : inv.revoked_at ? "turned off" : "finished";
    const who = inv.joined.length ? ` · ${inv.joined.map((j) => personName(j.id, j.username)).join(", ")}` : "";
    return el("li", { class: "person" },
      el("span", { class: "person-name", text: `Link from ${longDate(inv.created_at)} · ${used}, ${state_}${who}` }),
      inv.live ? el("button", { type: "button", class: "button", onclick: () => revokeInvite(inv.id) }, "Turn off") : null);
  }));
}

async function revokeInvite(id) {
  try {
    await api(`/invites/${id}/revoke`, { method: "POST" });
    $("#invite-note").textContent = "That link no longer works.";
  } catch (err) {
    $("#invite-note").textContent = err.message;
  }
  $("#invite-made").hidden = true;
  renderInvites();
}

$("#invite-make").addEventListener("click", async () => {
  try {
    const res = await getJSON("/invites", { method: "POST" });
    const url = `${location.origin}${res.path}`;
    $("#invite-link").textContent = url;
    $("#invite-qr").replaceChildren(qrSvg(url, "QR code for your invite link"));
    $("#invite-share").hidden = !navigator.share;
    $("#invite-copy").textContent = "Copy link";
    $("#invite-made").hidden = false;
    $("#invite-note").textContent = "";
    report("info", "invite link made");
  } catch (err) {
    $("#invite-note").textContent = err.message;
  }
  renderInvites();
});

$("#invite-copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("#invite-link").textContent);
    $("#invite-copy").textContent = "Copied";
  } catch {
    $("#invite-copy").textContent = "Select it and copy";
  }
});

$("#invite-share").addEventListener("click", () => {
  navigator.share({ title: "napsack", text: "Join me on napsack", url: $("#invite-link").textContent }).catch(() => {});
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
    note.textContent = res.status === "friends"
      ? `You and ${res.user.username} are now friends.`
      : `Request sent to ${res.user.username}.`;
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
  camera.stream?.getTracks().forEach((t) => t.stop());
  camera.stream = null;
  $("#camera-video").srcObject = null;
}

// Drawing on the pic before it's sent (draw.js).
const drawing = createDrawing({
  img: $("#camera-preview"), stage: $(".camera-stage"), canvas: $("#draw-layer"), layer: $("#sticker-layer"),
  penButton: $("#draw-pen"), colors: $("#draw-colors"), sizeButton: $("#draw-size"),
  stickerButton: $("#draw-sticker"), stickerTray: $("#sticker-tray"),
  bigger: $("#sticker-bigger"), smaller: $("#sticker-smaller"), undoButton: $("#draw-undo"),
});

function showDrawing(on) {
  for (const id of ["#draw-layer", "#sticker-layer", "#draw-tools"]) $(id).hidden = !on;
  drawing.reset();
}

/** The photo to send: as taken, or with the drawing flattened into it and compressed again. */
async function finalPhoto() {
  if (!drawing.hasMarks()) return new Uint8Array(await camera.blob.arrayBuffer());
  const flat = drawing.flatten();
  const blob = await compressPhoto(flat, flat.width, flat.height);
  report("debug", "pic drawn on", { bytes: blob.size });
  return new Uint8Array(await blob.arrayBuffer());
}

function showCapture() {
  clearPreview();
  $("#camera-video").hidden = false;
  // Back from a photo (Retake) to a camera that couldn't start: say why now.
  if (!camera.stream && camera.problem) cameraMessage(camera.problem);
  $("#capture-controls").hidden = false;
  $("#send-controls").hidden = true;
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
  camera.sends = new Map(); // a new pic gets new ids and is sealed afresh...
  camera.sent = new Set();   // ...and hasn't gone to anyone
  const img = $("#camera-preview");
  img.removeAttribute("src");
  img.hidden = true;
  showDrawing(false);
}

function showPreview(blob) {
  clearPreview();
  camera.blob = blob;
  camera.previewUrl = URL.createObjectURL(blob);
  const img = $("#camera-preview");
  img.src = camera.previewUrl;
  img.hidden = false;
  showDrawing(true);
  $("#camera-video").hidden = true;
  cameraMessage("");
  $("#capture-controls").hidden = true;
  $("#send-controls").hidden = false;
  $("#send-snap").textContent = sendLabel();
  $("#snap-caption-box").hidden = false;
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
  stopStream();
  clearPreview();
  clearCaption(); // sent or abandoned, it shouldn't linger in the page
  camera.to = [];
  if (tabs.current === "camera") showTab(profileTabOpen() ? "profile" : "chats");
});

$("#flip-camera").addEventListener("click", () => {
  camera.facing = camera.facing === "user" ? "environment" : "user";
  startStream();
});

// Double-tapping the live camera switches it, like the button. Counted from
// clicks rather than `dblclick`, which phones don't reliably send.
let lastStageTap = { at: 0, x: 0, y: 0 };
$(".camera-stage").addEventListener("click", (e) => {
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
  const video = $("#camera-video");
  if (!camera.stream || !video.videoWidth) return;
  try {
    // Freeze the frame first; the video keeps moving while we compress.
    const frame = await createImageBitmap(video);
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
    showPreview(await compressPhoto(bitmap, bitmap.width, bitmap.height));
  } catch (err) {
    cameraMessage(err.message);
  } finally {
    bitmap.close();
  }
});

// The caption box grows with what's typed (style.css caps it at four lines),
// and says how much room is left once there's little.
const CAPTION_MAX = 200;
function fitCaption() {
  const input = $("#snap-caption");
  // Enter sends, so a caption is one paragraph: pasted line breaks become spaces.
  if (/[\r\n]/.test(input.value)) input.value = input.value.replace(/[\r\n]+/g, " ");
  input.style.height = "auto";
  input.style.height = `${input.scrollHeight + 2}px`; // + the borders (border-box)
  const used = [...input.value].length;
  const count = $("#snap-caption-count");
  count.hidden = used < CAPTION_MAX - 40;
  count.textContent = `${used}/${CAPTION_MAX}`;
  count.classList.toggle("full", used >= CAPTION_MAX);
}
function clearCaption() {
  $("#snap-caption").value = "";
  $("#snap-caption-box").hidden = true;
  fitCaption();
}
$("#snap-caption").addEventListener("input", fitCaption);

$("#snap-caption").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.isComposing) {
    e.preventDefault();
    $("#send-snap").click();
  }
});

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
    const photo = await finalPhoto();
    const caption = $("#snap-caption").value.trim();
    for (const r of to) {
      if (camera.sent.has(recipientKey(r))) continue;
      try {
        if (r.kind === "group") await sendGroupPicTo(r.id, photo, caption);
        else await sendDirectPicTo(r.id, photo, caption);
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
  $("#camera-dialog").close();
  if (picked) {
    showToast(`Pic sent to ${listNames(to)}.`);
    refreshChats();
    refreshGroups();
  }
}

async function sendDirectPicTo(friendId, photo, caption) {
  const key = `d:${friendId}`;
  // The same id on every try (and on Send again), so a retry after a dropped
  // response isn't a second pic.
  if (!camera.sends.has(key)) camera.sends.set(key, newClientId());
  const clientId = camera.sends.get(key);
  // Format 2: the caption is sealed in with the photo, so only the friend sees it.
  const sealed = await e2e.encryptPic(await keyFor(friendId), photo, caption, state.me.id, friendId);
  if (state.config?.snap_max_bytes && sealed.length > state.config.snap_max_bytes) {
    throw new Error("That photo is too large to send.");
  }
  const m = await withRetries(() => getJSON(`/chats/${friendId}/snaps?format=${e2e.SNAP_FORMAT}&client_id=${clientId}`, {
    method: "POST",
    body: sealed,
    headers: { "Content-Type": "application/octet-stream" },
  }));
  await upsertMessage(m);
  if (state.activeId === friendId) renderMessages();
}

async function sendGroupPicTo(groupId, photo, caption) {
  const key = `g:${groupId}`;
  // Sealed once per pic and group, so Send again after a dropped connection
  // resends the same one (the server keeps one copy).
  if (!camera.sends.has(key)) {
    camera.sends.set(key, groupSender(groupId,
      (opts) => e2e.encryptGroupPic(photo, caption, opts),
      (s) => getJSON(`/groups/${groupId}/pics?format=${e2e.GROUP_FORMAT}`, {
        method: "POST", body: s.content, headers: { "Content-Type": "application/octet-stream", "X-Napsack-Keys": keysHeader(s) },
      })));
  }
  const m = await withRetries(camera.sends.get(key));
  upsertGroupMessage(m);
  if (state.activeGroupId === groupId) renderMessages();
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
$("#profile-sign-out").addEventListener("click", () => $("#sign-out").click());

// ---------- snap viewer ----------

// A `run` taps through every unopened pic in the chat: closing one opens the
// next. A pic counts as opened only once it's actually on screen: then the
// app tells the server (`confirmOpened`). So a dropped download, a slow
// decode, or a tap before it appears never loses one; it stays unopened, to
// try again. Stopping halfway (Escape, or leaving the app) leaves the rest
// unopened too.
const viewer = { url: null, timer: null, run: null, loading: false, shownAt: 0 };
// Taps this soon after a pic appears don't count: a quick double tap
// shouldn't skip past a pic nobody saw.
const TAP_GUARD_MS = 600;

/** Unopened pics in the open chat, oldest first. */
function waitingPics() {
  if (state.activeGroupId) {
    return (state.groupMessages.get(state.activeGroupId) || []).filter((m) => m.pic
      && m.sender_id !== state.me.id && !m.pic.viewers.includes(state.me.id) && !m.pic.discard_reason);
  }
  return (state.messages.get(state.activeId) || []).filter((m) => m.kind === "snap"
    && m.sender_id !== state.me.id && m.snap_state === "pending");
}

/** Tapping a pic opens it, then the others waiting in the chat, one by one. */
function openPics(first) {
  if (viewer.loading) return;
  viewer.run = { seen: new Set() };
  openPic(first);
}

/** A pic that can't be shown for a reason other than the connection. */
class PicProblem extends Error {}

async function openPic(m) {
  const run = viewer.run;
  run.seen.add(m.id);
  viewer.loading = true;
  showOpening(m);
  let pic;
  try {
    pic = await (m.pic ? loadGroupPic(m) : loadSnap(m));
  } catch (err) {
    viewer.loading = false;
    if (viewer.run !== run) return;
    // Opened on another device, or expired: on to the next.
    if (err.status === 410 || err.status === 404) return nextPic();
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
  if (shown) confirmOpened(m);
  else if (viewer.run === run) showViewerProblem("This pic couldn't be shown. It's still unopened.");
}

function nextPic() {
  if (viewer.loading) return;
  if (viewer.url && Date.now() - viewer.shownAt < TAP_GUARD_MS) return;
  const run = viewer.run;
  const next = run && waitingPics().find((m) => !run.seen.has(m.id));
  if (!next) return stopViewer();
  clearViewer(); // the viewer stays up, saying "Opening…", while the next one loads
  openPic(next);
}

/** Fetches and decrypts one direct pic: { blob, caption, from }. */
async function loadSnap(m) {
  if (![1, 2].includes(m.format ?? 1)) throw new PicProblem("This pic was sent from a newer version of napsack. Reload to open it.");
  const sealed = await api(`/snaps/${m.id}`, { as: "bytes" });
  let pic;
  try {
    pic = await withReadKey(m.sender_id, (k) => e2e.decryptPic(k, sealed, m.format ?? 1, m.sender_id, m.recipient_id));
  } catch {
    throw new PicProblem("This pic couldn't be decrypted.");
  }
  return { blob: new Blob([pic.photo], { type: "image/jpeg" }), caption: pic.caption, from: personName(m.sender_id, "") };
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
function showOpening(m) {
  const v = $("#viewer");
  v.classList.add("opening");
  $("#viewer-error").hidden = true;
  $("#viewer-from").textContent = personName(m.sender_id, m.sender_name ?? "");
  $("#viewer-caption").hidden = true;
  updateCount();
  $("#viewer-hint").textContent = "Opening…";
  v.hidden = false;
}

/** Shows a loaded pic and starts its timer. True once it's on screen. */
async function showInViewer({ blob, from, caption = "" }) {
  viewer.url = URL.createObjectURL(blob);
  const v = $("#viewer");
  const img = $("#viewer-image");
  img.src = viewer.url;
  try {
    await img.decode();
  } catch {
    return false;
  }
  if (!viewer.url) return false; // closed while it decoded
  v.classList.remove("opening");
  $("#viewer-from").textContent = from;
  $("#viewer-caption").textContent = caption;
  $("#viewer-caption").hidden = !caption;
  const left = updateCount();
  $("#viewer-hint").textContent = left ? "Tap for the next pic" : "Tap to close";
  v.style.setProperty("--view-ms", `${VIEW_MS}ms`);
  v.classList.add("running");
  viewer.timer = setTimeout(nextPic, VIEW_MS);
  viewer.shownAt = Date.now();
  return true;
}

/** Something went wrong: say so in the viewer; a tap closes it, and the pic stays unopened. */
function showViewerProblem(text) {
  $("#viewer").classList.remove("opening");
  $("#viewer-error").textContent = text;
  $("#viewer-error").hidden = false;
  $("#viewer-hint").textContent = "Tap to close";
  viewer.run = null;
}

function clearViewer() {
  clearTimeout(viewer.timer);
  const v = $("#viewer");
  v.classList.remove("running", "opening");
  $("#viewer-error").hidden = true;
  const img = $("#viewer-image");
  img.removeAttribute("src");
  if (viewer.url) URL.revokeObjectURL(viewer.url);
  viewer.url = null;
}

function stopViewer() {
  viewer.run = null;
  clearViewer();
  $("#viewer").hidden = true;
}

$("#viewer").addEventListener("click", nextPic);
$("#viewer").addEventListener("contextmenu", (e) => e.preventDefault());
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("#viewer").hidden) stopViewer();
});

// Keep relative timestamps fresh.
setInterval(() => { if (state.me) renderChatList(); }, 60_000);

// ---------- boot ----------

(async function boot() {
  try {
    state.config = await (await fetch("/api/config")).json();
  } catch {
    state.config = { invite_required: false };
  }
  APP_NAME = withEnvironment(APP_NAME, state.config);
  document.title = APP_NAME;
  markEnvironment(state.config);
  await readInviteLink();
  if (state.token) {
    try {
      state.me = await getJSON("/me");
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
    signOutLocally();
    showInviteBanner();
    return;
  }
  showAuth();
  showInviteBanner();
})();
