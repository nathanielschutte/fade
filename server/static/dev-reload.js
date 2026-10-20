// Development only. Debug builds (`cargo run`) add this to the page; release
// builds don't have it at all (server/src/web.rs). It asks the server every
// moment whether the web app's files changed on disk:
//   - the stylesheet: swapped in place, so you keep your place in the app
//   - anything else, or the server restarting (after a Rust change): the page
//     reloads (you stay signed in)

const EVERY_MS = 700;
let last = null;

function swapStyles(stamp) {
  for (const old of document.querySelectorAll('link[rel="stylesheet"]')) {
    const url = new URL(old.href);
    url.searchParams.set("v", stamp);
    const next = old.cloneNode();
    next.href = url.href;
    // Keep the old one until the new one has loaded, so nothing flashes unstyled.
    next.addEventListener("load", () => old.remove(), { once: true });
    old.after(next);
  }
  console.info("[dev] styles updated");
}

async function check() {
  try {
    const now = await (await fetch("/dev/changes", { cache: "no-store" })).json();
    if (last && (now.other !== last.other || now.server !== last.server)) {
      location.reload();
      return;
    }
    if (last && now.css !== last.css) swapStyles(now.css);
    last = now;
  } catch {
    // The server is restarting; keep asking.
  }
  setTimeout(check, EVERY_MS);
}

check();
