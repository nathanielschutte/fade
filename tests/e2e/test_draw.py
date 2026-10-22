"""Drawing on a pic before sending it (F13): a pen in colors and sizes,
stickers you move and resize, undo, and the drawing flattened into the photo
(so it's encrypted like any pic). The friend's viewer shows it: the test reads
the received photo's pixels. Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}

# A plain gray photo, chosen from "files" (headless Chromium has no camera).
PICK_GRAY = """async () => {
  const c = document.createElement('canvas'); c.width = 800; c.height = 600;
  const x = c.getContext('2d'); x.fillStyle = '#808080'; x.fillRect(0, 0, 800, 600);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'gray.png', { type: 'image/png' }));
  const input = document.querySelector('#file-input'); input.files = dt.files;
  input.dispatchEvent(new Event('change', { bubbles: true }));
}"""

# The pixel at (fx, fy) of the image the viewer is showing, as [r, g, b].
PIXEL = """([fx, fy]) => {
  const img = document.querySelector('#viewer-image');
  const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
  const x = c.getContext('2d'); x.drawImage(img, 0, 0);
  return [...x.getImageData(Math.round(fx * c.width), Math.round(fy * c.height), 1, 1).data.slice(0, 3)];
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


async def drag(page, x0, y0, x1, y1, steps=12):
    await page.mouse.move(x0, y0)
    await page.mouse.down()
    for i in range(1, steps + 1):
        await page.mouse.move(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)
    await page.mouse.up()


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA)
        ben = await sign_up(browser, BEN, **PHONE)
        await befriend(ana, ben, BEN, ANA)

        # Ana takes a (gray) pic: the drawing tools appear with it.
        await ana.locator(".chat-item", has_text=BEN).click()
        await ana.click("#camera-button")
        await ana.evaluate(PICK_GRAY)
        await expect(ana.locator("#camera-preview")).to_be_visible(timeout=10000)
        await expect(ana.locator("#draw-tools")).to_be_visible()
        await expect(ana.locator("#draw-undo")).to_be_disabled()

        # A thick red line across the middle.
        await ana.click("#draw-pen")
        await expect(ana.locator("#draw-pen")).to_have_attribute("aria-pressed", "true")
        await ana.click("#draw-colors .swatch[aria-label='Color #ff4d4d']")
        await ana.click("#draw-size")
        await expect(ana.locator("#draw-size")).to_have_text("Thick")
        box = await ana.locator("#draw-layer").bounding_box()
        mid = box["y"] + box["height"] / 2
        await drag(ana, box["x"] + box["width"] * 0.15, mid, box["x"] + box["width"] * 0.85, mid)
        await expect(ana.locator("#draw-undo")).to_be_enabled()
        # A second line, taken back with undo.
        low = box["y"] + box["height"] * 0.8
        await drag(ana, box["x"] + box["width"] * 0.2, low, box["x"] + box["width"] * 0.8, low)
        await ana.click("#draw-undo")

        # A sticker: added in the middle, dragged to the top left, made bigger, and the size undone.
        await ana.click("#draw-sticker")
        await expect(ana.locator("#draw-pen")).to_have_attribute("aria-pressed", "false")
        await ana.click("#sticker-tray .sticker-pick[aria-label='Add 🔥']")
        sticker = ana.locator("#sticker-layer .sticker")
        await expect(sticker).to_have_count(1)
        sb = await sticker.bounding_box()
        await drag(ana, sb["x"] + sb["width"] / 2, sb["y"] + sb["height"] / 2,
                   box["x"] + box["width"] * 0.2, box["y"] + box["height"] * 0.22)
        size = await sticker.evaluate("e => e.style.fontSize")
        await ana.click("#sticker-bigger")
        assert await sticker.evaluate("e => e.style.fontSize") != size
        await ana.click("#draw-undo")
        assert await sticker.evaluate("e => e.style.fontSize") == size, "undo puts the size back"
        await shot(ana, "draw-desktop", full_page=False)

        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).not_to_be_visible(timeout=10000)
        print("drew a line, undid another, placed and resized a sticker, sent")

        # Ben opens it: the red line is in the photo itself; the undone one isn't.
        await ben.locator(".chat-item", has_text=ANA).click()
        await ben.locator("button.snap-chip").first.click()
        for _ in range(100):  # (the page's CSP forbids wait_for_function's eval)
            if await ben.evaluate("(() => { const i = document.querySelector('#viewer-image'); return i.complete && i.naturalWidth > 0; })()"):
                break
            await asyncio.sleep(0.1)
        r, g, b = await ben.evaluate(PIXEL, [0.5, 0.5])
        assert r > 180 and g < 130 and b < 130, f"the line: {(r, g, b)}"
        r2, g2, b2 = await ben.evaluate(PIXEL, [0.5, 0.8])
        assert abs(r2 - g2) < 20 and abs(g2 - b2) < 20 and 90 < r2 < 170, f"undone, so still gray: {(r2, g2, b2)}"
        await ben.click("#viewer")
        print("the friend's photo has the drawing flattened in")

        # On a phone the toolbar fits and nothing scrolls sideways.
        await ben.click("#camera-button")
        await ben.evaluate(PICK_GRAY)
        await expect(ben.locator("#draw-tools")).to_be_visible(timeout=10000)
        await ben.tap("#draw-pen")
        tools = await ben.locator("#draw-tools").bounding_box()
        assert tools["x"] >= 0 and tools["x"] + tools["width"] <= 390, tools
        overflow = await ben.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"scrolls sideways by {overflow}px"
        await shot(ben, "draw-phone", full_page=False)
        # Retake clears the drawing tools back to a fresh start.
        await ben.tap("#retake")
        await expect(ben.locator("#draw-tools")).to_be_hidden()
        await browser.close()
    print("DRAW TEST PASSED")


asyncio.run(main())
