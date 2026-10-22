// napsack web client. Plain ES module: no framework, no build step.
// Every API call here is what the future mobile app will make too.
// Texts and snaps are encrypted here before upload; see crypto.js.

import * as e2e from "/crypto.js";
import * as keystore from "/keystore.js";
import { qrSvg } from "/qr.js";

const APP_NAME = "napsack";
const VIEW_MS = 10_000;        // how long a snap stays on screen
const MAX_EDGE = 1280;         // longest side of a snap, before any further shrinking
const SNAP_TARGET_BYTES = 200 * 1024;
const TOKEN_KEY = "fade.token";
const IDENTITY_KEY = "identity";

const $ = (sel, root = document) => root.querySelector(sel);

const state = {
  token: localStorage.getItem(TOKEN_KEY),
  me: null,
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
  groups: [],                  // GroupSummary[] (not end-to-end encrypted in v1)
  activeGroupId: null,         // group id of the open group chat (activeId is null then)
  groupMessages: new Map(),    // group id -> GroupMessage[], oldest first
  groupHistory: new Map(),     // group id -> { hasMore, loading }
  groupReads: new Map(),       // group id -> Map(user id -> { username, last }): how far each member has read
  showHidden: false,           // the chat list is showing hidden chats
  groupDetail: null,           // the group shown in the info sheet
  messages: new Map(),         // friend id -> Message[], oldest first; may be only the newest pages
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


// Make an API call
async function api(path, { method = "GET", json, body, headers = {} } = {}) {
  const HEADERS = { ...headers };

  // our primary client authorization mechanism
  if (state.token) HEADERS.Authorization = `Bearer ${state.token}`;
  
  if (json !== undefined) {
    HEADERS["Content-Type"] = "application/json";
    body = JSON.stringify(json);
  }
  
  let res;
  try {
    res = await fetch(`/api${path}`, { method, headers: HEADERS, body, cache: "no-store" });
  } catch {
    throw new ApiError("Can't reach the server. Check your connection.", 0);
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

  return res;
}


// gimme dat json right away
const getJSON = async (path, opts) => (await api(path, opts)).json();

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
  state.identity = null;
  state.pins = {};
  state.pastPins = {};
  state.readKeys.clear();
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
  $("#admin-link").hidden = !state.me.is_admin;
  syncPush();
  if (location.hash) openFromLink(location.hash);
  refreshChats();
  refreshGroups();
  refreshRequests();
  connectSocket();
}

function renderAccountBar() {
  $("#my-name").textContent = personName(state.me.id);
  paintAvatar($("#my-avatar"), state.me);
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
    const chats = await getJSON("/friends");
    await checkPins(chats);
    state.chats = chats;
    await Promise.all(chats.map((c) => c.last_message && decrypt(c.last_message)));
  } catch (err) {
    report("warn", "loading chats failed", errorFields(err));
    return;
  }
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
function chatRow({ name, status, time, current, onclick, group, avatar, actions = [] }) {
  const cls = ["chat-item"];
  if (status.marker === "snap") cls.push("has-unread", "has-snap");
  else if (status.marker === "text") cls.push("has-unread");
  if (group) cls.push("is-group");
  // While a row is swiped open, a tap anywhere on the list just closes it.
  const open = () => (rowSwipe.open ? closeSwipedRow() : onclick());
  return el("li", { class: "chat-row" },
    el("button", { type: "button", class: cls.join(" "), "aria-current": current ? "true" : null, onclick: open },
      el("span", { class: `marker ${status.marker || ""}`, "aria-hidden": "true" }),
      avatar,
      el("span", { class: "chat-text" },
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
  const entries = [
    ...state.chats.map((chat) => ({
      at: chat.last_message?.created_at ?? 0,
      name: chatName(chat),
      favorite: chat.favorite,
      hidden: chat.hidden,
      row: chatRow({
        name: chatName(chat), status: isTyping(`d:${chat.id}`) ? { text: "typing…" } : chatStatus(chat),
        time: chat.last_message?.created_at,
        current: chat.id === state.activeId, onclick: () => openChat(chat.id),
        avatar: el("span", { class: `avatar-wrap ${chat.active_now ? "online" : ""}` },
          paintAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), chat)),
        actions: chat.hidden
          ? [{ label: "Unhide", icon: "archive", aria: `Show your chat with ${chatName(chat)} again`, run: () => unhideChat(chat.id) }]
          : [favoriteAction(chat, chatName(chat), () => setFavorite("chats", chat.id, !chat.favorite)),
            { label: "Hide", icon: "archive", aria: `Hide your chat with ${chatName(chat)}`, run: () => hideChat(chat.id) }],
      }),
    })),
    ...state.groups.map((g) => ({
      at: g.last_message?.created_at ?? 0,
      name: g.name,
      favorite: g.favorite,
      hidden: false,
      row: chatRow({
        name: g.name, status: groupStatus(g), time: g.last_message?.created_at, group: true,
        current: g.id === state.activeGroupId, onclick: () => openGroup(g.id),
        avatar: paintGroupAvatar(el("span", { class: "avatar small", "aria-hidden": "true" }), g),
        actions: [favoriteAction(g, g.name, () => setFavorite("groups", g.id, !g.favorite)),
          { label: "Leave", icon: "leave", cls: "danger", aria: `Leave ${g.name}`, run: (e) => leaveFromList(e.currentTarget, g) }],
      }),
    })),
  ].sort((a, b) => b.at - a.at || a.name.localeCompare(b.name));

  const shown = entries.filter((e) => !e.hidden);
  const favorites = shown.filter((e) => e.favorite);
  const rest = shown.filter((e) => !e.favorite);
  const hidden = entries.filter((e) => e.hidden);
  const heading = (text) => el("li", { class: "list-heading", text });
  const items = [];
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
  $("#chat-empty").hidden = entries.length > 0;
  const unread = state.chats.reduce((n, c) => n + (c.hidden ? 0 : c.unread), 0) + state.groups.reduce((n, g) => n + g.unread, 0);
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
  $("#composer-input").disabled = chat.keyChanged;
  $("#composer .send").disabled = chat.keyChanged;
  $("#camera-button").disabled = chat.keyChanged;
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
  if (!msgs.length) items.push(el("li", { class: "msg-meta", text: "No messages yet." }));
  list.replaceChildren(...items);
  if (nearBottom || !list.dataset.scrolled) {
    list.scrollTop = list.scrollHeight;
    list.dataset.scrolled = "1";
  }
}

async function upsertMessage(m) {
  await decrypt(m);
  const fid = friendOf(m);
  const msgs = state.messages.get(fid);
  if (!msgs) return; // chat not loaded yet; it'll fetch on open
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
  try {
    const replyTo = state.replyTo && !state.replyTo.group ? state.replyTo.id : null;
    const ciphertext = await e2e.encryptText2(await keyFor(friendId), text, replyTo, state.me.id, friendId);
    const m = await getJSON(`/chats/${friendId}/messages`, { method: "POST", json: { ciphertext, format: e2e.TEXT_FORMAT } });
    state.plaintext.set(m.id, { text, replyTo });
    setReply(null);
    await upsertMessage(m);
    if (state.activeId === friendId) renderMessages();
  } catch (err) {
    input.value = text;
    fitComposer();
    alert(err.message);
  }
});

// The message box grows with what's typed; style.css caps it at four lines,
// past which it scrolls inside.
function fitComposer() {
  const input = $("#composer-input");
  input.style.height = "auto";
  input.style.height = `${input.scrollHeight + 2}px`; // + the borders (border-box)
}
$("#composer-input").addEventListener("input", fitComposer);

// On a computer, Enter sends and Shift+Enter starts a new line. On a phone,
// Return starts a new line and the Send button sends, like iMessage.
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
  };
}

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
  }
});

async function handleEvent(ev) {
  switch (ev.type) {
    case "ready":
      state.wsRetry = 0;
      sendVisibility();
      checkForUpdate();
      // Anything could have happened while disconnected.
      refreshChats();
      refreshGroups();
      refreshRequests();
      if (state.activeId) openChat(state.activeId);
      else if (state.activeGroupId) openGroup(state.activeGroupId);
      break;
    case "auth_failed":
      signOutLocally();
      break;
    case "message":
    case "message_updated": {
      const m = ev.message;
      // Their message arrived, so they're done typing (don't wait out the timer).
      if (ev.type === "message" && m.sender_id !== state.me.id) stopTyping(`d:${m.sender_id}`);
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
        const msgs = state.messages.get(ev.by) || [];
        for (const m of msgs) {
          if (m.sender_id === state.me.id && m.kind === "text" && !m.read_at && m.created_at <= ev.at) m.read_at = ev.at;
        }
        if (ev.by === state.activeId) renderMessages();
        refreshChatsSoon();
      }
      break;
    }
    case "friends_changed":
      await refreshChats();
      refreshRequests();
      refreshMe();
      refreshGroups(); // names in group lists come from the friends list
      if (state.activeGroupId) renderMessages();
      break;
    case "group_message": {
      const m = ev.message;
      stopTyping(`g:${m.group_id}:${m.sender_id}`);
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
// Version 1 isn't end-to-end encrypted: messages go to the server as plain
// text, and every group says so. Direct chats are unaffected.

const groupById = (id) => state.groups.find((g) => g.id === id);

async function refreshGroups() {
  try {
    state.groups = await getJSON("/groups");
  } catch (err) {
    report("warn", "loading groups failed", errorFields(err));
    return;
  }
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
    : `${m.sender_id === state.me.id ? "You" : personName(m.sender_id, m.sender_name)}: ${m.body}`;
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
  }
  if (matchMedia("(min-width: 760px)").matches) $("#composer-input").focus();
}

function upsertGroupMessage(m) {
  const msgs = state.groupMessages.get(m.group_id);
  if (!msgs) return; // not loaded yet; it'll fetch on open
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
    const content = [];
    if (m.pic) content.push(groupPicChip(m, mine));
    if (m.body) content.push(el("span", { class: "msg-body", text: m.body }));
    items.push(...bubble(m, mine, content));
  }
  const seen = seenByText(state.activeGroupId, msgs[msgs.length - 1]);
  if (seen) items.push(el("li", { class: "msg-meta seen-by", text: seen }));
  if (!msgs.length) items.push(el("li", { class: "msg-meta", text: "No messages yet." }));
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

/** Opens one group pic; false if it couldn't be shown. */
async function viewGroupPic(m) {
  let res;
  try {
    res = await api(`/groups/${m.group_id}/pics/${m.pic.id}`);
  } catch (err) {
    if (err.status !== 410) alert(err.message); // 410: opened elsewhere or expired; the socket updates the chat
    return false;
  }
  let caption = "";
  try { caption = decodeURIComponent(res.headers.get("X-Napsack-Caption") || ""); } catch {}
  showInViewer(await res.blob(), `${personName(m.sender_id, m.sender_name)} · ${groupById(m.group_id)?.name ?? ""}`, caption);
  return true;
}

async function sendGroupPic(groupId) {
  const btn = $("#send-snap");
  btn.disabled = true;
  try {
    const caption = encodeURIComponent($("#snap-caption").value.trim());
    const m = await getJSON(`/groups/${groupId}/pics${caption ? `?caption=${caption}` : ""}`, {
      method: "POST", body: camera.blob, headers: { "Content-Type": "image/jpeg" },
    });
    upsertGroupMessage(m);
    if (state.activeGroupId === groupId) renderMessages();
    $("#camera-dialog").close();
  } catch (err) {
    cameraMessage(err.message);
  } finally {
    btn.disabled = false;
  }
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
  try {
    const replyTo = state.replyTo?.group ? state.replyTo.id : undefined;
    const m = await getJSON(`/groups/${groupId}/messages`, { method: "POST", json: { text, reply_to: replyTo } });
    setReply(null);
    upsertGroupMessage(m);
    if (state.activeGroupId === groupId) renderMessages();
  } catch (err) {
    input.value = text;
    fitComposer();
    report("warn", "sending group text failed", { group_id: groupId, ...errorFields(err) });
    alert(err.message);
  }
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
  const friends = [...state.chats].sort((a, b) => chatName(a).localeCompare(chatName(b)));
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
      g.role === "owner" && !me
        ? el("button", { type: "button", class: "button", onclick: () => removeFromGroup(g, m) }, "Remove")
        : null);
  }));
  const inGroup = new Set(g.members.map((m) => m.id));
  const addable = state.chats.filter((f) => !inGroup.has(f.id)).sort((a, b) => chatName(a).localeCompare(chatName(b)));
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
const removeFromGroup = (g, m) => groupAction(
  () => api(`/groups/${g.id}/members/${m.id}`, { method: "DELETE" }), `Removed ${personName(m.id, m.username)}.`);

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

function paintGroupAvatar(node, g) {
  paintInitial(node, g.name, g.id);
  node.classList.add("group");
  if (g.avatar_id) showPicture(node, `g${g.id}:${g.avatar_id}`, `/groups/${g.id}/avatar/${g.avatar_id}`);
  return node;
}

function stat(label, value) {
  return [el("dt", { text: label }), el("dd", { text: String(value) })];
}

async function openProfile(userId) {
  const dialog = $("#profile-dialog");
  const msg = $("#profile-message");
  for (const id of ["#profile-stats", "#profile-people", "#profile-actions"]) $(id).replaceChildren();
  hideProfileEdit();
  $("#profile-people-section").hidden = true;
  msg.hidden = true;
  if (!dialog.open) dialog.showModal();

  let p;
  try {
    p = await getJSON(`/users/${userId}/profile`);
  } catch (err) {
    $("#profile-name").textContent = "";
    $("#profile-sub").textContent = "";
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
    $("#profile-stats").append(
      ...stat("Texts sent", s.texts_sent),
      ...stat("Texts received", s.texts_received),
      ...stat("Pics sent", s.pics_sent),
      ...stat("Pics received", s.pics_received),
      ...stat("Your pics opened", s.pics_sent ? `${s.pics_opened} of ${s.pics_sent}` : "—"),
      ...stat("Friends", p.friends.length),
    );
    $("#profile-people-title").textContent = p.friends.length ? "Your friends" : "No friends yet";
    people = p.friends;
  } else {
    const t = p.together;
    $("#profile-sub").textContent = [...id, `friends since ${longDate(p.friends_since)}`].join(" · ");
    $("#profile-stats").append(
      ...stat("Texts between you", t.texts),
      ...stat("Pics between you", t.pics),
      ...stat("First message", t.first_message_at ? longDate(t.first_message_at) : "—"),
      ...stat("Joined napsack", longDate(p.joined_at)),
      ...stat("Their friends", p.friend_count),
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
  $("#profile-edit-note").textContent = "";
}

function hideProfileEdit() {
  for (const id of ["#profile-name-form", "#profile-name-hint", "#profile-picture-row", "#profile-security"]) $(id).hidden = true;
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

$("#profile-picture-clear").addEventListener("click", () =>
  profileAction(() => api("/me/avatar", { method: "DELETE" }), "Picture removed."));

$("#my-profile").addEventListener("click", () => openProfile(state.me.id));
$("#chat-title").addEventListener("click", () => {
  if (state.activeId) openProfile(state.activeId);
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
  $("#friends-dialog").showModal();
  refreshRequests();
  renderInvites();
}

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
  $("#invite-text").textContent = `${inv.inviter.username} invited you. Add them as a friend?`;
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
  facing: "user",
  mirror: true,                // selfie view: preview and photo both flipped, like a mirror
  blob: null,
  previewUrl: null,
};

function cameraMessage(text) {
  const p = $("#camera-message");
  p.textContent = text || "";
  p.hidden = !text;
}

async function startStream() {
  stopStream();
  cameraMessage("");
  if (!navigator.mediaDevices?.getUserMedia) {
    cameraMessage("This browser can't open the camera here. Choose a photo instead.");
    return;
  }
  try {
    camera.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: camera.facing, width: { ideal: 1920 }, height: { ideal: 1080 } },
      audio: false,
    });
    // Mirror whatever the browser says is a front camera, as Snapchat does, so the
    // photo matches the preview. Laptop webcams report no facing; treat them as front.
    const facing = camera.stream.getVideoTracks()[0]?.getSettings?.().facingMode;
    camera.mirror = (facing || camera.facing) !== "environment";
    const video = $("#camera-video");
    video.classList.toggle("mirrored", camera.mirror);
    video.srcObject = camera.stream;
  } catch {
    cameraMessage("Camera access is blocked. Allow it in your browser settings, or choose a photo instead.");
  }
}

function stopStream() {
  camera.stream?.getTracks().forEach((t) => t.stop());
  camera.stream = null;
  $("#camera-video").srcObject = null;
}

function showCapture() {
  clearPreview();
  $("#camera-video").hidden = false;
  $("#capture-controls").hidden = false;
  $("#send-controls").hidden = true;
  $("#snap-caption").hidden = true;
  $("#snap-caption").value = "";
}

function clearPreview() {
  if (camera.previewUrl) URL.revokeObjectURL(camera.previewUrl);
  camera.previewUrl = null;
  camera.blob = null;
  const img = $("#camera-preview");
  img.removeAttribute("src");
  img.hidden = true;
}

function showPreview(blob) {
  clearPreview();
  camera.blob = blob;
  camera.previewUrl = URL.createObjectURL(blob);
  const img = $("#camera-preview");
  img.src = camera.previewUrl;
  img.hidden = false;
  $("#camera-video").hidden = true;
  cameraMessage("");
  $("#capture-controls").hidden = true;
  $("#send-controls").hidden = false;
  const chat = chatById(state.activeId);
  const name = state.activeGroupId ? groupById(state.activeGroupId)?.name : chat && chatName(chat);
  $("#send-snap").textContent = name ? `Send to ${name}` : "Send";
  $("#snap-caption").hidden = false;
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

$("#camera-button").addEventListener("click", () => {
  if (!state.activeId && !state.activeGroupId) return;
  $("#camera-dialog").showModal();
  showCapture();
  startStream();
});

$("#camera-dialog").addEventListener("close", () => {
  stopStream();
  clearPreview();
  $("#snap-caption").value = ""; // sent or abandoned, it shouldn't linger in the page
  $("#snap-caption").hidden = true;
});

$("#flip-camera").addEventListener("click", () => {
  camera.facing = camera.facing === "user" ? "environment" : "user";
  startStream();
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

$("#snap-caption").addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    e.preventDefault();
    $("#send-snap").click();
  }
});

$("#retake").addEventListener("click", () => {
  showCapture();
  if (!camera.stream) startStream();
});

$("#send-snap").addEventListener("click", async () => {
  if (state.activeGroupId) return sendGroupPic(state.activeGroupId);
  const friendId = state.activeId;
  if (!camera.blob || !friendId) return;
  const btn = $("#send-snap");
  btn.disabled = true;
  try {
    const photo = new Uint8Array(await camera.blob.arrayBuffer());
    // Format 2: the caption is sealed in with the photo, so only the friend sees it.
    const caption = $("#snap-caption").value.trim();
    const sealed = await e2e.encryptPic(await keyFor(friendId), photo, caption, state.me.id, friendId);
    if (state.config?.snap_max_bytes && sealed.length > state.config.snap_max_bytes) {
      throw new Error("That photo is too large to send.");
    }
    const m = await getJSON(`/chats/${friendId}/snaps?format=${e2e.SNAP_FORMAT}`, {
      method: "POST",
      body: sealed,
      headers: { "Content-Type": "application/octet-stream" },
    });
    await upsertMessage(m);
    renderMessages();
    $("#camera-dialog").close();
  } catch (err) {
    cameraMessage(err.message);
  } finally {
    btn.disabled = false;
  }
});

// ---------- snap viewer ----------

// A `run` taps through every unopened pic in the chat: closing one opens the
// next. Each pic is still marked opened when it's fetched, so stopping halfway
// (Escape, or leaving the app) leaves the rest unopened.
const viewer = { url: null, timer: null, run: null, loading: false };

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

async function openPic(m) {
  const run = viewer.run;
  run.seen.add(m.id);
  viewer.loading = true;
  let shown = false;
  try {
    shown = await (m.pic ? viewGroupPic(m) : viewSnap(m));
  } finally {
    viewer.loading = false;
  }
  if (viewer.run === run && !shown) nextPic(); // opened elsewhere or expired: on to the next
}

function nextPic() {
  if (viewer.loading) return;
  const run = viewer.run;
  const next = run && waitingPics().find((m) => !run.seen.has(m.id));
  if (!next) return stopViewer();
  clearViewer(); // the viewer stays up, empty, while the next one loads
  openPic(next);
}

/** Opens and decrypts one direct pic; false if it couldn't be shown. */
async function viewSnap(m) {
  if (![1, 2].includes(m.format ?? 1)) {
    alert("This pic was sent from a newer version of napsack. Reload the page to open it.");
    return false;
  }
  let sealed;
  try {
    sealed = new Uint8Array(await (await api(`/snaps/${m.id}`)).arrayBuffer());
  } catch (err) {
    // 410 means opened elsewhere or expired; the socket will update the chat.
    if (err.status !== 410) alert(err.message);
    return false;
  }
  let pic;
  try {
    pic = await withReadKey(m.sender_id, (k) => e2e.decryptPic(k, sealed, m.format ?? 1, m.sender_id, m.recipient_id));
  } catch {
    alert("This pic couldn't be decrypted.");
    return false;
  }
  showInViewer(new Blob([pic.photo], { type: "image/jpeg" }), personName(m.sender_id, ""), pic.caption);
  return true;
}

function showInViewer(blob, from, caption = "") {
  viewer.url = URL.createObjectURL(blob);
  const v = $("#viewer");
  const img = $("#viewer-image");
  $("#viewer-from").textContent = from;
  $("#viewer-caption").textContent = caption;
  $("#viewer-caption").hidden = !caption;
  // "2 of 3", counting pics that arrive while viewing.
  const run = viewer.run;
  const left = run ? waitingPics().filter((m) => !run.seen.has(m.id)).length : 0;
  const total = (run?.seen.size ?? 1) + left;
  $("#viewer-count").textContent = `${run?.seen.size ?? 1} of ${total}`;
  $("#viewer-count").hidden = total < 2;
  $("#viewer-hint").textContent = left ? "Tap for the next pic" : "Tap to close";
  v.style.setProperty("--view-ms", `${VIEW_MS}ms`);
  img.onload = () => {
    v.classList.add("running");
    viewer.timer = setTimeout(nextPic, VIEW_MS);
  };
  img.src = viewer.url;
  v.hidden = false;
}

function clearViewer() {
  clearTimeout(viewer.timer);
  $("#viewer").classList.remove("running");
  const img = $("#viewer-image");
  img.onload = null;
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
