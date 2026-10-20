"""Development live reload (server/src/web.rs, server/static/dev-reload.js):
in a debug build, saving the stylesheet swaps the new styles in without a
reload (an open dialog stays open), and saving anything else reloads the page.
Only touches the files' modified times, never their contents. Release builds
don't have any of this (checked after every deploy by scripts/deploy.sh).
Settings come from the environment; see common.py."""
import asyncio, os, time, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key

STATIC = os.path.join(os.path.dirname(__file__), "..", "..", "server", "static")


def touch(name):
    now = time.time()
    os.utime(os.path.join(STATIC, name), (now, now))


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        page = await browser.new_page()
        await page.goto(BASE)
        assert await page.locator('script[src="/dev/reload.js"]').count() == 1, "debug builds add the reload script"
        await page.click("#auth-toggle")
        await page.fill("#auth-form input[name=username]", f"dev_{uuid.uuid4().hex[:5]}")
        await page.fill("#auth-form input[name=password]", "correct horse battery")
        await page.fill("#auth-form input[name=invite_code]", INVITE)
        await page.click("#auth-submit")
        await expect(page.locator("#app")).to_be_visible(timeout=20000)
        await save_recovery_key(page)

        # Stylesheet saved: new styles, same page (the dialog stays open).
        await page.click("#friends-button")
        await expect(page.locator("#friends-dialog")).to_be_visible()
        await page.evaluate("window.__stillHere = true")
        await page.wait_for_timeout(1000)  # the script has its first reading
        touch("style.css")
        await expect(page.locator('link[rel="stylesheet"][href*="v="]')).to_have_count(1, timeout=5000)
        assert await page.evaluate("window.__stillHere === true"), "a style change shouldn't reload the page"
        await expect(page.locator("#friends-dialog")).to_be_visible()
        assert await page.locator('link[rel="stylesheet"]').count() == 1, "the old stylesheet is removed"
        print("stylesheet saved: swapped in place, dialog still open")

        # Anything else saved: the page reloads, still signed in.
        touch("app.js")
        # (Not wait_for_function: the page's security policy blocks evaluating strings.)
        for _ in range(50):
            try:
                if await page.evaluate("window.__stillHere") is None:
                    break
            except Exception:
                pass  # mid-reload
            await asyncio.sleep(0.1)
        else:
            raise AssertionError("saving app.js didn't reload the page")
        await expect(page.locator("#app")).to_be_visible(timeout=20000)
        print("app.js saved: the page reloaded, still signed in")

        await browser.close()
    print("DEV RELOAD TEST PASSED")


asyncio.run(main())
