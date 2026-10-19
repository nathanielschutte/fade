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
    el("span", { class: "tip-sub", text: `${n(d.texts)} texts · ${n(d.snaps)} snaps` }),
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
    el("thead", {}, el("tr", {}, ["Day", "Texts", "Snaps", "Sign-ups"].map((h, i) => el("th", { class: i ? "num" : null, text: h })))),
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
    ["Held in memory", `${n(server.snaps_in_memory)} · ${bytes(server.snap_bytes_in_memory)} of ${bytes(server.snap_pool_bytes)}`],
  ]);
  facts("#social-facts", [
    ["Friendships", n(social.friendships)],
    ["Pending requests", n(social.pending_requests)],
    ["Active sessions", n(social.active_sessions)],
    ["Avg friends per user", u.total ? (social.friendships * 2 / u.total).toFixed(1) : "—"],
  ]);
  facts("#server-facts", [
    ["Version", `${server.version} (${server.build})`],
    ["Uptime", uptime(server.uptime_secs)],
    ["Database", bytes(server.db_bytes)],
    ["Snap lifetime", `${server.snap_ttl_hours} h`],
    ["Sign-up", server.invite_required ? "Invite code required" : "Open"],
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

load();
setInterval(() => { if (document.visibilityState === "visible" && !$("#admin").hidden) load(); }, REFRESH_MS);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !$("#admin").hidden) load();
});
