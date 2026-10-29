"""Loading and slow connections (X23): before the server answers, the app
shows placeholders shaped like what's coming, never "No friends yet" or "No
messages yet"; after a few seconds it says the connection is slow; when
requests can't get through, it says so and offers to try again. The
network is held back on purpose with Playwright's routing. Settings come
from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
PW = "correct horse battery"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}
errors = []


async def sign_up(p, name):
    await p.click("#auth-toggle")
    await p.fill("#auth-form input[name=username]", name)
    await p.fill("#auth-form input[name=password]", PW)
    await p.fill("#auth-form input[name=invite_code]", INVITE)
    await p.click("#auth-submit")
    await expect(p.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(p)


async def befriend(asker, asked, name_of_asked, name_of_asker):
    await asker.click("#friends-button")
    await asker.fill("#add-friend-form input[name=username]", name_of_asked)
    await asker.click("#add-friend-form button[type=submit]")
    await expect(asker.locator("#add-friend-note")).to_contain_text("Request sent")
    await asker.click("#friends-dialog [data-close]")
    await asked.click("#friends-button")
    await asked.locator("#incoming-list li", has_text=name_of_asker).locator("button", has_text="Accept").click()
    await asked.click("#friends-dialog [data-close]")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ctx = await browser.new_context(**PHONE)
        ana = await ctx.new_page()
        ana.on("pageerror", lambda e: errors.append(str(e)))
        await ana.goto(BASE)
        await sign_up(ana, ANA)
        ben = await (await browser.new_context(**PHONE)).new_page()
        await ben.goto(BASE)
        await sign_up(ben, BEN)
        await befriend(ana, ben, BEN, ANA)

        # A slow chat list: placeholders and a slow-connection notice, not "No friends yet".
        gate = asyncio.Event()

        async def slow(route):
            await gate.wait()
            await route.continue_()
        await ana.route("**/api/friends?*", slow)
        await ana.reload()
        await expect(ana.locator("#chat-list .skeleton-row").first).to_be_visible(timeout=10000)
        await expect(ana.locator("#chat-empty")).to_be_hidden()
        await expect(ana.locator("#conn-banner")).to_have_text("Slow connection: still loading…", timeout=8000)
        await shot(ana, "loading-list-phone", full_page=False)
        gate.set()
        await expect(ana.locator("#chat-list .chat-name", has_text=BEN)).to_be_visible(timeout=10000)
        await expect(ana.locator("#chat-list .skeleton-row")).to_have_count(0)
        await expect(ana.locator("#conn-banner")).to_be_hidden(timeout=5000)
        await ana.unroute("**/api/friends?*", slow)

        # A chat that's slow to open: placeholders, not "No messages yet".
        chat_gate = asyncio.Event()

        async def slow_chat(route):
            await chat_gate.wait()
            await route.continue_()
        await ana.route("**/api/chats/*/messages?*", slow_chat)
        await ana.locator("#chat-list .chat-item", has_text=BEN).click()
        await expect(ana.locator("#messages .msg-skeleton").first).to_be_visible(timeout=5000)
        assert "No messages yet" not in await ana.locator("#messages").inner_text()
        await shot(ana, "loading-chat-phone", full_page=False)
        chat_gate.set()
        await expect(ana.locator("#messages")).to_contain_text("No messages yet.", timeout=10000)
        await ana.unroute("**/api/chats/*/messages?*", slow_chat)

        # Can't reach the server at all: says so, and offers to try again.
        async def down(route):
            await route.abort()
        await ana.route("**/api/friends?*", down)
        await ana.route("**/api/groups", down)
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
        await sign_up(new, f"cal_{tag}")
        await expect(new.locator("#chat-empty")).to_be_visible(timeout=10000)

        assert not errors, errors
        await browser.close()
    print("LOADING TEST PASSED")


asyncio.run(main())
