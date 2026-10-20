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
    ["Held in memory", `${n(server.snaps_in_memory)} · ${bytes(server.snap_bytes_in_memory)} of ${bytes(server.snap_pool_bytes)}`],
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
    ["Pic lifetime", `${server.snap_ttl_hours} h`],
    ["Sign-up", server.invite_required ? "Invite code required" : "Open"],
    ["Last backup", backupText(server.backup)],
    ["Memory", resourceText(server.resources, "mem")],
    ["Data disk", resourceText(server.resources, "disk")],
    ["Load (1 min)", server.resources?.load_1m ?? "—"],
  ]);

  $("#users").replaceChildren(...u.list.map((x) => el("tr", {},
    el("td", { text: x.username }),
    el("td", { text: dateLabel(x.created_at, { year: "numeric", month: "short", day: "numeric" }) }),
    el("td", { text: ago(x.last_seen_at) }),
    el("td", { class: "num", text: n(x.friends) }),
    el("td", { class: "num", text: n(x.texts_sent) }),
    el("td", { class: "num", text: n(x.snaps_sent) }),
  )));
  if (!u.list.length) $("#users").append(el("tr", {}, el("td", { colspan: "6", class: "muted", text: "No users yet." })));

  $("#updated").textContent = `Updated ${new Date(s.generated_at * 1000).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
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

// ---------- tabs ----------

const currentTab = () => (location.hash === "#logs" ? "logs" : "overview");

function showTab() {
  const tab = currentTab();
  $("#view-overview").hidden = tab !== "overview";
  $("#view-logs").hidden = tab !== "logs";
  $("#updated").hidden = tab !== "overview";
  for (const name of ["overview", "logs"]) {
    $(`#tab-${name}`).setAttribute("aria-current", name === tab ? "page" : "false");
  }
  if (tab === "logs") loadLogs(logs.loaded ? "tail" : "reset");
  else load();
}
window.addEventListener("hashchange", showTab);
showTab();

const visible = () => document.visibilityState === "visible" && !$("#admin").hidden;
setInterval(() => { if (visible() && currentTab() === "overview") load(); }, REFRESH_MS);
setInterval(() => { if (visible() && currentTab() === "logs" && $("#log-live").checked) loadLogs("tail"); }, TAIL_MS);
document.addEventListener("visibilitychange", () => { if (visible()) showTab(); });
