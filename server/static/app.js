// napsack web client. Plain ES module: no framework, no build step.
// Every API call here is what the future mobile app will make too.
// Texts and snaps are encrypted here before upload; see crypto.js.

import * as e2e from "/crypto.js";

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
  pairKeys: new Map(),         // friend id -> AES key shared with them
  plaintext: new Map(),        // message id -> decrypted text, or null if it couldn't be
  config: null,
  chats: [],
  requests: { incoming: [], outgoing: [] },
  activeId: null,              // friend id of the open chat
  messages: new Map(),         // friend id -> Message[], oldest first; may be only the newest pages
  history: new Map(),          // friend id -> { hasMore, loading } for paging back
  ws: null,
  wsRetry: 0,
};

// ---------- helpers ----------

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

class ApiError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

async function api(path, { method = "GET", json, body, headers = {} } = {}) {
  const h = { ...headers };
  if (state.token) h.Authorization = `Bearer ${state.token}`;
  if (json !== undefined) {
    h["Content-Type"] = "application/json";
    body = JSON.stringify(json);
  }
  let res;
  try {
    res = await fetch(`/api${path}`, { method, headers: h, body, cache: "no-store" });
  } catch {
    throw new ApiError("Can't reach the server. Check your connection.", 0);
  }
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
  if (diag.queue.length > 200) diag.queue.splice(0, diag.queue.length - 200);
  clearTimeout(diag.timer);
  diag.timer = setTimeout(flushReports, level === "error" ? 500 : 5000);
}

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
  if (diag.queue.length) diag.timer = setTimeout(flushReports, 1000);
}

window.addEventListener("pagehide", () => flushReports(true));
window.addEventListener("error", (e) =>
  report("error", "uncaught error", { error: String(e.message), at: `${e.filename?.split("/").pop()}:${e.lineno}` }));
window.addEventListener("unhandledrejection", (e) => report("error", "unhandled rejection", errorFields(e.reason)));

const friendOf = (m) => (m.sender_id === state.me.id ? m.recipient_id : m.sender_id);
const chatById = (id) => state.chats.find((c) => c.id === id);

// ---------- encryption ----------

const pinsKey = () => `pins:${state.me.id}`;

/**
 * Remember each friend's key the first time we see it. If the server later
 * hands out a different one, that chat is blocked: keys never change in
 * napsack, so a new one means someone is trying to listen in.
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
  if (changed) await e2e.saveLocal(pinsKey(), state.pins);
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

/** Adds `text` to a text message: the plaintext, or null if it can't be decrypted. */
async function decrypt(m) {
  if (m.kind !== "text") return m;
  // A newer app wrote this in a scheme this one doesn't know.
  m.unsupported = (m.format ?? 1) !== e2e.FORMAT;
  if (m.unsupported) {
    m.text = null;
    return m;
  }
  if (!state.plaintext.has(m.id)) {
    let text = null;
    try {
      text = await e2e.decryptText(await keyFor(friendOf(m)), m.ciphertext, m.sender_id, m.recipient_id);
    } catch (err) {
      report("warn", "decrypt failed", { message_id: m.id, friend_id: friendOf(m), ...errorFields(err) });
    }
    state.plaintext.set(m.id, text);
  }
  m.text = state.plaintext.get(m.id);
  return m;
}

async function loadIdentity() {
  const id = await e2e.loadLocal(IDENTITY_KEY).catch(() => null);
  if (!id || id.userId !== state.me.id) return false;
  state.identity = id;
  state.pins = (await e2e.loadLocal(pinsKey()).catch(() => null)) || {};
  return true;
}

// ---------- auth ----------

let authMode = "login";

function showAuth() {
  $("#app").hidden = true;
  $("#auth").hidden = false;
  setAuthMode("login");
}

function setAuthMode(mode) {
  authMode = mode;
  const register = mode === "register";
  $("#auth-submit").textContent = register ? "Create account" : "Sign in";
  $("#auth-toggle").textContent = register
    ? "Have an account? Sign in"
    : "New here? Create an account";
  $("#invite-field").hidden = !(register && state.config?.invite_required);
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
          invite_code: state.config?.invite_required ? form.invite_code.value.trim() : undefined,
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
    state.token = res.token;
    state.me = res.user;
    state.identity = { userId: res.user.id, privateKey, publicKey: res.public_key };
    await e2e.saveLocal(IDENTITY_KEY, state.identity);
    state.pins = (await e2e.loadLocal(pinsKey()).catch(() => null)) || {};
    localStorage.setItem(TOKEN_KEY, res.token);
    form.reset();
    report("info", register ? "signed up" : "signed in");
    enterApp();
  } catch (err) {
    report("info", register ? "sign-up failed" : "sign-in failed", errorFields(err));
    $("#auth-error").textContent = err.message;
  } finally {
    submit.disabled = false;
    submit.textContent = label;
  }
});

function signOutLocally() {
  state.token = null;
  state.me = null;
  state.identity = null;
  state.pins = {};
  state.pairKeys.clear();
  state.plaintext.clear();
  state.activeId = null;
  state.messages.clear();
  state.history.clear();
  localStorage.removeItem(TOKEN_KEY);
  e2e.deleteLocal(IDENTITY_KEY).catch(() => {});
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
  $("#signed-in-as").textContent = `Signed in as ${state.me.username}`;
  $("#admin-link").hidden = !state.me.is_admin;
  refreshChats();
  refreshRequests();
  connectSocket();
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
}

let refreshTimer = null;
function refreshChatsSoon() {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refreshChats, 150);
}

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

function renderChatList() {
  const list = $("#chat-list");
  list.replaceChildren(
    ...state.chats.map((chat) => {
      const status = chatStatus(chat);
      const cls = ["chat-item"];
      if (status.marker === "snap") cls.push("has-unread", "has-snap");
      else if (status.marker === "text") cls.push("has-unread");
      return el("li", {},
        el("button", {
          type: "button",
          class: cls.join(" "),
          "aria-current": chat.id === state.activeId ? "true" : null,
          onclick: () => openChat(chat.id),
        },
          el("span", { class: `marker ${status.marker || ""}`, "aria-hidden": "true" }),
          el("span", {},
            el("span", { class: "chat-name", text: chat.username }),
            el("span", { class: "chat-status", text: status.text })),
          el("span", { class: "chat-time", text: chat.last_message ? relTime(chat.last_message.created_at) : "" }),
        ));
    }),
  );
  $("#chat-empty").hidden = state.chats.length > 0;
  const unread = state.chats.reduce((n, c) => n + c.unread, 0);
  document.title = unread ? `(${unread}) ${APP_NAME}` : APP_NAME;
}

// ---------- conversation ----------

async function openChat(friendId) {
  const chat = chatById(friendId);
  if (!chat) return;
  state.activeId = friendId;
  $("#app").classList.add("in-chat");
  $("#chat-placeholder").hidden = true;
  $("#chat").hidden = false;
  $("#chat-title").textContent = chat.username;
  $("#chat-title").setAttribute("aria-label", `${chat.username}: view profile`);
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
  $("#key-warning").hidden = !chat.keyChanged;
  $("#key-warning-name").textContent = chat.username;
  $("#composer-input").disabled = chat.keyChanged;
  $("#composer .send").disabled = chat.keyChanged;
  $("#camera-button").disabled = chat.keyChanged;
}

$("#safety-button").addEventListener("click", async () => {
  const chat = chatById(state.activeId);
  if (!chat) return;
  $("#safety-name").textContent = chat.username;
  $("#safety-name-2").textContent = chat.username;
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
  if ($("#messages").scrollTop < 200 && state.activeId) loadOlder(state.activeId);
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
    else if (!h.hasMore) items.push(el("li", { class: "msg-meta history-edge", text: `This is the beginning of your chat with ${chat?.username ?? "them"}.` }));
  }
  let prevSender = null;
  for (const m of msgs) {
    const mine = m.sender_id === state.me.id;
    if (m.sender_id !== prevSender) {
      items.push(el("li", {
        class: `sender ${mine ? "mine" : ""}`,
        text: `${mine ? "Me" : chat?.username ?? ""}  ${clockTime(m.created_at)}`,
      }));
      prevSender = m.sender_id;
    }
    if (m.kind === "text") {
      items.push(m.text == null
        ? el("li", {
            class: `msg undecryptable ${mine ? "mine" : ""}`,
            text: m.unsupported ? "Sent from a newer version of napsack. Reload to read it." : "Couldn't decrypt this message.",
          })
        : el("li", { class: `msg ${mine ? "mine" : ""}`, text: m.text }));
      if (m.id === lastMineTextId && m.read_at) {
        items.push(el("li", { class: "msg-meta", text: "Seen" }));
      }
    } else {
      const canOpen = !mine && m.snap_state === "pending";
      const chip = canOpen
        ? el("button", { type: "button", class: "snap-chip", onclick: () => viewSnap(m) },
            el("span", { class: "marker snap", "aria-hidden": "true" }), "Tap to view pic")
        : el("span", { class: "snap-chip done" },
            el("span", { class: "marker", "aria-hidden": "true" }), snapLabel(m, mine));
      items.push(el("li", { class: `msg ${mine ? "mine" : ""}` }, chip));
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
  const friendId = state.activeId;
  if (!text || !friendId) return;
  input.value = "";
  try {
    const ciphertext = await e2e.encryptText(await keyFor(friendId), text, state.me.id, friendId);
    const m = await getJSON(`/chats/${friendId}/messages`, { method: "POST", json: { ciphertext, format: e2e.FORMAT } });
    state.plaintext.set(m.id, text);
    await upsertMessage(m);
    if (state.activeId === friendId) renderMessages();
  } catch (err) {
    input.value = text;
    alert(err.message);
  }
});

// ---------- realtime ----------

function connectSocket() {
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
    setTimeout(connectSocket, delay);
  };
}

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
      checkForUpdate();
      // Anything could have happened while disconnected.
      refreshChats();
      refreshRequests();
      if (state.activeId) openChat(state.activeId);
      break;
    case "auth_failed":
      signOutLocally();
      break;
    case "message":
    case "message_updated": {
      const m = ev.message;
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
      refreshChats();
      refreshRequests();
      break;
  }
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

/** A stand-in until profile pictures exist: initial on a tint picked from the id. */
function paintAvatar(node, user) {
  node.textContent = (user.username[0] || "?").toUpperCase();
  node.dataset.tint = String(user.id % 6);
}

function stat(label, value) {
  return [el("dt", { text: label }), el("dd", { text: String(value) })];
}

async function openProfile(userId) {
  const dialog = $("#profile-dialog");
  const msg = $("#profile-message");
  for (const id of ["#profile-stats", "#profile-people", "#profile-actions"]) $(id).replaceChildren();
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
  paintAvatar($("#profile-avatar"), p);
  $("#profile-name").textContent = p.username;

  let people = [];
  if (p.kind === "me") {
    const s = p.stats;
    $("#profile-sub").textContent = `Joined ${longDate(p.joined_at)}`;
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
    $("#profile-sub").textContent = `Friends since ${longDate(p.friends_since)}`;
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
    }, `Message ${p.username}`));
  }

  $("#profile-people-section").hidden = people.length === 0 && p.kind !== "me";
  $("#profile-people").replaceChildren(...people.map((f) => {
    const avatar = el("span", { class: "avatar small", "aria-hidden": "true" });
    paintAvatar(avatar, f);
    return el("li", {},
      el("button", { type: "button", class: "person person-link", onclick: () => openProfile(f.id) },
        avatar,
        el("span", { class: "person-name", text: f.username }),
        el("span", { class: "person-meta", text: `since ${longDate(f.since)}` })));
  }));
}

$("#my-profile").addEventListener("click", () => {
  $("#friends-dialog").close();
  openProfile(state.me.id);
});
$("#chat-title").addEventListener("click", () => { if (state.activeId) openProfile(state.activeId); });

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
  $("#friends-dialog").showModal();
  refreshRequests();
}
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
  const name = chatById(state.activeId)?.username;
  $("#send-snap").textContent = name ? `Send to ${name}` : "Send";
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
  if (!state.activeId) return;
  $("#camera-dialog").showModal();
  showCapture();
  startStream();
});

$("#camera-dialog").addEventListener("close", () => {
  stopStream();
  clearPreview();
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

$("#retake").addEventListener("click", () => {
  showCapture();
  if (!camera.stream) startStream();
});

$("#send-snap").addEventListener("click", async () => {
  const friendId = state.activeId;
  if (!camera.blob || !friendId) return;
  const btn = $("#send-snap");
  btn.disabled = true;
  try {
    const photo = new Uint8Array(await camera.blob.arrayBuffer());
    const sealed = await e2e.encryptSnap(await keyFor(friendId), photo, state.me.id, friendId);
    if (state.config?.snap_max_bytes && sealed.length > state.config.snap_max_bytes) {
      throw new Error("That photo is too large to send.");
    }
    const m = await getJSON(`/chats/${friendId}/snaps?format=${e2e.FORMAT}`, {
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

const viewer = { url: null, timer: null };

async function viewSnap(m) {
  if ((m.format ?? 1) !== e2e.FORMAT) {
    alert("This pic was sent from a newer version of napsack. Reload the page to open it.");
    return;
  }
  let sealed;
  try {
    sealed = new Uint8Array(await (await api(`/snaps/${m.id}`)).arrayBuffer());
  } catch (err) {
    // 410 means opened elsewhere or expired; the socket will update the chat.
    if (err.status !== 410) alert(err.message);
    return;
  }
  let photo;
  try {
    photo = await e2e.decryptSnap(await keyFor(m.sender_id), sealed, m.sender_id, m.recipient_id);
  } catch {
    alert("This pic couldn't be decrypted.");
    return;
  }
  viewer.url = URL.createObjectURL(new Blob([photo], { type: "image/jpeg" }));
  const v = $("#viewer");
  const img = $("#viewer-image");
  $("#viewer-from").textContent = chatById(friendOf(m))?.username || "";
  v.style.setProperty("--view-ms", `${VIEW_MS}ms`);
  img.onload = () => {
    v.classList.add("running");
    viewer.timer = setTimeout(closeViewer, VIEW_MS);
  };
  img.src = viewer.url;
  v.hidden = false;
}

function closeViewer() {
  clearTimeout(viewer.timer);
  const v = $("#viewer");
  v.classList.remove("running");
  v.hidden = true;
  const img = $("#viewer-image");
  img.onload = null;
  img.removeAttribute("src");
  if (viewer.url) URL.revokeObjectURL(viewer.url);
  viewer.url = null;
}

$("#viewer").addEventListener("click", closeViewer);
$("#viewer").addEventListener("contextmenu", (e) => e.preventDefault());
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("#viewer").hidden) closeViewer();
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
  if (state.token) {
    try {
      state.me = await getJSON("/me");
      // A session without its key (cleared site data, another account) can't
      // read anything, so start over with the password.
      if (await loadIdentity()) {
        enterApp();
        return;
      }
    } catch {
      // fall through to sign in
    }
    signOutLocally();
    return;
  }
  showAuth();
})();
