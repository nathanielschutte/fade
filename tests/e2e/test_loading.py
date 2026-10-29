"""Loading and slow connections (X23): before the server answers, the app
shows placeholders shaped like what's coming, never "No friends yet" or "No
messages yet"; after a few seconds it says the connection is slow; when
requests can't get through, it says so and offers to try again. The
network is held back on purpose with Playwright's routing. Settings come
from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, launch, no_placeholders, shot, PHONE, befriend, fill_sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
errors = []


async def forget_kept(page):
    """What the app kept on this device (cache.js) would show at once; these
    checks are about the first load, before anything was kept."""
    await page.evaluate("import('/cache.js').then((c) => c.clear())")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ctx = await browser.new_context(**PHONE)
        ana = await ctx.new_page()
        ana.on("pageerror", lambda e: errors.append(str(e)))
        await ana.goto(BASE)
        await fill_sign_up(ana, ANA)
        ben = await (await browser.new_context(**PHONE)).new_page()
        await ben.goto(BASE)
        await fill_sign_up(ben, BEN)
        await befriend(ana, ben, BEN, ANA)

        # A slow chat list: placeholders and a slow-connection notice, not "No friends yet".
        gate = asyncio.Event()

        async def slow(route):
            await gate.wait()
            await route.continue_()
        await ana.route("**/api/friends?*", slow)
        await forget_kept(ana)  # a first visit: nothing kept to show yet (test_cache.py covers that)
        await ana.reload()
        await expect(ana.locator("#chat-list .skeleton-row").first).to_be_visible(timeout=10000)
        await expect(ana.locator("#chat-empty")).to_be_hidden()
        await expect(ana.locator("#conn-banner")).to_have_text("Slow connection: still loading…", timeout=8000)
        await shot(ana, "loading-list-phone", full_page=False)
        gate.set()
        await expect(ana.locator("#chat-list .chat-name", has_text=BEN)).to_be_visible(timeout=10000)
        await expect(ana.locator("#chat-list .skeleton-row")).to_have_count(0)
        await no_placeholders(ana)
        await expect(ana.locator("#conn-banner")).to_be_hidden(timeout=5000)
        await ana.unroute("**/api/friends?*", slow)

        # A chat that's slow to open: placeholders, not "No messages yet".
        chat_gate = asyncio.Event()

        async def slow_chat(route):
            await chat_gate.wait()
            await route.continue_()
        await ana.route("**/api/chats/*/messages?*", slow_chat)
        await forget_kept(ana)
        await ana.locator("#chat-list .chat-item", has_text=BEN).click()
        await expect(ana.locator("#messages .msg-skeleton").first).to_be_visible(timeout=5000)
        assert "No messages yet" not in await ana.locator("#messages").inner_text()
        await shot(ana, "loading-chat-phone", full_page=False)
        chat_gate.set()
        await expect(ana.locator("#messages")).to_contain_text("No messages yet.", timeout=10000)
        await no_placeholders(ana)
        await ana.unroute("**/api/chats/*/messages?*", slow_chat)

        # Can't reach the server at all: says so, and offers to try again.
        async def down(route):
            await route.abort()
        await ana.route("**/api/friends?*", down)
        await ana.route("**/api/groups", down)
        await forget_kept(ana)
        await ana.reload()
        await expect(ana.locator("#chat-list .list-problem")).to_contain_text("Couldn't load your chats", timeout=20000)
        await expect(ana.locator("#conn-banner")).to_contain_text("Can't reach napsack right now")
        await expect(ana.locator("#chat-empty")).to_be_hidden()
        await shot(ana, "loading-failed-phone", full_page=False)
        await ana.unroute("**/api/friends?*", down)
        await ana.unroute("**/api/groups", down)
        await ana.locator("#chat-list .list-problem button", has_text="Try again").click()
        await expect(ana.locator("#chat-list .chat-name", has_text=BEN)).to_be_visible(timeout=10000)
        await expect(ana.locator("#conn-banner")).to_be_hidden(timeout=5000)

        # Someone with no friends at all does see the empty state, once it's known.
        new = await (await browser.new_context(**PHONE)).new_page()
        await new.goto(BASE)
        await fill_sign_up(new, f"cal_{tag}")
        await expect(new.locator("#chat-empty")).to_be_visible(timeout=10000)

        assert not errors, errors
        await browser.close()
    print("LOADING TEST PASSED")


asyncio.run(main())
