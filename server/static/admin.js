import { chatName, chatSummary, counts, drawGraph, groupLetter, isChat, widthChanged } from "/graph-view.js";
import { markEnvironment, withEnvironment } from "/env.js";

// napsack admin panel. Reads /api/admin/stats with the normal session token;
// the server decides who's an admin. Shows counts only, never content.

const TOKEN_KEY = "fade.token";
const REFRESH_MS = 30_000;

const $ = (sel) => document.querySelector(sel);
const fmt = new Intl.NumberFormat();
const n = (v) => fmt.format(v);

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === "class") node.className = v;
    else if (k === "text") node.textContent = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const c of children.flat()) if (c != null) node.append(c);
  return node;
}

function ago(ts) {
  if (!ts) return "never";
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 120) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  if (s < 30 * 86400) return `${Math.floor(s / 86400)} d ago`;
  return dateLabel(ts);
}

const dateLabel = (ts, opts = { month: "short", day: "numeric" }) =>
  new Date(ts * 1000).toLocaleDateString(undefined, { ...opts, timeZone: "UTC" });

function bytes(b) {
  if (b < 1024) return `${b} B`;
  if (b < 1024 ** 2) return `${(b / 1024).toFixed(1)} KB`;
  return `${(b / 1024 ** 2).toFixed(1)} MB`;
}

function uptime(s) {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}

/** Backups run hourly; more than two hours without one needs a look. */
function backupText(b) {
  if (!b) return "None yet";
  if (!b.ok) return `Failed ${ago(b.at)}: ${b.error}`;
  const overdue = Date.now() / 1000 - b.at > 2 * 3600;
  return `${overdue ? "Overdue, last " : ""}${ago(b.at)} · ${bytes(b.bytes)}`;
}

/** Caps and what the guard turned away since the server started (guard.rs). */
function protectionText(p, users) {
  if (!p) return "—";
  return `${n(users)} of ${n(p.accounts_max)} accounts · ${p.sessions_per_user_max} devices each · ${n(p.banned_addresses)} addresses banned · ${n(p.refused_since_start)} requests refused`;
}

function resourceText(r, kind) {
  if (!r) return "—";
  if (kind === "mem" && r.mem_total_bytes) {
    return `${bytes(r.mem_available_bytes)} free of ${bytes(r.mem_total_bytes)} (app ${bytes(r.app_rss_bytes)})`;
  }
  if (kind === "disk" && r.disk_total_bytes) {
    return `${bytes(r.disk_total_bytes - r.disk_free_bytes)} used of ${bytes(r.disk_total_bytes)}`;
  }
  return "—";
}

function facts(target, rows) {
  $(target).replaceChildren(...rows.flatMap(([k, v]) => [el("dt", { text: k }), el("dd", { text: v })]));
}

// ---------- chart ----------
// One series, so no legend: the panel title names it. Each column is the
// hover/focus target (taller than the bar) and opens a tooltip with the split.

const tip = $("#tip");

function showTip(target, d) {
  tip.replaceChildren(
    el("strong", { text: dateLabel(d.day, { weekday: "short", month: "short", day: "numeric" }) }),
    el("span", { text: `${n(d.texts + d.snaps)} messages` }),
    el("span", { class: "tip-sub", text: `${n(d.texts)} texts · ${n(d.snaps)} pics` }),
    el("span", { class: "tip-sub", text: `${n(d.signups)} sign-up${d.signups === 1 ? "" : "s"}` }),
  );
  tip.hidden = false;
  const r = target.getBoundingClientRect();
  const w = tip.offsetWidth;
  const left = Math.min(window.innerWidth - w - 8, Math.max(8, r.left + r.width / 2 - w / 2));
  tip.style.left = `${left + window.scrollX}px`;
  tip.style.top = `${r.top + window.scrollY - tip.offsetHeight - 8}px`;
}
const hideTip = () => { tip.hidden = true; };

function renderChart(days) {
  const max = Math.max(1, ...days.map((d) => d.texts + d.snaps));
  const cols = days.map((d, i) => {
    const total = d.texts + d.snaps;
    const label = `${dateLabel(d.day)}: ${total} messages`;
    const bar = el("div", { class: `chart-bar${total ? "" : " empty"}` });
    // The CSP forbids style attributes; CSSOM property writes are allowed.
    bar.style.height = `${(total / max) * 100}%`;
    return el("div", {
      class: "chart-col", tabindex: "0", "aria-label": label,
      onmouseenter: (e) => showTip(e.currentTarget, d),
      onfocus: (e) => showTip(e.currentTarget, d),
      onmouseleave: hideTip, onblur: hideTip,
    },
      el("div", { class: "chart-bar-area" }, bar),
      // Every other day keeps labels from colliding on phones; the last day always shows.
      el("span", { class: "chart-x", text: i % 2 === (days.length - 1) % 2 ? dateLabel(d.day) : "" }),
    );
  });
  $("#chart").replaceChildren(
    el("span", { class: "chart-max", text: `${n(max)}` }),
    el("div", { class: "chart-cols" }, cols),
  );
  $("#chart").setAttribute("aria-label", `Messages per day over the last ${days.length} days, peak ${max}.`);

  $("#chart-table").replaceChildren(
    el("thead", {}, el("tr", {}, ["Day", "Texts", "Pics", "Sign-ups"].map((h, i) => el("th", { class: i ? "num" : null, text: h })))),
    el("tbody", {}, days.map((d) => el("tr", {},
      el("td", { text: dateLabel(d.day, { weekday: "short", month: "short", day: "numeric" }) }),
      el("td", { class: "num", text: n(d.texts) }),
      el("td", { class: "num", text: n(d.snaps) }),
      el("td", { class: "num", text: n(d.signups) }),
    ))),
  );
}

// ---------- page ----------

function render(s) {
  const { users: u, messages: m, social, server } = s;
  $("#t-users").textContent = n(u.total);
  $("#t-users-sub").textContent = `+${n(u.new_7d)} this week`;
  $("#t-active").textContent = n(u.active_24h);
  $("#t-active-sub").textContent = `${n(u.active_7d)} this week`;
  $("#t-online").textContent = n(u.online);
  $("#t-online-sub").textContent = `${n(u.sockets)} open connection${u.sockets === 1 ? "" : "s"}`;
  $("#t-texts").textContent = n(m.texts);
  $("#t-texts-sub").textContent = `+${n(m.texts_24h)} today`;
  $("#t-snaps").textContent = n(m.snaps);
  $("#t-snaps-sub").textContent = `+${n(m.snaps_24h)} today`;

  renderChart(m.daily);

  const viewed = m.snaps_opened + m.snaps_expired;
  facts("#snap-facts", [
    ["Waiting to be opened", n(m.snaps_pending)],
    ["Opened", n(m.snaps_opened)],
    ["Expired unopened", n(m.snaps_expired)],
    ["Open rate", viewed ? `${Math.round((m.snaps_opened / viewed) * 100)}%` : "—"],
    ["Group pics on disk", `${n(server.group_pics_pending)} · ${bytes(server.group_pic_bytes)} of ${bytes(server.group_pic_disk_bytes)}`],
    ["Direct pics on disk", `${n(server.snaps_waiting)} · ${bytes(server.snap_bytes_waiting)} of ${bytes(server.snap_disk_bytes)}`],
  ]);
  facts("#social-facts", [
    ["Friendships", n(social.friendships)],
    ["Pending requests", n(social.pending_requests)],
    ["Groups", `${n(social.groups)} · ${n(social.group_messages)} messages`],
    ["Active sessions", n(social.active_sessions)],
    ["Avg friends per user", u.total ? (social.friendships * 2 / u.total).toFixed(1) : "—"],
  ]);
  facts("#server-facts", [
    ["Version", `${server.version} (${server.build})`],
    ["Uptime", uptime(server.uptime_secs)],
    ["Database", bytes(server.db_bytes)],
    ["Pic lifetime", server.snap_ttl_hours % 24 ? `${server.snap_ttl_hours} h` : `${server.snap_ttl_hours / 24} days`],
    ["Sign-up", server.invite_required ? "Invite code required" : "Open"],
    ["Last backup", backupText(server.backup)],
    ["Memory", resourceText(server.resources, "mem")],
    ["Data disk", resourceText(server.resources, "disk")],
    ["Load (1 min)", server.resources?.load_1m ?? "—"],
    ["Protection", protectionText(server.protection, u.total)],
  ]);

  // Admins only (roles.md): the server doesn't send the list to PowerUsers.
  $("#users-panel").hidden = !u.list;
  $("#users").replaceChildren(...(u.list ?? []).map((x) => el("tr", {},
    el("td", { text: x.username }),
    el("td", { text: dateLabel(x.created_at, { year: "numeric", month: "short", day: "numeric" }) }),
    el("td", { text: ago(x.last_seen_at) }),
    el("td", { class: "num", text: n(x.friends) }),
    el("td", { class: "num", text: n(x.texts_sent) }),
    el("td", { class: "num", text: n(x.snaps_sent) }),
    el("td", {}, el("button", { type: "button", class: "reset-button", onclick: (e) => resetUser(e.currentTarget, x) },
      x.id === pendingReset ? "Tap again: issue a reset code" : "Reset password")),
  )));
  if (u.list && !u.list.length) $("#users").append(el("tr", {}, el("td", { colspan: "7", class: "muted", text: "No users yet." })));

  $("#updated").textContent = `Updated ${new Date(s.generated_at * 1000).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
}

// For someone who lost their password and their recovery key. Two taps; the
// code is shown once, here, for the admin to hand over in person. The first
// tap is remembered by user, not on the button, so the list refreshing in
// between (it does every 30 seconds) doesn't lose it.
let pendingReset = null;
async function resetUser(btn, user) {
  if (pendingReset !== user.id) {
    pendingReset = user.id;
    btn.textContent = "Tap again: issue a reset code";
    return;
  }
  pendingReset = null;
  btn.disabled = true;
  const out = $("#reset-result");
  try {
    const res = await fetch(`/api/admin/users/${user.id}/reset-code`, {
      method: "POST", headers: { Authorization: `Bearer ${localStorage.getItem(TOKEN_KEY)}` }, cache: "no-store",
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
    const until = new Date(body.expires_at * 1000).toLocaleString(undefined, { weekday: "short", hour: "numeric", minute: "2-digit" });
    out.replaceChildren(
      el("p", {}, el("strong", { text: `Reset code for ${body.username}` })),
      el("p", { class: "reset-code", text: body.code }),
      el("p", { class: "muted", text: `Works once, until ${until}. Give it to them in person or on a call, not in a napsack chat they can't open. They'll get their account and friends back with a new password, but messages from before can't be read, and their friends will see a new safety code. If they still have their recovery key, they should use that instead: it keeps everything.` }),
    );
    out.hidden = false;
    out.scrollIntoView({ block: "nearest" });
  } catch (err) {
    out.replaceChildren(el("p", { text: `Couldn't issue a code: ${err.message}` }));
    out.hidden = false;
  } finally {
    btn.disabled = false;
    btn.textContent = "Reset password";
  }
}

function fail(text) {
  $("#admin").hidden = true;
  const msg = $("#message");
  msg.hidden = false;
  msg.replaceChildren(text, " ", el("a", { href: "/", text: "Go to napsack" }));
}

async function load() {
  const token = localStorage.getItem(TOKEN_KEY);
  if (!token) return fail("Sign in first.");
  let res;
  try {
    res = await fetch("/api/admin/stats", { headers: { Authorization: `Bearer ${token}` }, cache: "no-store" });
  } catch {
    $("#updated").textContent = "Offline. Retrying…";
    return;
  }
  if (res.status === 401) return fail("Your session ended. Sign in again.");
  if (!res.ok) return fail("This page isn't available.");
  render(await res.json());
  $("#message").hidden = true;
  $("#admin").hidden = false;
  connectPresence();
}

// Looking at this page counts as being online, like having the app open, so
// "Online now" includes whoever is looking at it. (Before, the page held no
// connection, and an admin checking from the Home Screen app, where /admin
// replaces the app, saw 0 while plainly online.) The socket never says the
// page is on screen, so notifications for new messages still arrive.
let presence = null;
function connectPresence() {
  const token = localStorage.getItem(TOKEN_KEY);
  if (!token || (presence && presence.readyState <= WebSocket.OPEN)) return;
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/api/ws`);
  presence = ws;
  ws.onopen = () => ws.send(JSON.stringify({ type: "auth", token }));
  ws.onmessage = (e) => {
    // Once the server counts this connection, show the count that includes it.
    try {
      if (JSON.parse(e.data).type === "ready" && currentTab() === "overview") load();
    } catch {}
  };
  ws.onclose = () => setTimeout(() => { if (visible()) connectPresence(); }, 5000);
}

// ---------- logs ----------
// Newest first. "Live" polls for entries newer than the top row; "Load older"
// pages back. The server keeps a fixed number of entries since its last start.

const LOG_PAGE = 200;
const LOG_DOM_CAP = 2000;
const TAIL_MS = 3000;
const logs = { entries: [], loaded: false, busy: false };

function logClock(ms) {
  const d = new Date(ms);
  const time = d.toLocaleTimeString(undefined, { hour12: false });
  const today = d.toDateString() === new Date().toDateString();
  const day = today ? "" : `${d.toLocaleDateString(undefined, { month: "short", day: "numeric" })} `;
  return `${day}${time}.${String(d.getMilliseconds()).padStart(3, "0")}`;
}

/** "fade_server::auth" -> "auth"; "client::web" -> "web app". */
function logSource(target) {
  if (target.startsWith("client::")) return `${target.slice(8)} app`;
  return target.replace(/^fade_server::?/, "") || "server";
}

function logRow(e) {
  const level = e.level.toLowerCase();
  return el("tr", { class: `log-${level}` },
    el("td", { class: "log-time", text: logClock(e.ts) }),
    el("td", {}, el("span", { class: `log-level log-level-${level}`, text: e.level })),
    el("td", {},
      el("div", { class: "log-msg" }, e.message || "(no message)", " ",
        el("span", { class: `log-target${e.target.startsWith("client::") ? " log-client" : ""}`, text: logSource(e.target) })),
      e.fields.length
        ? el("div", { class: "log-fields" }, e.fields.map(([k, v]) =>
            el("span", { class: "log-field" }, el("b", { text: k }), `=${v}`)))
        : null,
    ),
  );
}

function renderLogs(meta) {
  if (logs.entries.length > LOG_DOM_CAP) logs.entries.length = LOG_DOM_CAP;
  $("#log-rows").replaceChildren(...logs.entries.map(logRow));
  if (!logs.entries.length) {
    $("#log-rows").append(el("tr", {}, el("td", { colspan: "3", class: "muted", text: "No matching entries." })));
  }
  if (meta) {
    const since = new Date(meta.since_ms).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
    $("#logs-note").textContent =
      `Last ${n(meta.capacity)} entries since the server started (${since}). Older: journalctl -u fade.`;
    const oldestShown = logs.entries.at(-1)?.seq ?? 0;
    $("#log-older").hidden = !(oldestShown > meta.oldest_seq);
  }
  $("#log-count").textContent = `${n(logs.entries.length)} shown`;
}

async function fetchLogs(params) {
  const token = localStorage.getItem(TOKEN_KEY);
  if (!token) { fail("Sign in first."); return null; }
  const qs = new URLSearchParams({ limit: String(LOG_PAGE) });
  const q = $("#log-q").value.trim();
  const level = $("#log-level").value;
  const source = $("#log-source").value;
  if (q) qs.set("q", q);
  if (source) qs.set("source", source);
  if (level) qs.set("level", level);
  for (const [k, v] of Object.entries(params)) qs.set(k, String(v));
  let res;
  try {
    res = await fetch(`/api/admin/logs?${qs}`, { headers: { Authorization: `Bearer ${token}` }, cache: "no-store" });
  } catch {
    $("#log-count").textContent = "Offline. Retrying…";
    return null;
  }
  if (res.status === 401) { fail("Your session ended. Sign in again."); return null; }
  if (!res.ok) { fail("This page isn't available."); return null; }
  return res.json();
}

async function loadLogs(mode = "reset") {
  if (logs.busy) return;
  logs.busy = true;
  try {
    const params = {};
    if (mode === "tail" && logs.entries.length) params.after = logs.entries[0].seq;
    if (mode === "older" && logs.entries.length) params.before = logs.entries.at(-1).seq;
    const data = await fetchLogs(params);
    if (!data) return;
    if (mode === "reset") logs.entries = data.entries;
    else if (mode === "older") logs.entries.push(...data.entries);
    else logs.entries.unshift(...data.entries);
    logs.loaded = true;
    renderLogs(data);
    $("#message").hidden = true;
    $("#admin").hidden = false;
  } finally {
    logs.busy = false;
  }
}

let searchTimer = null;
$("#log-q").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => loadLogs("reset"), 300);
});
$("#log-controls").addEventListener("submit", (e) => { e.preventDefault(); loadLogs("reset"); });
$("#log-level").addEventListener("change", () => loadLogs("reset"));
$("#log-source").addEventListener("change", () => loadLogs("reset"));
$("#log-older").addEventListener("click", () => loadLogs("older"));
$("#log-live").addEventListener("change", () => { if ($("#log-live").checked) loadLogs("tail"); });

// ---------- metrics ----------
// /api/admin/metrics: readings every 10 seconds for the last hour, each minute
// as min/avg/max beyond that (metrics.rs). Each chart is one measure (small
// multiples, never two scales on one chart): the line is the average, the
// faint band around it the range within each point, so spikes stay visible.
// Dashed lines are limits and references. Hover for exact values; every
// figure is also in the table.

const SVG = "http://www.w3.org/2000/svg";
const metrics = { hours: 24, host: null, data: null, loadedAt: 0, busy: false };

function svg(tag, attrs = {}) {
  const node = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  return node;
}

const usd = (x) => `$${x < 10 ? x.toFixed(2) : x.toFixed(0)}`;

/** Bytes up to GB (the overview's `bytes` stops at MB). */
function size(b) {
  if (b >= 1024 ** 3) return `${(b / 1024 ** 3).toFixed(b >= 10 * 1024 ** 3 ? 0 : 1)} GB`;
  if (b >= 1024 ** 2) return `${Math.round(b / 1024 ** 2)} MB`;
  return bytes(b);
}

function fmtValue(unit, x) {
  if (x == null || !Number.isFinite(x)) return "—";
  const zero = { "%": "0%", ms: "0 ms", "/s": "0/s", "/min": "0/min", "": "0" }[unit];
  if (x === 0 && zero) return zero;
  switch (unit) {
    case "%": return `${x < 10 ? x.toFixed(1) : Math.round(x)}%`;
    case "bytes": return size(Math.round(x));
    case "B/s": return `${size(Math.round(x))}/s`;
    case "ms": return `${x < 10 ? x.toFixed(1) : Math.round(x)} ms`;
    case "/s": return `${x < 10 ? x.toFixed(1) : Math.round(x)}/s`;
    case "/min": return `${x < 10 ? x.toFixed(1) : n(Math.round(x))}/min`;
    default: return x < 10 ? x.toFixed(1).replace(/\.0$/, "") : n(Math.round(x));
  }
}

/** [min, avg, max] of a stored figure, or of the sum of several. */
const fig = (...keys) => (p) => {
  const parts = keys.map((k) => p.v[k]).filter(Boolean);
  if (parts.length !== keys.length) return null;
  return [0, 1, 2].map((i) => parts.reduce((a, x) => a + x[i], 0));
};

/** The charts, in order. `series` are [name, getter]; at most two, in fixed colors. */
function chartSpecs(host) {
  const est = host.estimate || {};
  const disks = Object.keys(host.info.disks || {});
  const diskName = (d) => (d === "system" ? "System" : "Data");
  const specs = [
    {
      title: "CPU", unit: "%", max: 100,
      note: "Share of the whole machine",
      series: [["Machine", fig("cpu")], ["napsack server", fig("app_cpu")]],
      refs: est.cpu_baseline_pct ? [{ y: est.cpu_baseline_pct, label: `Free baseline ${est.cpu_baseline_pct}%` }] : [],
    },
  ];
  if (host.credits?.points?.length) {
    specs.push({
      title: "CPU credits", unit: "", note: "Above zero, CPU over the baseline is free",
      // CloudWatch's points are 5-minute averages starting at t.
      points: host.credits.points.map(([t, b]) => ({ t, s: 300, v: { credits: [b, b, b] } })),
      series: [["Balance", fig("credits")]],
      refs: est.credit_max ? [{ y: est.credit_max, label: `Full (${est.credit_max})` }] : [],
    });
  }
  specs.push(
    {
      title: "Memory", unit: "%", max: 100, note: `Of ${size(host.info.mem_total || 0)}`,
      series: [["Used", fig("mem")]], refs: [{ y: 80, label: "80%" }],
    },
    {
      title: "Server memory", unit: "bytes", note: "What the napsack server holds",
      series: [["napsack server", fig("app_mem")]],
      refs: host.info.app_mem_limit ? [{ y: host.info.app_mem_limit, label: `Limit ${size(host.info.app_mem_limit)}` }] : [],
    },
    {
      title: "Disk space", unit: "%", max: 100, note: disks.map((d) => `${diskName(d)} ${size(host.info.disks[d])}`).join(" · "),
      series: disks.map((d) => [diskName(d), fig(`disk_${d}`)]), refs: [{ y: 80, label: "80%" }],
    },
    {
      title: "Disk activity", unit: "/s", note: "Reads and writes per second",
      series: disks.map((d) => [diskName(d), fig(`reads_${d}`, `writes_${d}`)]),
    },
    { title: "Network", unit: "B/s", series: [["In", fig("net_in")], ["Out", fig("net_out")]] },
    { title: "Requests", unit: "/min", series: [["Requests", fig("requests")]] },
    {
      title: "Response time", unit: "ms", note: "Half of requests are faster than p50; 95% faster than p95",
      series: [["p50", fig("p50")], ["p95", fig("p95")]],
    },
    { title: "Live connections", unit: "", note: "Open app connections", series: [["Connections", fig("sockets")]] },
  );
  return specs;
}

/** A round number at or above x, for the top of a chart. */
function niceMax(x) {
  if (!(x > 0)) return 1;
  const p = 10 ** Math.floor(Math.log10(x));
  return [1, 2, 2.5, 5, 10].map((m) => m * p).find((m) => m >= x);
}

function clockLabel(t, long) {
  const d = new Date(t * 1000);
  const time = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return long ? `${d.toLocaleDateString(undefined, { weekday: "short" })} ${time}` : time;
}

/** Where a point is drawn: the middle of the time it covers (`t` to `t + s`). */
const mid = (p) => p.t + (p.s ?? 0) / 2;

/** "Thu 10:40–10:46 PM" for a span, "Thu 10:40:20 PM" for a 10-second reading (when it was taken). */
function spanLabel(p) {
  const d = (t, opts) => new Date(t * 1000).toLocaleTimeString(undefined, opts);
  const day = new Date(p.t * 1000).toLocaleDateString(undefined, { weekday: "short" });
  if ((p.s ?? 0) < 60) return `${day} ${d(p.t + (p.s ?? 0), { hour: "numeric", minute: "2-digit", second: "2-digit" })}`;
  return `${day} ${d(p.t, { hour: "numeric", minute: "2-digit" })}–${d(p.t + p.s, { hour: "numeric", minute: "2-digit" })}`;
}

/**
 * Splits points where readings are missing (the server was down, or before
 * metrics existed), so lines don't bridge time with no readings. A gap is a
 * hole between one point's end and the next one's start longer than either
 * point (with a little slack for timer jitter).
 */
function segments(points, get) {
  const out = [];
  let run = [];
  let prev = null;
  for (const p of points) {
    const v = get(p);
    const hole = prev ? p.t - (prev.t + (prev.s ?? 0)) : 0;
    if (!v || hole > Math.max(prev?.s ?? 0, p.s ?? 0, 10) + 2) {
      if (run.length) out.push(run);
      run = [];
    }
    if (v) run.push([mid(p), v]);
    if (v) prev = p;
  }
  if (run.length) out.push(run);
  return out;
}

function drawChart(box, spec, points, range) {
  const W = Math.max(260, box.clientWidth), H = 170;
  const m = { l: 46, r: 10, t: 10, b: 24 };
  const [t0, t1] = range;
  const series = spec.series.map(([name, get], i) => ({ name, get, cls: `series-${i + 1}` }));
  const all = series.flatMap((s) => points.map(s.get).filter(Boolean));
  const peak = Math.max(0, ...all.map((v) => v[2]), ...(spec.refs || []).map((r) => r.y));
  const yMax = spec.max ?? niceMax(peak * 1.05);
  const x = (t) => m.l + ((t - t0) / Math.max(1, t1 - t0)) * (W - m.l - m.r);
  const y = (v) => m.t + (1 - Math.min(v, yMax) / yMax) * (H - m.t - m.b);

  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, class: "mchart-svg", "aria-hidden": "true" });
  for (const f of [0, 0.5, 1]) {
    root.append(svg("line", { x1: m.l, x2: W - m.r, y1: y(yMax * f), y2: y(yMax * f), class: "mgrid" }));
    const label = svg("text", { x: m.l - 6, y: y(yMax * f) + 4, class: "maxis", "text-anchor": "end" });
    label.textContent = fmtValue(spec.unit, yMax * f);
    root.append(label);
  }
  // A day or more: the times repeat, so name the day.
  const long = t1 - t0 >= 86_400;
  [[t0, "start"], [(t0 + t1) / 2, "middle"], [t1, "end"]].forEach(([t, anchor]) => {
    const label = svg("text", { x: x(t), y: H - 6, class: "maxis", "text-anchor": anchor });
    label.textContent = clockLabel(t, long);
    root.append(label);
  });
  for (const ref of spec.refs || []) {
    if (ref.y > yMax) continue;
    root.append(svg("line", { x1: m.l, x2: W - m.r, y1: y(ref.y), y2: y(ref.y), class: "mref" }));
    const label = svg("text", { x: W - m.r - 2, y: y(ref.y) - 4, class: "mref-label", "text-anchor": "end" });
    label.textContent = ref.label;
    root.append(label);
  }
  for (const s of series) {
    for (const run of segments(points, s.get)) {
      const top = run.map(([t, v]) => `${x(t).toFixed(1)},${y(v[2]).toFixed(1)}`);
      const bottom = run.slice().reverse().map(([t, v]) => `${x(t).toFixed(1)},${y(v[0]).toFixed(1)}`);
      root.append(svg("polygon", { points: [...top, ...bottom].join(" "), class: `mband ${s.cls}` }));
      const line = run.map(([t, v], i) => `${i ? "L" : "M"}${x(t).toFixed(1)},${y(v[1]).toFixed(1)}`).join("");
      // A lone reading still shows, as a dot.
      root.append(run.length > 1
        ? svg("path", { d: line, class: `mline ${s.cls}` })
        : svg("circle", { cx: x(run[0][0]), cy: y(run[0][1][1]), r: 3, class: `mdot ${s.cls}` }));
    }
  }

  // Hover: a hairline at the nearest reading, and its values.
  const cross = svg("line", { y1: m.t, y2: H - m.b, class: "mcross", visibility: "hidden" });
  const hit = svg("rect", { x: m.l, y: 0, width: W - m.l - m.r, height: H, class: "mhit" });
  root.append(cross, hit);
  const hide = () => { cross.setAttribute("visibility", "hidden"); hideTip(); };
  hit.addEventListener("pointerleave", hide);
  hit.addEventListener("pointermove", (e) => {
    if (!points.length) return;
    const r = root.getBoundingClientRect();
    const t = t0 + ((e.clientX - r.left) * (W / r.width) - m.l) / (W - m.l - m.r) * (t1 - t0);
    const p = points.reduce((best, q) => (Math.abs(mid(q) - t) < Math.abs(mid(best) - t) ? q : best));
    cross.setAttribute("x1", x(mid(p)));
    cross.setAttribute("x2", x(mid(p)));
    cross.setAttribute("visibility", "visible");
    tip.replaceChildren(
      el("strong", { text: spanLabel(p) }),
      ...series.map((s) => {
        const v = s.get(p);
        const spread = v && v[2] - v[0] > 1e-9 ? ` (${fmtValue(spec.unit, v[0])}–${fmtValue(spec.unit, v[2])})` : "";
        return el("span", {}, el("i", { class: `mswatch ${s.cls}`, "aria-hidden": "true" }),
          `${s.name}: ${v ? fmtValue(spec.unit, v[1]) : "—"}`, el("span", { class: "tip-sub", text: spread }));
      }),
    );
    tip.hidden = false;
    const w = tip.offsetWidth;
    tip.style.left = `${Math.min(window.innerWidth - w - 8, Math.max(8, e.clientX - w / 2)) + window.scrollX}px`;
    tip.style.top = `${r.top + window.scrollY - tip.offsetHeight - 6}px`;
  });
  return root;
}

/**
 * Latest, average and peak of a series over the range, for headers and the
 * table. The average is weighted by the time each point covers, so a
 * 10-second reading counts a sixth as much as a stored minute.
 */
function summarize(points, get) {
  const vs = points.map((p) => [get(p), p.s || 1]).filter(([v]) => v);
  if (!vs.length) return null;
  const secs = vs.reduce((a, [, s]) => a + s, 0);
  return {
    now: vs.at(-1)[0][1],
    avg: vs.reduce((a, [v, s]) => a + v[1] * s, 0) / secs,
    peak: Math.max(...vs.map(([v]) => v[2])),
  };
}

const STATUS = {
  ok: { label: "All good", icon: "M7 12.5l3.5 3.5L17 9" },
  watch: { label: "Worth watching", icon: "M12 7v6M12 16.5v.5" },
  red: { label: "In the red", icon: "M8.5 8.5l7 7M15.5 8.5l-7 7" },
};

function statusBadge(level, label = null) {
  const s = STATUS[level] || STATUS.ok;
  const icon = svg("svg", { viewBox: "0 0 24 24", "aria-hidden": "true" });
  icon.append(svg("circle", { cx: 12, cy: 12, r: 10 }), svg("path", { d: s.icon }));
  return el("span", { class: `mstatus mstatus-${level}` }, icon, label ?? s.label);
}

function hostLabel(h) {
  const i = h.info;
  const parts = [i.instance ? `${i.instance.instance_type} · ${i.instance.zone}` : h.host];
  parts.push(`${i.vcpus} vCPU${i.vcpus === 1 ? "" : "s"}`, `${size(i.mem_total || 0)} memory`);
  return parts.join(" · ");
}

function renderStatus(data) {
  $("#m-status").replaceChildren(...data.hosts.map((h) => el("div", { class: "mhost" },
    el("div", { class: "mhost-head" }, statusBadge(h.status), el("span", { class: "panel-note", text: hostLabel(h) })),
    h.reasons.length
      ? el("ul", { class: "mreasons" }, h.reasons.map((r) => el("li", { text: r })))
      : el("p", { class: "muted", text: "Memory, disks, CPU, response times and errors are all comfortably inside their limits." }),
  )));
}

function monthName(ymd) {
  return new Date(`${ymd}T12:00:00Z`).toLocaleDateString(undefined, { month: "long", timeZone: "UTC" });
}

function renderCost(data) {
  // Cost is Admins' only (roles.md); the server sends none to PowerUsers.
  $("#m-cost").closest(".panel").hidden = data.cost_visible === false;
  if (data.cost_visible === false) return;
  const out = [];
  const est = data.hosts.find((h) => h.host === metrics.host)?.estimate;
  if (est) {
    out.push(
      el("p", { class: "mcost-total" }, el("strong", { text: usd(est.total) }), " a month at today's rate"),
      el("dl", { class: "facts" }, est.lines.flatMap((l) => [el("dt", { text: l.name }), el("dd", { text: l.usd == null ? "—" : usd(l.usd) })])),
    );
    if (est.s3?.length) {
      const what = (b) => (b.includes("-backups-") ? "backups" : "releases");
      const cls = (c) => (c === "StandardStorage" ? "" : " (Glacier)");
      out.push(el("p", { class: "panel-note", text: `S3 holds ${est.s3.map((x) => `${what(x.bucket)}${cls(x.class)} ${size(x.gb * 1024 ** 3)}`).join(" · ")}. EBS snapshots add a few cents.` }));
    }
    const server = est.lines.find((l) => l.name === "Server")?.usd;
    if (est.next) {
      const more = server == null ? "" : `, ${usd(est.next.usd - server)} more`;
      out.push(el("p", { class: "panel-note", text: `Next size up: ${est.next.instance_type}, ${usd(est.next.usd)} a month for the server${more}, with a free CPU baseline of ${est.next.cpu_baseline_pct}%.` }));
    }
  } else if (!data.on_aws) {
    out.push(el("p", { class: "muted", text: "Cost shows when the server runs on AWS." }));
  }
  const months = data.billing?.months || [];
  if (months.some((mo) => mo.total > 0)) {
    for (const mo of months.slice().reverse()) {
      const current = mo.end > new Date().toISOString().slice(0, 10);
      out.push(el("p", { class: "mcost-billed" },
        el("strong", { text: `${monthName(mo.start)}${current ? " so far" : ""}: ${usd(mo.total)}` }),
        mo.estimated ? " (AWS's running estimate)" : " (billed)"));
      if (mo.services.length) {
        // Every service with a cent or more (S3, snapshots under "EC2 - Other", ...), largest first.
        out.push(el("p", { class: "panel-note", text: mo.services.map((s) => `${s.service.replace(/^Amazon |^AWS /, "")} ${usd(s.usd)}`).join(" · ") }));
      }
    }
    out.push(el("p", { class: "panel-note", text: `From AWS Cost Explorer, everything tagged App=fade. Checked ${ago(data.billing.fetched_at)}.` }));
  } else if (data.on_aws && data.billing_read === false) {
    out.push(el("p", { class: "panel-note", text: "Billed amounts are read in production only. This copy's own resources are tagged App=fade-staging in AWS Billing." }));
  } else if (data.on_aws && !data.aws_problems?.["reading the bill from Cost Explorer"]) {
    out.push(el("p", { class: "panel-note", text: "No billed amounts tagged App=fade yet. AWS counts tagged costs from when the App cost tag was turned on (October 23, 2026, backfilled to October 1), and Cost Explorer shows them about a day later." }));
  }
  // Usually a missing permission on the instance's role (infra/main.tf: ReadCpuCredits, ReadCosts).
  for (const [what, error] of Object.entries(data.aws_problems || {})) {
    out.push(el("p", { class: "panel-note mcost-problem", text: `Couldn't finish ${what}: ${error}. If it says AccessDenied, the server's AWS role needs the permissions in infra/main.tf (ReadCpuCredits, ReadCosts).` }));
  }
  $("#m-cost").replaceChildren(...out);
}

function renderMetrics() {
  const data = metrics.data;
  if (!data) return;
  if (!data.hosts.some((h) => h.host === metrics.host)) metrics.host = data.hosts[0]?.host ?? null;
  const select = $("#m-host");
  select.hidden = data.hosts.length < 2;
  select.replaceChildren(...data.hosts.map((h) => el("option", { value: h.host, text: hostLabel(h) })));
  select.value = metrics.host ?? "";

  const ranges = [1, 24, data.retention_hours].filter((h, i, a) => h <= data.retention_hours && a.indexOf(h) === i);
  $("#m-range").replaceChildren(...ranges.map((h) => el("button", {
    type: "button", class: "segment", "aria-pressed": String(h === data.hours), "data-hours": h,
    onclick: () => pickRange(h),
  }, h === 1 ? "1 hour" : h % 24 ? `${h} hours` : h === 24 ? "24 hours" : `${h / 24} days`)));

  renderStatus(data);
  renderCost(data);

  const host = data.hosts.find((h) => h.host === metrics.host);
  if (!host) {
    $("#m-charts").replaceChildren(el("p", { class: "muted", text: "No readings yet. The first arrive 20 seconds after the server starts." }));
    return;
  }
  // After a restart the last hour is per-minute up to the restart, then every 10 seconds.
  const restarted = data.hours === 1 && host.series.some((p) => p.s >= 60);
  $("#m-note").textContent = data.hours !== 1 ? "Each point: a minute or more (average, with its range)"
    : restarted ? "Every 10 seconds since the server restarted; each minute before that" : "Every 10 seconds";
  const range = [data.generated_at - data.hours * 3600, data.generated_at];
  const rows = [];
  $("#m-charts").replaceChildren(...chartSpecs(host).map((spec) => {
    // Only what's inside the range: CPU credits come from CloudWatch for the
    // whole retention window whatever the range, and anything outside it
    // would be drawn past the chart's edge and stretch its scale.
    const points = (spec.points ?? host.series).filter((p) => mid(p) >= range[0] && mid(p) <= range[1]);
    const box = el("section", { class: "panel mchart" });
    const sums = spec.series.map(([name, get]) => [name, summarize(points, get)]);
    for (const [name, sum] of sums) rows.push([spec.title, name, spec.unit, sum]);
    const legend = sums.length > 1
      ? el("div", { class: "mlegend" }, sums.map(([name, sum], i) => el("span", {},
          el("i", { class: `mswatch series-${i + 1}`, "aria-hidden": "true" }), `${name} `, el("b", { text: fmtValue(spec.unit, sum?.now) }))))
      : el("span", { class: "mnow", text: fmtValue(spec.unit, sums[0]?.[1]?.now) });
    box.append(el("header", { class: "panel-head" }, el("h2", { text: spec.title }), legend));
    if (spec.note) box.append(el("p", { class: "panel-note mchart-note", text: spec.note }));
    const plot = el("div", { class: "mplot", role: "img",
      "aria-label": `${spec.title}: ${sums.map(([name, s]) => `${name} now ${fmtValue(spec.unit, s?.now)}, peak ${fmtValue(spec.unit, s?.peak)}`).join("; ")}` });
    box.append(plot);
    // Drawn once the box has its width.
    requestAnimationFrame(() => plot.replaceChildren(drawChart(plot, spec, points, range)));
    return box;
  }));

  $("#m-table").replaceChildren(
    el("thead", {}, el("tr", {}, ["Chart", "Line", "Now", "Average", "Peak"].map((h, i) => el("th", { class: i > 1 ? "num" : null, text: h })))),
    el("tbody", {}, rows.map(([title, name, unit, s]) => el("tr", {},
      el("td", { text: title }), el("td", { text: name }),
      ...["now", "avg", "peak"].map((k) => el("td", { class: "num", text: fmtValue(unit, s?.[k]) })),
    ))),
  );
}

// One load at a time. A range picked mid-load gets its own load right after,
// and an answer for a range no longer picked is dropped, so the charts always
// match the highlighted button.
async function loadMetrics() {
  if (metrics.busy) {
    metrics.again = true;
    return;
  }
  metrics.busy = true;
  try {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) return fail("Sign in first.");
    const hours = metrics.hours;
    let res;
    try {
      res = await fetch(`/api/admin/metrics?hours=${hours}`, { headers: { Authorization: `Bearer ${token}` }, cache: "no-store" });
    } catch {
      $("#m-note").textContent = "Offline. Retrying…";
      return;
    }
    if (res.status === 401) return fail("Your session ended. Sign in again.");
    if (!res.ok) return fail("This page isn't available.");
    const data = await res.json();
    if (hours !== metrics.hours) return;
    metrics.data = data;
    metrics.loadedAt = Date.now();
    $("#message").hidden = true;
    $("#admin").hidden = false;
    renderMetrics();
    loadIncidents();
  } finally {
    metrics.busy = false;
    if (metrics.again) {
      metrics.again = false;
      loadMetrics();
    }
  }
}

function pickRange(hours) {
  metrics.hours = hours;
  // The button lights up at once; the charts follow when the data arrives.
  for (const b of document.querySelectorAll("#m-range .segment")) {
    b.setAttribute("aria-pressed", String(Number(b.dataset.hours) === hours));
  }
  loadMetrics();
}

$("#m-host").addEventListener("change", (e) => { metrics.host = e.target.value; renderMetrics(); });
let resizeTimer = null;

// ---------- incidents (Admins only; plan X18, docs/implementation/health-monitor.md) ----------
// What the health monitor found and did, from its records in S3: the last
// 7 days, open ones first. An Admin can mark one resolved; the monitor's own
// record is never changed.

const incidents = { data: null, confirm: null, loadedAt: 0 };
// state → [badge level, words]
const INCIDENT_STATES = {
  open: ["red", "Open"],
  needs_human: ["red", "Needs a person"],
  recovered: ["ok", "Recovered"],
  resolved: ["ok", "Marked resolved"],
};
const agoIso = (iso) => (iso ? ago(Date.parse(iso) / 1000) : "");
const clock = (iso) => (iso ? new Date(iso).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "");

function lasted(a, b) {
  const s = Math.max(0, (Date.parse(b) - Date.parse(a)) / 1000);
  if (s < 3600) return `${Math.max(1, Math.round(s / 60))} min`;
  if (s < 86400) return `${Math.round(s / 360) / 10} h`;
  return `${Math.round(s / 8640) / 10} days`;
}

async function loadIncidents(force = false) {
  const panel = $("#m-incidents-panel");
  panel.hidden = viewer?.role !== "admin";
  if (panel.hidden) return;
  // The Metrics tab refreshes often; the records change at most every 5 minutes.
  if (!force && incidents.data && Date.now() - incidents.loadedAt < 60_000) return;
  try {
    incidents.data = await api("/admin/incidents");
    incidents.loadedAt = Date.now();
  } catch (err) {
    $("#m-incidents").replaceChildren(el("p", { class: "muted", text: `Couldn't load incidents: ${err.message}` }));
    return;
  }
  renderIncidents();
}

function renderIncidents() {
  const data = incidents.data;
  if (!data) return;
  const host = $("#m-incidents");
  if (!data.available) {
    host.replaceChildren(el("p", { class: "muted", text: "There's no health monitor here: it watches the server on AWS." }));
    return;
  }
  if (data.error) {
    host.replaceChildren(el("p", { class: "muted", text: data.error }));
    return;
  }
  const list = [...data.incidents].sort((a, b) =>
    Number(["open", "needs_human"].includes(b.state)) - Number(["open", "needs_human"].includes(a.state)) || (a.id < b.id ? 1 : -1));
  if (!list.length) {
    host.replaceChildren(el("p", { class: "muted", text: "No incidents in the last 7 days. The monitor checks every 5 minutes." }));
    return;
  }
  host.replaceChildren(el("ul", { class: "incidents" }, list.map(incidentRow)));
}

function incidentRow(inc) {
  const [level, words] = INCIDENT_STATES[inc.state] ?? INCIDENT_STATES.open;
  const end = inc.closed_at || inc.resolved?.at;
  const facts = [
    `Opened ${clock(inc.opened_at)}`,
    end ? `lasted ${lasted(inc.opened_at, end)}` : `${agoIso(inc.opened_at)}, still open`,
    `${inc.steps} ${inc.steps === 1 ? "repair step" : "repair steps"}`,
  ];
  if (inc.resolved) facts.push(`marked resolved by ${inc.resolved.by} ${agoIso(inc.resolved.at)}`);
  const unresolved = ["open", "needs_human"].includes(inc.state);
  const action = unresolved
    ? el("button", { type: "button", class: "reset-button", onclick: (e) => resolveIncident(e.currentTarget, inc) },
      incidents.confirm === inc.id ? "Tap again: mark resolved" : "Mark resolved")
    : null;
  return el("li", { class: `incident incident-${inc.state}` },
    el("div", { class: "incident-head" }, statusBadge(level, words), el("span", { class: "panel-note", text: facts.join(" · ") }), action),
    el("details", { class: "incident-detail" },
      el("summary", { text: "What happened" }),
      el("ol", { class: "incident-timeline" }, inc.timeline.map((e) => el("li", {},
        el("span", { class: "incident-time", text: clock(e.at) }),
        el("span", { text: timelineText(e) }))))));
}

/** One run of the monitor, in words. */
function timelineText(e) {
  const parts = [];
  if (e.healthy === true) parts.push("Healthy again");
  else if (e.error) parts.push(`Unhealthy: ${e.error}`);
  if (e.instance) {
    const i = e.instance;
    parts.push(`Server ${i.state}${i.instance_status ? `, checks ${i.system_status}/${i.instance_status}` : ""}${i.ssm ? `, SSM ${i.ssm}` : ""}`);
  }
  if (e.action) parts.push(`Tried to ${e.action.name}: ${e.action.result ?? "no answer"}`);
  // (The monitor notes "healthy again" on recovery, which the first part already says.)
  else if (e.note && e.healthy !== true) parts.push(e.note[0].toUpperCase() + e.note.slice(1));
  return parts.join(". ");
}

async function resolveIncident(btn, inc) {
  // Two taps, like taking away a role.
  if (incidents.confirm !== inc.id) {
    incidents.confirm = inc.id;
    btn.textContent = "Tap again: mark resolved";
    return;
  }
  incidents.confirm = null;
  btn.disabled = true;
  try {
    await api(`/admin/incidents/${encodeURIComponent(inc.id)}/resolve`, "POST");
  } catch (err) {
    $("#m-incidents-note").textContent = `Couldn't mark it resolved: ${err.message}`;
  }
  await loadIncidents(true);
}

// ---------- friend graph (docs/implementation/friend-graph.md) ----------
// Everyone, or chosen people (you by default) with their friends or friends
// of friends. Real usernames: this is what the server holds. The drawing is
// the same module as the app's own friend map.

const graphView = { all: false, depth: 1, chats: false, users: null, data: null, busy: false, again: false };

async function loadGraph() {
  if (graphView.busy) {
    graphView.again = true;
    return;
  }
  graphView.busy = true;
  try {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) return fail("Sign in first.");
    const qs = new URLSearchParams();
    if (graphView.chats) qs.set("chats", "1");
    if (graphView.all) qs.set("all", "1");
    else {
      if (graphView.users?.size) qs.set("users", [...graphView.users].join(","));
      qs.set("depth", String(graphView.depth));
    }
    let res;
    try {
      res = await fetch(`/api/admin/graph?${qs}`, { headers: { Authorization: `Bearer ${token}` }, cache: "no-store" });
    } catch {
      $("#g-note").textContent = "Offline. Try again in a moment.";
      return;
    }
    if (res.status === 401) return fail("Your session ended. Sign in again.");
    if (!res.ok) return fail("This page isn't available.");
    graphView.data = await res.json();
    // The first answer says who "you" are: the people it centered on.
    if (!graphView.users) {
      graphView.users = new Set(graphView.data.graph.nodes.filter((n) => n.kind === "seed").map(personRef));
    }
    $("#message").hidden = true;
    $("#admin").hidden = false;
    renderGraphControls();
    drawAdminGraph();
  } finally {
    graphView.busy = false;
    if (graphView.again) {
      graphView.again = false;
      loadGraph();
    }
  }
}

function renderGraphControls() {
  const people = graphView.data?.people ?? [];
  $("#g-all").checked = graphView.all;
  $("#g-chats").checked = graphView.chats;
  $("#g-depth").hidden = graphView.all;
  $("#g-people").hidden = graphView.all;
  for (const b of document.querySelectorAll("#g-depth .segment")) {
    b.setAttribute("aria-pressed", String(Number(b.dataset.depth) === graphView.depth));
  }
  const chosen = people.filter((p) => graphView.users?.has(p.id)).map((p) => p.username);
  // Anonymous people (chosen from a PowerUser's graph) are counted, not named.
  const anonymous = [...(graphView.users ?? [])].filter((u) => typeof u === "string").length;
  if (anonymous) chosen.push(`${anonymous} anonymous`);
  $("#g-people-summary").textContent = chosen.length
    ? `Showing ${chosen.length > 3 ? `${chosen.slice(0, 3).join(", ")} and ${chosen.length - 3} more` : chosen.join(", ")}`
    : "Choose people";
  const q = $("#g-search").value.trim().toLowerCase();
  $("#g-people-list").replaceChildren(...people
    .filter((p) => !q || p.username.toLowerCase().includes(q))
    .map((p) => el("li", {}, el("label", {},
      el("input", {
        type: "checkbox", value: String(p.id), checked: graphView.users?.has(p.id) ? "" : null,
        onchange: (e) => {
          if (e.target.checked) graphView.users.add(p.id);
          else graphView.users.delete(p.id);
          loadGraph();
        },
      }),
      ` ${p.username}`))));
}

/** How to choose someone: their id, or (anonymous, on a PowerUser's graph) their alias key. */
const personRef = (n) => n.user_id ?? n.key;
const personLabel = (n) => n.username ?? n.alias ?? "";

function drawAdminGraph() {
  const data = graphView.data;
  if (!data || currentTab() !== "graph") return;
  const g = data.graph;
  const seeds = g.nodes.filter((n) => n.kind === "seed");
  const { people, friendships, chats } = counts(g);
  const sum = `${people} people, ${friendships} friendships${chats ? `, ${chats} group ${chats === 1 ? "chat" : "chats"}` : ""}`;
  $("#g-note").textContent = data.all ? `Everyone: ${sum}` : sum;
  if (data.anonymous) $("#g-note").textContent += ". People you aren't friends with are anonymous";
  if (!g.nodes.length) {
    $("#g-host").replaceChildren(el("p", { class: "muted", text: "Choose someone to see their friends." }));
    return;
  }
  drawGraph($("#g-host"), g, {
    // One person: their map, with them in the middle (and out of the grouping).
    center: !data.all && seeds.length === 1 ? seeds[0].key : null,
    label: personLabel,
    title: `Friend graph: ${sum}.`,
    describe: (n, { neighbors, group }) => isChat(n) ? [
      el("b", { text: chatName(n) }),
      ` · group chat · ${chatSummary(n)}: ${neighbors.map(personLabel).filter(Boolean).join(", ")}${n.others ? ` and ${n.others} more` : ""}.`,
    ] : [
      el("b", { text: personLabel(n) }),
      ` · ${neighbors.length} ${neighbors.length === 1 ? "friend" : "friends"} shown${group >= 0 ? ` · Group ${groupLetter(group)}` : ""}. `,
      el("button", {
        type: "button", class: "link",
        onclick: () => { graphView.all = false; graphView.users = new Set([personRef(n)]); loadGraph(); },
      }, "Show their graph"),
    ],
  });
}

$("#g-all").addEventListener("change", (e) => { graphView.all = e.target.checked; loadGraph(); });
$("#g-chats").addEventListener("change", (e) => { graphView.chats = e.target.checked; loadGraph(); });
for (const b of document.querySelectorAll("#g-depth .segment")) {
  b.addEventListener("click", () => { graphView.depth = Number(b.dataset.depth); loadGraph(); });
}
$("#g-search").addEventListener("input", renderGraphControls);
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (currentTab() === "metrics") renderMetrics();
    if (currentTab() === "graph" && widthChanged($("#g-host"))) drawAdminGraph();
  }, 150);
});

// ---------- roles (docs/implementation/roles.md) ----------
// Everyone for Admins; for PowerUsers, themselves and their friends. Admins
// and PowerUsers make someone a PowerUser; only Admins take it away.

const ROLE_NAMES = { user: "User", power: "PowerUser", admin: "Admin" };
const rolesView = { data: null, confirm: null };

async function api(path, method = "GET") {
  const res = await fetch(`/api${path}`, { method, headers: { Authorization: `Bearer ${localStorage.getItem(TOKEN_KEY)}` }, cache: "no-store" });
  const body = await res.json().catch(() => ({}));
  if (res.status === 401) fail("Your session ended. Sign in again.");
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

async function loadRoles() {
  try {
    rolesView.data = await api("/admin/roles");
  } catch (err) {
    $("#r-note").textContent = `Couldn't load roles: ${err.message}`;
    return;
  }
  $("#message").hidden = true;
  $("#admin").hidden = false;
  renderRoles();
}

function renderRoles() {
  const data = rolesView.data;
  if (!data) return;
  const admin = data.role === "admin";
  $("#r-explain").textContent = admin
    ? "PowerUsers see how napsack is doing: the overview, metrics without cost, and the graph with people they don't know kept anonymous. They can make their friends PowerUsers; only Admins can take it away. Admins come from settings."
    : "PowerUsers see how napsack is doing. You can make your friends PowerUsers; only an Admin can take it away.";
  $("#r-admin").hidden = !(admin && data.admins_from_settings);
  const q = $("#r-search").value.trim().toLowerCase();
  const people = data.people.filter((p) => !q || p.username.toLowerCase().includes(q));
  const counts = data.people.reduce((c, p) => ({ ...c, [p.role]: (c[p.role] || 0) + 1 }), {});
  $("#r-note").textContent = ["admin", "power", "user"].filter((r) => counts[r]).map((r) => `${counts[r]} ${ROLE_NAMES[r]}${counts[r] === 1 ? "" : "s"}`).join(" · ");
  $("#r-rows").replaceChildren(...people.map((p) => {
    const me = p.id === viewer?.id;
    let action = null;
    if (p.role === "user" && !me) {
      action = el("button", { type: "button", class: "reset-button", onclick: (e) => changeRole(e.currentTarget, p, "grant") }, "Make PowerUser");
    } else if (p.role === "power" && admin && !me) {
      action = el("button", { type: "button", class: "reset-button", onclick: (e) => changeRole(e.currentTarget, p, "revoke") },
        rolesView.confirm === p.id ? "Tap again: remove PowerUser" : "Remove PowerUser");
    } else if (p.role === "admin") {
      action = el("span", { class: "muted", text: "Set in settings" });
    }
    const since = p.granted_at ? dateLabel(p.granted_at, { year: "numeric", month: "short", day: "numeric" }) : "";
    return el("tr", {},
      el("td", { text: me ? `${p.username} (you)` : p.username }),
      el("td", {}, el("span", { class: `role-badge role-${p.role}`, text: ROLE_NAMES[p.role] })),
      el("td", { class: "muted", text: p.granted_by ? `${since} by ${p.granted_by}` : since }),
      el("td", {}, action));
  }));
  if (!people.length) $("#r-rows").append(el("tr", {}, el("td", { colspan: "4", class: "muted", text: q ? "Nobody matches." : "Nobody here yet." })));
}

async function changeRole(btn, person, how) {
  // Taking the role away is two taps, remembered by person (the list can redraw in between).
  if (how === "revoke" && rolesView.confirm !== person.id) {
    rolesView.confirm = person.id;
    btn.textContent = "Tap again: remove PowerUser";
    return;
  }
  rolesView.confirm = null;
  btn.disabled = true;
  const out = $("#r-result");
  try {
    await api(`/admin/roles/${person.id}`, how === "grant" ? "POST" : "DELETE");
    out.replaceChildren(el("p", { text: how === "grant" ? `${person.username} is a PowerUser now.` : `${person.username} is a User again.` }));
  } catch (err) {
    out.replaceChildren(el("p", { text: `Couldn't change ${person.username}'s role: ${err.message}` }));
  }
  out.hidden = false;
  await loadRoles();
}

$("#r-search").addEventListener("input", renderRoles);
$("#r-reload").addEventListener("click", async () => {
  const note = $("#r-reload-note");
  try {
    const r = await api("/admin/roles/reload", "POST");
    note.textContent = `Reloaded: ${r.admins} admin${r.admins === 1 ? "" : "s"}.`;
  } catch (err) {
    note.textContent = err.message;
  }
  loadRoles();
});

// ---------- tabs ----------

const TABS = ["overview", "metrics", "graph", "roles", "logs"];
// Which tabs each role gets (roles.md). The server enforces the same, endpoint by endpoint.
const TAB_ROLES = { overview: "power", metrics: "power", graph: "power", roles: "power", logs: "admin" };
const RANK = { user: 0, power: 1, admin: 2 };
let viewer = null;
const allowed = (tab) => viewer && RANK[viewer.role] >= RANK[TAB_ROLES[tab]];
const currentTab = () => TABS.find((t) => location.hash === `#${t}` && allowed(t)) ?? "overview";

function showTab() {
  if (!viewer) return;
  const tab = currentTab();
  for (const name of TABS) {
    $(`#view-${name}`).hidden = name !== tab;
    $(`#tab-${name}`).hidden = !allowed(name);
    $(`#tab-${name}`).setAttribute("aria-current", name === tab ? "page" : "false");
  }
  $("#updated").hidden = tab !== "overview";
  if (tab === "logs") loadLogs(logs.loaded ? "tail" : "reset");
  else if (tab === "metrics") loadMetrics();
  else if (tab === "graph") loadGraph();
  else if (tab === "roles") loadRoles();
  else load();
}

/** Who's looking, and so which tabs they get. */
async function start() {
  // A non-production copy says so (env.js), signed in or not.
  fetch("/api/config").then((r) => r.json()).then((config) => {
    document.title = withEnvironment(document.title, config);
    markEnvironment(config);
  }).catch(() => {});
  const token = localStorage.getItem(TOKEN_KEY);
  if (!token) return fail("Sign in first.");
  let res;
  try {
    res = await fetch("/api/me", { headers: { Authorization: `Bearer ${token}` }, cache: "no-store" });
  } catch {
    return fail("Can't reach napsack right now.");
  }
  if (res.status === 401) return fail("Your session ended. Sign in again.");
  const me = await res.json();
  viewer = { id: me.id, role: me.role ?? (me.is_admin ? "admin" : "user") };
  if (viewer.role === "user") return fail("This page isn't available.");
  showTab();
}
window.addEventListener("hashchange", showTab);
start();

const visible = () => document.visibilityState === "visible" && !$("#admin").hidden;
setInterval(() => { if (visible() && currentTab() === "overview") load(); }, REFRESH_MS);
// The last hour moves every 10 seconds; longer ranges once a minute.
setInterval(() => {
  if (!visible() || currentTab() !== "metrics") return;
  if (metrics.hours === 1 || Date.now() - metrics.loadedAt > 60_000) loadMetrics();
}, 10_000);
setInterval(() => { if (visible() && currentTab() === "logs" && $("#log-live").checked) loadLogs("tail"); }, TAIL_MS);
document.addEventListener("visibilitychange", () => { if (visible()) showTab(); });
