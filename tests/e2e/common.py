"""Settings shared by the end-to-end tests. scripts/test.sh sets these; you can
also export them yourself to point the tests at another server.

NAPSACK_URL      server to test, e.g. http://127.0.0.1:8099
NAPSACK_INVITE   invite code the server requires
NAPSACK_ADMIN    username in the server's FADE_ADMINS (test_admin.py signs up as it)
NAPSACK_DB       optional: path to the server's SQLite file, for checks that read it
NAPSACK_SHOTS    optional: directory to write screenshots into
E2E_CHROME       "chrome" (default) uses installed Chrome; "bundled" uses Playwright's Chromium
"""
import os, re

from playwright.async_api import expect

BASE = os.environ.get("NAPSACK_URL", "http://127.0.0.1:8099").rstrip("/")
INVITE = os.environ.get("NAPSACK_INVITE", "letmein")
ADMIN = os.environ.get("NAPSACK_ADMIN", "e2e_admin")
DB = os.environ.get("NAPSACK_DB") or None
SHOTS = os.environ.get("NAPSACK_SHOTS") or None
# Testing a deployed server (staging), not a local debug build.
REMOTE = os.environ.get("NAPSACK_REMOTE") == "1"
_CHANNEL = os.environ.get("E2E_CHROME", "chrome")

# Every test account's password (the admin's too, which several tests share).
PASSWORD = "correct horse battery"
# Signing up or in makes keys from the password (600,000 rounds, twice for a
# new account, plus a recovery key): with four browsers at once on a CI runner
# that can pass 20 seconds. A waiting check, so it costs nothing when it's quick.
SIGN_IN_WAIT = 30000

PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}


async def launch(pw, full=False, chrome=False, **kw):
    """`full`: Playwright's own headless browser is a stripped-down shell
    without notifications or service-worker push; full Chromium has them.
    `chrome`: Google Chrome itself, whatever E2E_CHROME says, for Chrome's own
    codecs (the AAC sound in recorded videos), which Chromium doesn't have."""
    if chrome:
        kw["channel"] = "chrome"
    elif _CHANNEL != "bundled":
        kw["channel"] = _CHANNEL
    elif full:
        kw["channel"] = "chromium"
    return await pw.chromium.launch(**kw)


async def open_page(browser, errors=None, label=None, console=False, init=None,
                    permissions=None, prepare=None, goto=True, **ctx):
    """A page in a new context (`ctx`: viewport, PHONE, ...), at the app unless
    `goto` is false. Page errors go to `errors`, as "label: error" when
    labelled; with `console`, so do console errors other than the 4xx a
    failed request logs. `init`: a script run before the app's own;
    `permissions`: granted for the app's origin; `prepare(page)`: anything
    else needed before it loads (routes)."""
    context = await browser.new_context(**ctx)
    if permissions:
        await context.grant_permissions(permissions, origin=BASE)
    if init:
        await context.add_init_script(init)
    page = await context.new_page()
    if errors is not None:
        tag = f"{label}: " if label else ""
        page.on("pageerror", lambda e: errors.append(f"{tag}{e}"))
        if console:
            page.on("console", lambda m: m.type == "error" and "status of 4" not in m.text
                    and errors.append(f"{tag}{m.text}"))
    if prepare:
        await prepare(page)
    if goto:
        await page.goto(BASE)
    return page


async def fill_sign_up(page, name, password=PASSWORD, code=True, toggle=True, save_key=True):
    """Sign up on a page showing the sign-in form: `toggle` switches it to
    signing up; `code` fills in the invite code; `save_key` saves the
    recovery key a new account is shown."""
    if toggle:
        await page.click("#auth-toggle")
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", password)
    if code:
        await page.fill("#auth-form input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=SIGN_IN_WAIT)
    if save_key:
        await save_recovery_key(page)


async def sign_up(browser, name, password=PASSWORD, **page_kw):
    """A new account, signed in on a page of its own (open_page's options)."""
    page = await open_page(browser, **page_kw)
    await fill_sign_up(page, name, password)
    return page


async def sign_in(page, name, password=PASSWORD, wait=True):
    """Sign in on the sign-in form; `wait` for the app to open (not when the
    test expects the sign-in to be refused)."""
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", password)
    await page.click("#auth-submit")
    if wait:
        await expect(page.locator("#app")).to_be_visible(timeout=SIGN_IN_WAIT)


async def sign_up_or_in(page, name, password=PASSWORD):
    """Sign in, or sign up if there's no such account yet: for accounts tests
    share, like the admin's, which whichever test runs first creates. Goes on
    as soon as the app opens or the sign-in is refused, never waiting out a
    timeout."""
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", password)
    await page.click("#auth-submit")
    app = page.locator("#app")
    refused = page.locator("#auth-error").filter(has_text=re.compile(r"\S"))
    # (Once refused, both match: the error, then the still-hidden app.)
    await expect(app.or_(refused).first).to_be_visible(timeout=SIGN_IN_WAIT)
    if not await app.is_visible():
        await fill_sign_up(page, name, password)


async def befriend(asker, asked, name_of_asked, name_of_asker):
    """`asker` sends a friend request from the Friends dialog; `asked` accepts it."""
    await asker.click("#friends-button")
    await asker.fill("#add-friend-form input[name=username]", name_of_asked)
    await asker.click("#add-friend-form button[type=submit]")
    await expect(asker.locator("#add-friend-note")).to_contain_text("Request sent")
    await asker.click("#friends-dialog [data-close]")
    await asked.click("#friends-button")
    await asked.locator("#incoming-list li", has_text=name_of_asker).locator("button", has_text="Accept").click()
    await asked.click("#friends-dialog [data-close]")


def row(page, name):
    """A chat's row in the chat list."""
    return page.locator("#chat-list .chat-row", has=page.locator(".chat-name", has_text=name))


async def save_recovery_key(page):
    """A new account is shown its recovery key once, in a dialog that stays
    until it's saved. Tests save it and go on. Returns the key."""
    await expect(page.locator("#recovery-dialog")).to_be_visible(timeout=SIGN_IN_WAIT)
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
