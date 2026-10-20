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
_CHANNEL = os.environ.get("E2E_CHROME", "chrome")


async def launch(pw, **kw):
    if _CHANNEL != "bundled":
        kw["channel"] = _CHANNEL
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
