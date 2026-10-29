"""Kept on the device (X31): napsack opens from what it kept last time, while
the server is still answering, so a slow connection shows your chats and
their newest messages at once. What's kept is what the server sent: no
message text in it, only ciphertext. Signing out deletes it, and a session
that ended elsewhere still signs out once the server says so. Settings come
from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import launch, no_placeholders, shot, PHONE, befriend, row, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
SECRET = f"the cache never sees this {tag}"
errors = []

KEPT = """async () => {
  const cache = await import('/cache.js');
  return JSON.stringify(await cache.all());
}"""


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, **PHONE)
        ben = await sign_up(browser, BEN, errors=errors)
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
