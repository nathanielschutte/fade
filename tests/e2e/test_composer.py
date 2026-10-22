"""Writing and refreshing: the message box grows to four lines and then
scrolls (X5); Enter sends on a computer, Return is a new line on a phone (X5);
Send keeps the keyboard up, and dragging the chat down puts it away (X6);
pulling the chat list down refetches it (X7). Settings come from the
environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}


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


async def drag(page, selector, dy):
    """A finger dragging down `dy` pixels from near the top of `selector`."""
    box = await page.locator(selector).bounding_box()
    x, y = box["x"] + box["width"] / 2, box["y"] + 30
    cdp = await page.context.new_cdp_session(page)
    await cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
    for i in range(1, 11):
        await cdp.send("Input.dispatchTouchEvent", {"type": "touchMove", "touchPoints": [{"x": x, "y": y + dy * i / 10}]})
        await asyncio.sleep(0.02)
    await cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})


async def height(page):
    return await page.evaluate("document.querySelector('#composer-input').getBoundingClientRect().height")


async def focused(page):
    return await page.evaluate("document.activeElement && document.activeElement.id")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA)
        ben = await sign_up(browser, BEN, **PHONE)
        await befriend(ana, ben, BEN, ANA)

        # A computer: one line is the 46px pill; a long message grows to four lines and stops.
        await ana.locator(".chat-item", has_text=BEN).click()
        box = ana.locator("#composer-input")
        await box.fill("hello")
        one = await height(ana)
        assert abs(one - 46) < 1, one
        await box.fill("\n".join(f"line {i}" for i in range(12)))
        four = await height(ana)
        assert 112 < four < 120, four
        assert await ana.evaluate("(e => e.scrollHeight > e.clientHeight)(document.querySelector('#composer-input'))")
        await box.fill("")
        assert abs(await height(ana) - 46) < 1

        # Shift+Enter is a new line, Enter sends, and the box shrinks back.
        await box.type("line one")
        await box.press("Shift+Enter")
        await box.type("line two")
        assert abs(await height(ana) - 69) < 2, await height(ana)  # two lines
        await box.press("Enter")
        await expect(ana.locator(".msg", has_text="line two")).to_be_visible(timeout=10000)
        await expect(box).to_have_value("")
        assert abs(await height(ana) - 46) < 1
        await expect(ben.locator(".chat-item", has_text=ANA)).to_be_visible(timeout=10000)
        await ben.locator(".chat-item", has_text=ANA).click()
        body = ben.locator(".msg-body", has_text="line two")
        await expect(body).to_be_visible(timeout=10000)
        assert await body.inner_text() == "line one\nline two"

        # Clicking Send leaves the cursor in the box, ready for the next message.
        await box.fill("focus stays")
        await ana.click("#composer .send")
        await expect(ana.locator(".msg", has_text="focus stays")).to_be_visible(timeout=10000)
        assert await focused(ana) == "composer-input"

        # A phone: Return is a new line; the Send button sends and keeps the keyboard up.
        pbox = ben.locator("#composer-input")
        await pbox.tap()
        await pbox.type("first")
        await pbox.press("Enter")
        await pbox.type("second")
        await expect(pbox).to_have_value("first\nsecond")
        await shot(ben, "composer-phone-two-lines", full_page=False)
        await ben.tap("#composer .send")
        await expect(ben.locator(".msg-body", has_text="second")).to_be_visible(timeout=10000)
        await expect(pbox).to_have_value("")
        assert await focused(ben) == "composer-input", await focused(ben)

        # Dragging the chat down puts the keyboard away.
        await drag(ben, "#messages", 120)
        assert await focused(ben) != "composer-input"

        # Pull to refresh: the chat list refetches, and the indicator tucks away after.
        await ben.tap("#back-button")
        await expect(ben.locator("#chat-list")).to_be_visible()
        async with ben.expect_request(lambda r: r.method == "GET" and r.url.endswith("/api/friends"), timeout=5000):
            await drag(ben, "#chat-list", 220)
        await expect(ben.locator("#pull")).to_have_css("height", "0px", timeout=5000)
        # A short pull doesn't.
        fetched = []
        ben.on("request", lambda r: r.url.endswith("/api/friends") and fetched.append(r))
        await asyncio.sleep(3.2)  # past the refresh throttle
        await drag(ben, "#chat-list", 60)
        await asyncio.sleep(1)
        assert not fetched, "a short pull shouldn't refresh"
        await expect(ben.locator("#pull")).to_have_css("height", "0px")

        # Desktop never sees the indicator.
        assert await ana.evaluate("document.querySelector('#pull').getBoundingClientRect().height") == 0

        await browser.close()
    print("COMPOSER TEST PASSED")


asyncio.run(main())
