"""A bad connection never loses or doubles anything. A text whose response is
lost on the way back is stored once; a text sent offline waits as "Not sent"
and goes by itself when the connection returns; a pic whose upload response
is lost is sent once; and a pic whose download fails stays unopened, to open
again later. Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
GROUP = f"Bus {tag}"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}

PICK_IMAGE = """async () => {
  const c = document.createElement('canvas'); c.width = 900; c.height = 600;
  const g = c.getContext('2d'); g.fillStyle = '#2b5'; g.fillRect(0, 0, 900, 600); g.fillStyle = '#fff'; g.fillRect(300, 150, 300, 300);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'pic.png', { type: 'image/png' }));
  const input = document.querySelector('#file-input'); input.files = dt.files; input.dispatchEvent(new Event('change'));
}"""


async def sign_up(browser, name, **ctx):
    page = await (await browser.new_context(**ctx)).new_page()
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


async def lose_first_response(page, pattern):
    """The request reaches the server, but the answer never comes back (once)."""
    lost = []

    async def handler(route):
        if route.request.method == "POST" and not lost:
            await route.fetch()
            lost.append(route.request.url)
            await route.abort("connectionreset")
        else:
            await route.continue_()
    await page.route(pattern, handler)
    return lost


async def send_text(page, text):
    await page.fill("#composer-input", text)
    await page.press("#composer-input", "Enter")


def bubbles(page, text):
    return page.locator("#messages .msg-body", has_text=text)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA)
        ben = await sign_up(browser, BEN, **PHONE)
        await befriend(ana, ben, BEN, ANA)
        await row(ana, BEN).click()
        await row(ben, ANA).click()

        # A text whose response is lost: retried with the same id, stored once.
        lost = await lose_first_response(ana, "**/api/chats/*/messages")
        await send_text(ana, "made it once")
        await expect(bubbles(ben, "made it once")).to_have_count(1, timeout=15000)
        await expect(bubbles(ana, "made it once")).to_have_count(1, timeout=15000)
        await expect(ana.locator("#messages .msg.pending")).to_have_count(0, timeout=15000)
        assert lost, "the first send's response was dropped"
        await asyncio.sleep(1.5)
        await expect(bubbles(ben, "made it once")).to_have_count(1)
        await ana.unroute("**/api/chats/*/messages")

        # Offline: a note says so, the text waits as "Not sent", and goes by
        # itself when the connection is back.
        await ana.context.set_offline(True)
        await expect(ana.locator("#conn-banner")).to_contain_text("offline")
        await send_text(ana, "sent while offline")
        await expect(ana.locator("#messages .msg.pending", has_text="sent while offline")).to_be_visible()
        await expect(ana.locator("#messages .send-failed")).to_contain_text("Not sent", timeout=15000)
        await shot(ana, "resilience-offline")
        await ana.context.set_offline(False)
        await expect(ana.locator("#conn-banner")).to_be_hidden(timeout=10000)
        await expect(bubbles(ben, "sent while offline")).to_have_count(1, timeout=20000)
        await expect(ana.locator("#messages .msg.pending")).to_have_count(0, timeout=10000)
        await expect(bubbles(ana, "sent while offline")).to_have_count(1)

        # Ben reads a text before Ana's own copy is back from the server (her
        # answer is slow): it still says "Seen" once it lands.
        gate = asyncio.Event()

        async def slow_answer(route):
            if route.request.method != "POST":
                return await route.continue_()
            res = await route.fetch()
            await gate.wait()
            await route.fulfill(response=res)
        await ana.route("**/api/chats/*/messages", slow_answer)
        await send_text(ana, "read before it landed")
        await expect(bubbles(ben, "read before it landed")).to_have_count(1, timeout=15000)
        await asyncio.sleep(1.5)  # Ben's page marks it read, and Ana hears so first
        gate.set()
        await expect(ana.locator("#messages .msg.pending")).to_have_count(0, timeout=15000)
        await expect(ana.locator("#messages > li").last).to_have_text("Seen", timeout=5000)
        items = await ana.locator("#messages > li").all_text_contents()
        assert "read before it landed" in items[-2], items[-4:]
        await ana.unroute("**/api/chats/*/messages", slow_answer)

        # A pic whose upload response is lost: tried again with the same id, sent once.
        lost = await lose_first_response(ana, "**/api/chats/*/snaps*")
        await ana.click("#camera-button")
        await ana.evaluate(PICK_IMAGE)
        await expect(ana.locator("#send-snap")).to_be_visible(timeout=30000)
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).not_to_be_visible(timeout=20000)
        assert lost, "the pic upload's response was dropped"
        await expect(ben.locator("button.snap-chip")).to_have_count(1, timeout=15000)
        await asyncio.sleep(1.5)
        await expect(ben.locator("button.snap-chip")).to_have_count(1)
        await ana.unroute("**/api/chats/*/snaps*")

        # Ben's download keeps failing: the viewer says so, and the pic stays unopened.
        async def fail(route):
            await route.abort("connectionreset")
        await ben.route("**/api/snaps/*", fail)
        await ben.locator("button.snap-chip").click()
        await expect(ben.locator("#viewer-error")).to_contain_text("still unopened", timeout=20000)
        await shot(ben, "resilience-viewer-error")
        await ben.click("#viewer")
        await expect(ben.locator("#viewer")).to_be_hidden()
        await expect(ben.locator("button.snap-chip")).to_contain_text("Tap to view pic")

        # The first try fails, then it works: the app retries by itself, and
        # only once it's on screen does it count as opened.
        await ben.unroute("**/api/snaps/*")
        tries = []

        async def flaky(route):
            if route.request.method == "GET":
                tries.append(1)
                if len(tries) == 1:
                    return await route.abort("connectionreset")
            await route.continue_()
        await ben.route("**/api/snaps/**", flaky)
        await ben.locator("button.snap-chip").click()
        await expect(ben.locator("#viewer-image")).to_be_visible(timeout=20000)
        await expect(ben.locator("#viewer-hint")).to_have_text("Tap to close")
        assert len(tries) >= 2, tries
        await asyncio.sleep(0.8)  # past the tap guard
        await ben.click("#viewer")
        await expect(ben.locator("#viewer")).to_be_hidden()
        await expect(ben.locator("button.snap-chip")).to_have_count(0, timeout=10000)
        await expect(ana.locator(".snap-chip.done").last).to_contain_text("Opened", timeout=10000)

        # Groups: a resend after a lost response is stored once too.
        await ana.click("#start-button")
        await ana.fill("#new-group-name", GROUP)
        await ana.locator("#new-group-friends label", has_text=BEN).locator("input").check()
        await ana.click("#new-group-submit")
        await expect(ana.locator("#chat-title")).to_have_text(GROUP)
        await ben.click("#back-button")  # (a phone: back to the chat list)
        await expect(row(ben, GROUP)).to_be_visible(timeout=10000)
        await row(ben, GROUP).click()
        lost = await lose_first_response(ana, "**/api/groups/*/messages")
        await send_text(ana, "group once")
        await expect(bubbles(ben, "group once")).to_have_count(1, timeout=15000)
        await expect(ana.locator("#messages .msg.pending")).to_have_count(0, timeout=15000)
        assert lost
        await asyncio.sleep(1.5)
        await expect(bubbles(ben, "group once")).to_have_count(1)
        await expect(bubbles(ana, "group once")).to_have_count(1)

        await browser.close()
    print("RESILIENCE TEST PASSED")


asyncio.run(main())
