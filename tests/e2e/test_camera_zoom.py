"""Camera zoom (X27): the 1× button steps through zooms, and two fingers pinch.
Where the browser offers the camera's own zoom, napsack asks the camera;
otherwise it enlarges the middle of the preview and crops the photo to match.
The camera is a stub: a frame that's black with a white middle, so a 2× crop
is all white. Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import launch, shot, PHONE, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
errors = []

# window.__zoom: the camera's own zoom range to report, or null for none.
STUB = """
window.__zoom = null;
window.__applied = [];
navigator.mediaDevices.getUserMedia = async () => {
  const c = document.createElement('canvas'); c.width = 1280; c.height = 720;
  const g = c.getContext('2d');
  setInterval(() => { g.fillStyle = '#000'; g.fillRect(0, 0, 1280, 720); g.fillStyle = '#fff'; g.fillRect(320, 180, 640, 360); }, 30);
  const stream = c.captureStream(30);
  const track = stream.getVideoTracks()[0];
  const real = track.getSettings.bind(track);
  track.getSettings = () => ({ ...real(), facingMode: 'environment' });
  track.getCapabilities = () => (window.__zoom ? { zoom: window.__zoom } : {});
  track.applyConstraints = async (c) => { window.__applied.push(c); };
  return stream;
};
"""

# The photo's size, and whether its corner is light (the middle) or dark (the edge).
PHOTO = """async () => {
  const img = document.querySelector('#camera-preview');
  await img.decode();
  const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
  const g = c.getContext('2d'); g.drawImage(img, 0, 0);
  const [r] = g.getImageData(8, 8, 1, 1).data;
  return { width: img.naturalWidth, corner: r > 128 ? 'light' : 'dark' };
}"""


async def pinch(page, cdp, spread_from, spread_to):
    """Two fingers on the middle of the camera, moving apart (or together)."""
    box = await page.locator(".camera-stage").bounding_box()
    cx, cy = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2

    def points(gap):
        return [{"x": cx - gap / 2, "y": cy, "id": 0}, {"x": cx + gap / 2, "y": cy, "id": 1}]
    await cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": points(spread_from)})
    for i in range(1, 9):
        gap = spread_from + (spread_to - spread_from) * i / 8
        await cdp.send("Input.dispatchTouchEvent", {"type": "touchMove", "touchPoints": points(gap)})
    await cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, init=STUB, **PHONE)
        cdp = await ana.context.new_cdp_session(ana)

        # No zoom from the camera: the preview enlarges, and the photo is cropped.
        await ana.click("#tab-camera")
        chip = ana.locator("#zoom-chip")
        await expect(chip).to_have_text("1×", timeout=10000)
        await ana.wait_for_timeout(300)
        await ana.click("#shutter")
        await expect(ana.locator("#camera-preview")).to_be_visible()
        assert await ana.evaluate(PHOTO) == {"width": 1280, "corner": "dark"}
        await expect(chip).to_be_hidden()  # not over a photo
        await ana.click("#retake")
        await expect(chip).to_be_visible()
        await chip.click()
        await expect(chip).to_have_text("2×")
        assert "scale(2)" in await ana.locator("#camera-video").evaluate("v => v.style.transform")
        await shot(ana, "zoom-2x-phone", full_page=False)
        await ana.click("#shutter")
        await expect(ana.locator("#camera-preview")).to_be_visible()
        assert await ana.evaluate(PHOTO) == {"width": 640, "corner": "light"}, "a 2× photo is the middle half"
        await ana.click("#retake")
        await chip.click()
        await expect(chip).to_have_text("3×")  # as far as cropping goes
        await chip.click()
        await expect(chip).to_have_text("1×")
        print("button: 1×, 2×, 3×, back to 1×; the photo is cropped to match")

        # Two fingers apart: zooms in; together: back out. Never past the ends.
        await pinch(ana, cdp, 80, 200)
        await expect(chip).to_have_text("2.5×")
        await pinch(ana, cdp, 100, 400)
        await expect(chip).to_have_text("3×")
        await pinch(ana, cdp, 300, 30)
        await expect(chip).to_have_text("1×")
        print("pinch zooms in and out, within 1× to 3×")

        # Closing the camera starts the next one at 1×.
        await pinch(ana, cdp, 100, 200)
        await ana.click("#capture-controls [data-close]")
        await ana.click("#tab-camera")
        await expect(chip).to_have_text("1×", timeout=10000)
        await ana.click("#capture-controls [data-close]")

        # The camera's own zoom (to 8×): napsack asks the camera, and doesn't crop.
        await ana.evaluate("window.__zoom = { min: 1, max: 8, step: 0.1 }")
        await ana.click("#tab-camera")
        await expect(chip).to_have_text("1×", timeout=10000)
        await ana.wait_for_timeout(300)
        await chip.click()
        await chip.click()
        await expect(chip).to_have_text("5×")
        await ana.wait_for_timeout(200)
        applied = await ana.evaluate("window.__applied.map((c) => c.advanced[0].zoom)")
        assert applied[-1] == 5 and 2 in applied, applied
        assert await ana.locator("#camera-video").evaluate("v => v.style.transform") == ""
        await pinch(ana, cdp, 100, 400)
        await expect(chip).to_have_text("8×")
        await ana.click("#shutter")
        await expect(ana.locator("#camera-preview")).to_be_visible()
        assert (await ana.evaluate(PHOTO))["width"] == 1280, "the camera zoomed; the photo isn't cropped"
        print("uses the camera's own zoom when there is one")

        assert not errors, errors
        await browser.close()
    print("ZOOM TEST PASSED")


asyncio.run(main())
