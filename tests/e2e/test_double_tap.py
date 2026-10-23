"""Double taps: on a chat in the list, open it with the camera up (one tap
just opens the chat); on the live camera, switch between front and back.
Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}

# Headless Chrome has no camera here; stand in a canvas stream, and remember
# which way each request asked the camera to face.
CAMERA = """window.__facing = [];
navigator.mediaDevices.getUserMedia = async (want) => {
  window.__facing.push(want?.video?.facingMode ?? null);
  const c = document.createElement('canvas'); c.width = 1280; c.height = 720;
  const g = c.getContext('2d');
  setInterval(() => { g.fillStyle = '#3a6'; g.fillRect(0, 0, 1280, 720); }, 30);
  return c.captureStream(30);
};"""


async def sign_up(browser, name, **ctx):
    context = await browser.new_context(**ctx)
    await context.add_init_script(CAMERA)
    page = await context.new_page()
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


async def double_tap(page, locator, gap=0.12):
    box = await locator.bounding_box()
    x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
    await page.touchscreen.tap(x, y)
    await asyncio.sleep(gap)
    await page.touchscreen.tap(x, y)


async def until(page, js, timeout=10):
    """Polls `js` in the page (the CSP rules out wait_for_function)."""
    for _ in range(int(timeout * 10)):
        if await page.evaluate(js):
            return
        await asyncio.sleep(0.1)
    raise AssertionError(f"timed out waiting for {js}")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA)
        ben = await sign_up(browser, BEN, **PHONE)
        await befriend(ana, ben, BEN, ANA)
        await expect(row(ben, ANA)).to_be_visible(timeout=10000)

        # A phone: one tap just opens the chat, after only a moment.
        start = asyncio.get_running_loop().time()
        await row(ben, ANA).tap()
        await expect(ben.locator("#back-button")).to_be_visible()
        waited = asyncio.get_running_loop().time() - start
        assert waited < 0.6, f"a tap took {waited:.2f}s to open the chat"
        await expect(ben.locator("#chat-title")).to_have_text(ANA)
        await asyncio.sleep(0.6)
        await expect(ben.locator("#camera-dialog")).not_to_be_visible()
        await ben.click("#back-button")

        # Two taps: the chat, with the camera up. The second tap lands on the
        # chat (it now covers the list) and does nothing else there.
        await double_tap(ben, row(ben, ANA))
        await expect(ben.locator("#camera-dialog")).to_be_visible(timeout=5000)
        await expect(ben.locator("#chat-title")).to_have_text(ANA)
        await until(ben, "document.querySelector('#camera-video').videoWidth > 100")
        await shot(ben, "double-tap-camera")

        # Double-tapping the live camera switches it, as the button does.
        before = await ben.evaluate("window.__facing.slice()")
        await double_tap(ben, ben.locator("#camera-video"))
        await until(ben, f"window.__facing.length > {len(before)}")
        after = await ben.evaluate("window.__facing")
        assert after[-1] != before[-1], (before, after)
        # A single tap doesn't.
        await asyncio.sleep(0.5)
        count = len(after)
        box = await ben.locator("#camera-video").bounding_box()
        await ben.touchscreen.tap(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        await asyncio.sleep(0.6)
        assert await ben.evaluate("window.__facing.length") == count
        await ben.click("#camera-dialog [data-close]")
        await expect(ben.locator("#camera-dialog")).not_to_be_visible()

        # A slower double tap: the chat has already opened under the finger,
        # and the second tap still goes to the camera (and nothing else).
        await ben.click("#back-button")
        await double_tap(ben, row(ben, ANA), gap=0.25)
        await expect(ben.locator("#camera-dialog")).to_be_visible(timeout=5000)
        await expect(ben.locator("#chat-title")).to_have_text(ANA)
        await ben.click("#camera-dialog [data-close]")
        await expect(ben.locator("#camera-dialog")).not_to_be_visible()
        # Two taps far apart are two taps: the chat opens, no camera.
        await ben.click("#back-button")
        await row(ben, ANA).tap()
        await asyncio.sleep(0.6)
        await expect(ben.locator("#camera-dialog")).not_to_be_visible()

        # A computer: double-clicking the row does the same.
        await row(ana, BEN).dblclick()
        await expect(ana.locator("#camera-dialog")).to_be_visible(timeout=5000)
        await expect(ana.locator("#chat-title")).to_have_text(BEN)
        await ana.click("#camera-dialog [data-close]")
        # A click opens the chat and nothing more.
        await row(ana, BEN).click()
        await asyncio.sleep(0.6)
        await expect(ana.locator("#camera-dialog")).not_to_be_visible()

        await browser.close()
    print("DOUBLE TAP TEST PASSED")


asyncio.run(main())
