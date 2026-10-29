"""Settings shared by the end-to-end tests. scripts/test.sh sets these; you can
also export them yourself to point the tests at another server.

NAPSACK_URL      server to test, e.g. http://127.0.0.1:8099
NAPSACK_INVITE   invite code the server requires
NAPSACK_ADMIN    username in the server's FADE_ADMINS (test_admin.py signs up as it)
NAPSACK_DB       optional: path to the server's SQLite file, for checks that read it
NAPSACK_SHOTS    optional: directory to write screenshots into
E2E_CHROME       "chrome" (default) uses installed Chrome; "bundled" uses Playwright's Chromium
"""
import os

BASE = os.environ.get("NAPSACK_URL", "http://127.0.0.1:8099").rstrip("/")
INVITE = os.environ.get("NAPSACK_INVITE", "letmein")
ADMIN = os.environ.get("NAPSACK_ADMIN", "e2e_admin")
DB = os.environ.get("NAPSACK_DB") or None
SHOTS = os.environ.get("NAPSACK_SHOTS") or None
# Testing a deployed server (staging), not a local debug build.
REMOTE = os.environ.get("NAPSACK_REMOTE") == "1"
_CHANNEL = os.environ.get("E2E_CHROME", "chrome")


async def launch(pw, full=False, **kw):
    """`full`: Playwright's own headless browser is a stripped-down shell
    without notifications or service-worker push; full Chromium has them."""
    if _CHANNEL != "bundled":
        kw["channel"] = _CHANNEL
    elif full:
        kw["channel"] = "chromium"
    return await pw.chromium.launch(**kw)


async def save_recovery_key(page):
    """A new account is shown its recovery key once, in a dialog that stays
    until it's saved. Tests save it and go on. Returns the key."""
    from playwright.async_api import expect
    await expect(page.locator("#recovery-dialog")).to_be_visible(timeout=20000)
    key = await page.locator("#recovery-key").text_content()
    await page.check("#recovery-saved")
    await page.click("#recovery-done")
    await expect(page.locator("#recovery-dialog")).to_be_hidden()
    return key


async def shot(page, name, full_page=True):
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        await page.screenshot(path=os.path.join(SHOTS, f"{name}.png"), full_page=full_page)


# Words a loading placeholder shows until its data arrives (app.js).
PLACEHOLDERS = ("Loading…", "Opening…", "Making your code…")


async def no_placeholders(page, scope="body"):
    """Once what was loading has arrived, nothing still says it's loading: no
    placeholder words and no skeleton rows, anywhere visible in `scope`. A
    placeholder is replaced by what loads, never left beside it (0.34.0 left
    "Loading…" above a loaded profile). Call this after checking the loaded
    data is there, in every test of something that shows a placeholder."""
    left = await page.evaluate("""([scope, words]) => {
      const root = document.querySelector(scope);
      if (!root) return [];
      const seen = [];
      const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        const text = n.textContent.trim();
        if (words.includes(text) && n.parentElement.checkVisibility()) seen.push(text);
      }
      for (const el of root.querySelectorAll('.skeleton-row, .msg-skeleton')) {
        if (el.checkVisibility()) seen.push(el.className);
      }
      return seen;
    }""", [scope, list(PLACEHOLDERS)])
    assert not left, f"still showing a loading placeholder in {scope}: {left}"
