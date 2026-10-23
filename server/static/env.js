// Marks a non-production copy (staging) on every page, so nobody mistakes it
// for the real napsack: its name in the title and by the wordmark, a thin
// band across the top, the browser's bar color, and the build in the
// bottom-right corner. It's all added on top (a data-env attribute on <html>
// and two elements styled in style.css), so the production design never has
// to know about it. In production /api/config has no environment and this
// does nothing.

const ENV_COLOR = "#e8a33d"; // = --env-mark in style.css (meta theme-color can't read CSS)

/** "napsack" → "napsack (staging)" on a non-production copy. */
export function withEnvironment(name, config) {
  return config?.environment ? `${name} (${config.environment})` : name;
}

function uptime(startedAt) {
  const s = Math.max(0, Date.now() / 1000 - startedAt);
  if (s < 3600) return `up ${Math.floor(s / 60)}m`;
  if (s < 86400) return `up ${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `up ${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}

/** Marks the page if `config` (from /api/config) names an environment. Once per page. */
export function markEnvironment(config) {
  const env = config?.environment;
  const root = document.documentElement;
  if (!env || root.dataset.env) return;
  root.dataset.env = env;

  for (const mark of document.querySelectorAll(".wordmark")) {
    const tag = document.createElement("span");
    tag.className = "env-tag";
    tag.textContent = env;
    mark.append(tag);
  }
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", ENV_COLOR);

  const band = document.createElement("div");
  band.className = "env-band";
  band.setAttribute("aria-hidden", "true");

  // Which build this is, at a glance: the environment, the server's version
  // and commit, and how long it's been up (a deploy restarts it).
  const build = document.createElement("div");
  build.className = "env-build";
  build.setAttribute("role", "note");
  const show = () => {
    build.textContent = [env, `v${config.server_version}`, config.build, config.started_at ? uptime(config.started_at) : null]
      .filter(Boolean).join(" · ");
  };
  show();
  setInterval(show, 60_000);
  document.body.append(band, build);
}
