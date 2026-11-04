"""Texts stay in the order they were written (X40). Each chat's outbox sends
one at a time: a text goes to the server only once the one before it has its
answer, so the server's ids (the order everywhere, paging included) follow
the writing. Writing stays instant; a text that fails holds the ones after it,
and the page says so, until it's sent again or removed. Groups the same.
Settings come from the environment; see common.py."""
import asyncio, json, uuid
from playwright.async_api import async_playwright, expect

from common import PHONE, befriend, launch, row, shot, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
GROUP = f"Order {tag}"
errors = []


async def write(page, text):
    await page.fill("#composer-input", text)
    await page.press("#composer-input", "Enter")


async def first_one_slow(page, pattern):
    """The first text's request reaches the server only after a while (a slow
    connection), long after the next two were written. Returns the client ids
    of the posts, in the order they set off, and how many others had set off
    when the first was let through."""
    posts, overtaken = [], []

    async def handler(route):
        if route.request.method != "POST":
            return await route.continue_()
        posts.append(json.loads(route.request.post_data)["client_id"])
        if len(posts) == 1:
            await asyncio.sleep(1.5)  # the slow connection itself
            overtaken.append(len(posts) - 1)
        await route.continue_()
    await page.route(pattern, handler)
    return posts, overtaken


async def in_order(page, other, words, pattern):
    posts, overtaken = await first_one_slow(page, pattern)
    for w in words:
        await write(page, w)
    # All three show at once, before any has its answer.
    await expect(page.locator("#messages .msg.pending")).to_have_count(3)
    await expect(page.locator("#messages .msg.pending .msg-body")).to_have_text(words)
    await expect(page.locator("#messages .msg.pending")).to_have_count(0, timeout=15000)
    assert overtaken == [0], f"{overtaken} sent before the first had its answer"
    assert len(posts) == 3, posts
    await page.unroute(pattern)
    # Stored in the order written: what the other side sees, and a fresh load.
    await expect(other.locator("#messages .msg-body").filter(has_text=tag)).to_have_text(words, timeout=10000)
    return posts


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors)
        ben = await sign_up(browser, BEN, errors=errors, **PHONE)
        await befriend(ana, ben, BEN, ANA)
        await row(ana, BEN).click()
        await row(ben, ANA).click()

        # A slow first send isn't overtaken by the two written after it.
        words = [f"one {tag}", f"two {tag}", f"three {tag}"]
        await in_order(ana, ben, words, "**/api/chats/*/messages")
        await ana.reload()
        await row(ana, BEN).click()
        await expect(ana.locator("#messages .msg-body").filter(has_text=tag)).to_have_text(words, timeout=10000)
        print("texts written quickly are stored in the order written")

        # One that fails holds the ones after it, and says so; Try again sends all three, in order.
        posts = []

        async def refuse_first(route):
            if route.request.method != "POST":
                return await route.continue_()
            posts.append(1)
            if len(posts) == 1:
                return await route.fulfill(status=400, content_type="application/json",
                                           body=json.dumps({"error": "Something was wrong with that."}))
            await route.continue_()
        await ana.route("**/api/chats/*/messages", refuse_first)
        held = [f"four {tag}", f"five {tag}", f"six {tag}"]
        for w in held:
            await write(ana, w)
        failed = ana.locator("#messages .send-failed")
        await expect(failed).to_contain_text("Not sent: Something was wrong with that. The 2 texts after it wait for it.")
        await expect(ana.locator("#messages .msg-meta", has_text="Waiting for the text above.")).to_have_count(2)
        await expect(ana.locator("#messages .msg.pending")).to_have_count(3)
        await shot(ana, "send-order-held", full_page=False)
        assert len(posts) == 1, posts  # the two after it never set off
        await failed.locator("button", has_text="Try again").click()
        await expect(ana.locator("#messages .msg.pending")).to_have_count(0, timeout=15000)
        await expect(ben.locator("#messages .msg-body").filter(has_text=tag)).to_have_text(words + held, timeout=10000)

        # Removing the one that failed lets the rest go; its words go back in the box.
        posts.clear()
        gone = [f"seven {tag}", f"eight {tag}"]
        for w in gone:
            await write(ana, w)
        await expect(failed).to_contain_text("The text after it waits for it.")
        await failed.locator("button", has_text="Remove").click()
        await expect(ana.locator("#messages .msg.pending")).to_have_count(0, timeout=15000)
        await expect(ana.locator("#composer-input")).to_have_value(gone[0])
        await expect(ben.locator("#messages .msg-body").filter(has_text=tag)).to_have_text(words + held + gone[1:], timeout=10000)
        await ana.unroute("**/api/chats/*/messages")
        print("a failed text holds the ones after it until it's sent again or removed")

        # Groups keep their order the same way.
        await ana.fill("#composer-input", "")
        await ana.click("#start-button")
        await ana.fill("#new-group-name", GROUP)
        await ana.locator("#new-group-friends label", has_text=BEN).locator("input").check()
        await ana.click("#new-group-submit")
        await expect(ana.locator("#chat-title")).to_have_text(GROUP)
        await ben.click("#back-button")
        await row(ben, GROUP).click()
        await in_order(ana, ben, [f"g1 {tag}", f"g2 {tag}", f"g3 {tag}"], "**/api/groups/*/messages")
        print("group texts too")

        assert not errors, errors
        print("SEND ORDER TEST PASSED")
        await browser.close()


asyncio.run(main())
