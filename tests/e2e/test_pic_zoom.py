"""Zooming into an opened pic (the web's viewer, app.js). On a phone, pinch
to zoom and drag to pan; on a computer, the wheel (a trackpad pinch) zooms and
dragging pans. Neither is a tap: a zoomed pic doesn't move on to the next one
when it's panned, a tap zooms it back out, and the next pic opens unzoomed.
Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import PHONE, befriend, launch, row, shot, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
errors = []

PICK_IMAGE = """async () => {
  const c = document.createElement('canvas'); c.width = 900; c.height = 600;
  const g = c.getContext('2d'); g.fillStyle = '#2b5'; g.fillRect(0, 0, 900, 600);
  g.fillStyle = '#fff'; for (let x = 0; x < 900; x += 100) g.fillRect(x, 250, 50, 100);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'pic.png', { type: 'image/png' }));
  const input = document.querySelector('#file-input'); input.files = dt.files; input.dispatchEvent(new Event('change'));
}"""

# The stage's transform as [scale, x, y]; [1, 0, 0] when it isn't zoomed.
ZOOM = """() => {
  const t = getComputedStyle(document.querySelector('#viewer-stage')).transform;
  if (t === 'none') return [1, 0, 0];
  const m = t.match(/matrix\\(([^)]+)\\)/)[1].split(',').map(Number);
  return [m[0], m[4], m[5]];
}"""


async def send_pics(page, n):
    for _ in range(n):
        await page.click("#camera-button")
        await page.evaluate(PICK_IMAGE)
        await expect(page.locator("#send-snap")).to_be_visible(timeout=30000)
        await page.click("#send-snap")
        await expect(page.locator("#camera-dialog")).not_to_be_visible(timeout=20000)


async def zoom_is(page, test):
    """Waits until the stage has come to rest (no spring-back still running)
    with its [scale, x, y] passing `test` (a JS expression of s, x, y)."""
    try:
        await page.wait_for_function(f"""() => {{
          if (document.querySelector('#viewer-stage').getAnimations().length) return false;
          const [s, x, y] = ({ZOOM})();
          return {test};
        }}""", timeout=10000)
    except Exception:
        seen = await page.evaluate(f"""() => [({ZOOM})(), document.querySelector('#viewer-image').getBoundingClientRect().toJSON(),
          innerWidth, document.querySelector('#viewer-stage').getAnimations().length]""")
        raise AssertionError(f"zoom never came to rest with {test}: [s, x, y], image box, width, animations = {seen}")


async def touch(cdp, kind, points):
    await cdp.send("Input.dispatchTouchEvent", {"type": kind, "touchPoints": [
        {"x": x, "y": y, "id": i} for i, (x, y) in enumerate(points)]})


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors)
        ben = await sign_up(browser, BEN, errors=errors, **PHONE)
        await befriend(ana, ben, BEN, ANA)
        await row(ana, BEN).click()
        await row(ben, ANA).click()
        await send_pics(ana, 2)
        await send_pics(ben, 2)

        # Ben's phone: a pinch zooms in, about where the fingers are.
        await expect(ben.locator("button.snap-chip")).to_have_count(2, timeout=15000)
        await ben.locator("button.snap-chip").first.tap()
        await expect(ben.locator("#viewer-image")).to_be_visible(timeout=20000)
        await expect(ben.locator("#viewer-count")).to_have_text("1 of 2")
        await expect(ben.locator("#viewer-hint")).to_have_text("Tap for the next one")
        cdp = await ben.context.new_cdp_session(ben)
        cx, cy = 195, 422
        await touch(cdp, "touchStart", [(cx - 40, cy), (cx + 40, cy)])
        for step in range(1, 9):
            await touch(cdp, "touchMove", [(cx - 40 - 12 * step, cy), (cx + 40 + 12 * step, cy)])
        await touch(cdp, "touchEnd", [])
        await zoom_is(ben, "s > 1.8")
        await expect(ben.locator("#viewer-hint")).to_have_text("Tap to zoom out")
        await expect(ben.locator("#viewer-count")).to_have_text("1 of 2")  # still the first
        await shot(ben, "pic-zoom-phone", full_page=False)

        # A drag pans it, and isn't a tap: the same pic stays.
        s, x0, _ = await ben.evaluate(ZOOM)
        await touch(cdp, "touchStart", [(cx, cy)])
        for step in range(1, 7):
            await touch(cdp, "touchMove", [(cx + 15 * step, cy)])
        await touch(cdp, "touchEnd", [])
        await zoom_is(ben, f"x > {x0} + 40")
        await expect(ben.locator("#viewer-count")).to_have_text("1 of 2")
        # Dragged far past the edge, it springs back to it.
        await touch(cdp, "touchStart", [(cx, cy)])
        for step in range(1, 7):
            await touch(cdp, "touchMove", [(cx + 150 * step, cy)])
        await touch(cdp, "touchEnd", [])
        # Its left edge back at the screen's, measured where it's drawn.
        await zoom_is(ben, "Math.abs(document.querySelector('#viewer-image').getBoundingClientRect().left) < 2")
        await expect(ben.locator("#viewer-count")).to_have_text("1 of 2")

        # A tap zooms back out; the next tap moves on, and the next pic opens unzoomed.
        await ben.locator("#viewer").tap()
        await zoom_is(ben, "s === 1 && x === 0 && y === 0")
        await expect(ben.locator("#viewer-hint")).to_have_text("Tap for the next one")
        await expect(ben.locator("#viewer-count")).to_have_text("1 of 2")
        await ben.locator("#viewer").tap()
        await expect(ben.locator("#viewer-count")).to_have_text("2 of 2", timeout=20000)
        await expect(ben.locator("#viewer-image")).to_be_visible(timeout=20000)
        await expect(ben.locator("#viewer-hint")).to_have_text("Tap to close")
        assert await ben.evaluate(ZOOM) == [1, 0, 0]
        print("phone: pinch zooms, a drag pans without moving on, a tap zooms out")

        # Ana's computer: the wheel zooms where the pointer is; a mouse drag pans
        # and isn't a click; Escape stops, and the next pic opens unzoomed.
        await expect(ana.locator("button.snap-chip")).to_have_count(2, timeout=15000)
        await ana.locator("button.snap-chip").first.click()
        await expect(ana.locator("#viewer-image")).to_be_visible(timeout=20000)
        await expect(ana.locator("#viewer-count")).to_have_text("1 of 2")
        box = await ana.locator("#viewer").bounding_box()
        mx, my = box["width"] / 2 + 100, box["height"] / 2
        await ana.mouse.move(mx, my)
        await ana.mouse.wheel(0, -400)
        await zoom_is(ana, "s > 1.5")
        await expect(ana.locator("#viewer-hint")).to_have_text("Tap to zoom out")
        await shot(ana, "pic-zoom-desktop", full_page=False)
        _, x0, _ = await ana.evaluate(ZOOM)
        await ana.mouse.down()
        for step in range(1, 7):
            await ana.mouse.move(mx - 20 * step, my)
        await ana.mouse.up()
        await zoom_is(ana, f"x < {x0} - 40")
        await expect(ana.locator("#viewer-count")).to_have_text("1 of 2")  # the drag's click didn't move on
        await ana.mouse.click(mx, my)
        await zoom_is(ana, "s === 1")
        await expect(ana.locator("#viewer-count")).to_have_text("1 of 2")
        await ana.mouse.wheel(0, -400)
        await zoom_is(ana, "s > 1.5")
        await ana.keyboard.press("Escape")
        await expect(ana.locator("#viewer")).to_be_hidden()
        await expect(ana.locator("button.snap-chip")).to_have_count(1, timeout=10000)
        await ana.locator("button.snap-chip").click()
        await expect(ana.locator("#viewer-image")).to_be_visible(timeout=20000)
        await expect(ana.locator("#viewer-hint")).to_have_text("Tap to close")
        assert await ana.evaluate(ZOOM) == [1, 0, 0]
        print("computer: the wheel zooms, a drag pans without moving on, the next opens unzoomed")

        assert not errors, errors
        print("PIC ZOOM TEST PASSED")
        await browser.close()


asyncio.run(main())
