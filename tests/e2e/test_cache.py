"""Kept on the device (X31): napsack opens from what it kept last time, while
the server is still answering, so a slow connection shows your chats and
their newest messages at once. What's kept is what the server sent: no
message text in it, only ciphertext. Signing out deletes it, and a session
that ended elsewhere still signs out once the server says so. Settings come
from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, no_placeholders, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
SECRET = f"the cache never sees this {tag}"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}
errors = []

KEPT = """async () => {
  const cache = await import('/cache.js');
  return JSON.stringify(await cache.all());
}"""


async def sign_up(browser, name, **ctx):
    page = await (await browser.new_context(**ctx)).new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    await page.goto(BASE)
    await page.click("#auth-toggle")
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", "correct horse battery")
    await page.fill("#auth-form input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(page)
    return page


async def befriend(asker, asked, name_of_asked, name_of_asker):
    await asker.click("#friends-button")
    await asker.fill("#add-friend-form input[name=username]", name_of_asked)
    await asker.click("#add-friend-form button[type=submit]")
    await expect(asker.locator("#add-friend-note")).to_contain_text("Request sent")
    await asker.click("#friends-dialog [data-close]")
    await asked.click("#friends-button")
    await asked.locator("#incoming-list li", has_text=name_of_asker).locator("button", has_text="Accept").click()
    await asked.click("#friends-dialog [data-close]")


def row(page, name):
    return page.locator("#chat-list .chat-row", has=page.locator(".chat-name", has_text=name))


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, **PHONE)
        ben = await sign_up(browser, BEN)
        await befriend(ana, ben, BEN, ANA)
        await row(ben, ANA).click()
        await ben.fill("#composer-input", SECRET)
        await ben.press("#composer-input", "Enter")
        await row(ana, BEN).click()
        await expect(ana.locator(".msg-body", has_text=SECRET)).to_be_visible(timeout=10000)
        await ana.click("#back-button")
        await expect(row(ana, BEN).locator(".chat-status")).to_have_text(SECRET, timeout=10000)

        # What's kept is what the server sent: ciphertext, never the text.
        kept = await ana.evaluate(KEPT)
        assert "friends" in kept and f":chat:" in kept and '"me"' in kept, kept[:300]
        assert SECRET not in kept, "message text was kept on the device"
        print("kept: the chat list, the chat's newest page, who you are; no text")

        # A very slow server: napsack opens anyway, from what it kept.
        gate = asyncio.Event()

        async def held(route):
            await gate.wait()
            await route.continue_()
        await ana.route("**/api/**", held)
        await ana.reload()
        await expect(ana.locator("#app")).to_be_visible(timeout=5000)
        await expect(row(ana, BEN).locator(".chat-status")).to_have_text(SECRET, timeout=5000)
        await expect(ana.locator("#chat-list .skeleton-row")).to_have_count(0)
        await row(ana, BEN).click()
        await expect(ana.locator(".msg-body", has_text=SECRET)).to_be_visible(timeout=5000)
        await no_placeholders(ana)
        await shot(ana, "kept-while-slow", full_page=False)
        gate.set()  # from now on the route lets everything through
        # The server's answer takes over: something new arrives as usual.
        await ben.fill("#composer-input", "and this is new")
        await ben.press("#composer-input", "Enter")
        await expect(ana.locator(".msg-body", has_text="and this is new")).to_be_visible(timeout=15000)
        print("opens from what was kept while the server is slow, then catches up")

        # A session ended elsewhere: the kept copy opens, then the server's 401 signs out.
        await ana.evaluate("fetch('/api/auth/logout', { method: 'POST', headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } })")
        await ana.reload()
        await expect(ana.locator("#auth")).to_be_visible(timeout=15000)
        assert await ana.evaluate(KEPT) == "[]", "signing out deletes what was kept"
        print("an ended session still signs out, and what was kept is gone")

        assert not errors, errors
        await browser.close()
    print("CACHE TEST PASSED")


asyncio.run(main())
