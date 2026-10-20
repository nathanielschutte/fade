"""Front camera snaps are mirrored like the preview; back camera snaps aren't.
Settings come from the environment; see common.py."""
import asyncio, sys, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot
tag = uuid.uuid4().hex[:5]

# A frame that's red on the left, blue on the right. The stub reports the facing
# the test asks for, like a phone's front or back camera would.
STUB = """
window.__facing = 'user';
navigator.mediaDevices.getUserMedia = async () => {
  const c = document.createElement('canvas'); c.width = 1280; c.height = 720;
  const g = c.getContext('2d');
  setInterval(() => { g.fillStyle = '#d00'; g.fillRect(0, 0, 640, 720); g.fillStyle = '#00d'; g.fillRect(640, 0, 640, 720); }, 30);
  const stream = c.captureStream(30);
  const track = stream.getVideoTracks()[0];
  const real = track.getSettings.bind(track);
  track.getSettings = () => ({ ...real(), facingMode: window.__facing });
  return stream;
};
"""

LEFT_PIXEL = """async () => {
  const img = document.querySelector('#camera-preview');
  await img.decode();
  const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
  const g = c.getContext('2d'); g.drawImage(img, 0, 0);
  const [r, , b] = g.getImageData(20, c.height / 2, 1, 1).data;
  return r > b ? 'red' : 'blue';
}"""


async def register(browser, name, mobile=False):
    opts = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True} if mobile else {}
    ctx = await browser.new_context(**opts)
    await ctx.add_init_script(STUB)
    p = await ctx.new_page()
    await p.goto(BASE)
    await p.click("#auth-toggle")
    await p.fill("input[name=username]", name)
    await p.fill("input[name=password]", "correct horse battery")
    await p.fill("input[name=invite_code]", INVITE)
    await p.click("#auth-submit")
    await expect(p.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(p)
    return p


async def capture(p, facing):
    await p.evaluate(f"window.__facing = {facing!r}")
    await p.click("#camera-button")
    await p.wait_for_timeout(500)
    mirrored = await p.evaluate("document.querySelector('#camera-video').classList.contains('mirrored')")
    await p.click("#shutter")
    await expect(p.locator("#camera-preview")).to_be_visible()
    left = await p.evaluate(LEFT_PIXEL)
    await shot(p, f"mirror-{facing}")
    await p.click("#retake")
    await p.click("#capture-controls [data-close]")
    return mirrored, left


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        a = await register(browser, f"mia_{tag}", mobile=True)
        b = await register(browser, f"leo_{tag}")
        await a.click("#friends-button")
        await a.fill("#add-friend-form input[name=username]", f"leo_{tag}")
        await a.click("#add-friend-form button[type=submit]")
        await expect(a.locator("#add-friend-note")).to_contain_text("Request sent")
        await a.click("#friends-dialog [data-close]")
        await b.click("#friends-button")
        await b.locator("#incoming-list button", has_text="Accept").click()
        await a.wait_for_timeout(500)
        await a.locator(".chat-item").first.click()

        front = await capture(a, "user")
        back = await capture(a, "environment")
        print("front camera: preview mirrored=%s, photo left edge=%s" % front)
        print("back camera:  preview mirrored=%s, photo left edge=%s" % back)
        assert front == (True, "blue"), front
        assert back == (False, "red"), back
        await browser.close()
    print("MIRROR TEST PASSED")


asyncio.run(main())
