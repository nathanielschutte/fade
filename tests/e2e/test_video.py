"""Short videos (X28): hold the shutter to record (a tap still takes a photo),
slide up to zoom while recording, stop at the server's limit, send to a
friend (format 4) or a group (format 5), and watch it once. The camera and
microphone are stubs: a canvas and a quiet tone. Settings come from the
environment; see common.py."""
import asyncio, json, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, no_placeholders, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
GROUP = f"Clips {tag}"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}
errors = []

# window.__noMic: the microphone is refused.
STUB = """
window.__noMic = false;
navigator.mediaDevices.getUserMedia = async (want) => {
  if (want.audio && !want.video) {
    if (window.__noMic) throw new DOMException('denied', 'NotAllowedError');
    const ctx = new AudioContext();
    const tone = ctx.createOscillator(); const out = ctx.createMediaStreamDestination();
    tone.connect(out); tone.start();
    return out.stream;
  }
  const c = document.createElement('canvas'); c.width = 720; c.height = 1280;
  const g = c.getContext('2d'); let n = 0;
  setInterval(() => { n++; g.fillStyle = n % 60 < 30 ? '#2b5' : '#25b'; g.fillRect(0, 0, 720, 1280); g.fillStyle = '#fff'; g.fillRect(260, 540, 200, 200); }, 33);
  const stream = c.captureStream(30);
  const track = stream.getVideoTracks()[0];
  const real = track.getSettings.bind(track);
  track.getSettings = () => ({ ...real(), facingMode: 'environment' });
  return stream;
};
"""


async def sign_up(browser, name, max_seconds=None):
    ctx = await browser.new_context(**PHONE)
    await ctx.add_init_script(STUB)
    page = await ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    if max_seconds:
        async def shorter(route):
            res = await route.fetch()
            config = await res.json()
            config["video_max_seconds"] = max_seconds
            await route.fulfill(response=res, body=json.dumps(config))
        await page.route("**/api/config", shorter)
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


async def hold_shutter(page, ms, slide_up=0):
    """Press the shutter, hold (sliding up partway through), and let go."""
    box = await page.locator("#shutter").bounding_box()
    x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
    await page.mouse.move(x, y)
    await page.mouse.down()
    await page.wait_for_timeout(ms // 2)
    if slide_up:
        for i in range(1, 6):
            await page.mouse.move(x, y - slide_up * i / 5)
            await page.wait_for_timeout(40)
    await page.wait_for_timeout(ms // 2)
    await page.mouse.up()


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, max_seconds=3)
        ben = await sign_up(browser, BEN)
        await befriend(ana, ben, BEN, ANA)

        # A tap still takes a photo.
        await row(ana, BEN).click()
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        await ana.click("#shutter")
        await expect(ana.locator("#camera-preview")).to_be_visible()
        await expect(ana.locator("#camera-preview-video")).to_be_hidden()
        await ana.click("#retake")

        # Hold to record; slide up to zoom in while recording.
        await hold_shutter(ana, 1600, slide_up=120)
        await expect(ana.locator("#camera-preview-video")).to_be_visible(timeout=10000)
        await expect(ana.locator("#camera-preview")).to_be_hidden()
        await expect(ana.locator("#draw-tools")).to_be_hidden()  # drawing is for photos
        await expect(ana.locator("#zoom-chip")).to_be_hidden()
        assert await ana.locator("#camera-preview-video").evaluate("v => !v.paused && v.loop"), "the preview plays, looping"
        await expect(ana.locator("#send-snap")).to_have_text(f"Send to {BEN}")
        await ana.fill("#snap-caption", "listen")
        await shot(ana, "video-preview-phone", full_page=False)
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).to_be_hidden(timeout=20000)
        await expect(ana.locator(".snap-chip.done", has_text="Video sent")).to_be_visible()
        print("hold records a video; a tap is still a photo")

        # Ben: a new video, watched once, with its caption, then gone.
        await expect(row(ben, ANA).locator(".chat-status")).to_have_text("New video", timeout=15000)
        await row(ben, ANA).click()
        await ben.locator("button.snap-chip", has_text="Tap to view video").click()
        await expect(ben.locator("#viewer-video")).to_be_visible(timeout=15000)
        await expect(ben.locator("#viewer-caption")).to_have_text("listen")
        assert await ben.locator("#viewer-video").evaluate("v => !v.paused"), "it plays"
        await shot(ben, "video-viewer-phone", full_page=False)
        await expect(ben.locator("#viewer")).to_be_hidden(timeout=15000)  # closes when it ends
        await expect(ben.locator(".snap-chip.done", has_text="Viewed")).to_be_visible()
        await expect(ana.locator(".snap-chip.done", has_text="Opened")).to_be_visible(timeout=10000)
        await no_placeholders(ben)
        print("the friend watches it once; the sender sees it opened")

        # Recording stops at the limit (3 seconds here) even while still held.
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        box = await ana.locator("#shutter").bounding_box()
        await ana.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        await ana.mouse.down()
        await expect(ana.locator("#record-time")).to_be_visible(timeout=5000)
        await shot(ana, "video-recording-phone", full_page=False)
        await expect(ana.locator("#camera-preview-video")).to_be_visible(timeout=8000)
        await ana.mouse.up()
        await ana.click("#retake")

        # No microphone: it records anyway, without sound, and says so.
        await ana.evaluate("window.__noMic = true")
        await ana.click("#capture-controls [data-close]")
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        await hold_shutter(ana, 1200)
        await expect(ana.locator("#camera-preview-video")).to_be_visible(timeout=10000)
        await expect(ana.locator("#camera-message")).to_have_text("This video has no sound: napsack can't use the microphone.")
        await ana.click("#retake")
        await ana.click("#capture-controls [data-close]")
        await ana.evaluate("window.__noMic = false")
        print("stops at the limit; works without a microphone")

        # A group video (format 5), from the camera tab.
        await ben.click("#back-button")
        await ben.click("#start-button")
        await ben.fill("#new-group-name", GROUP)
        await ben.locator("#new-group-friends label", has_text=ANA).locator("input").check()
        await ben.click("#new-group-submit")
        await expect(ben.locator("#chat-title")).to_have_text(GROUP)
        await ana.click("#back-button")
        await expect(row(ana, GROUP)).to_be_visible(timeout=15000)
        await ana.click("#tab-camera")
        await ana.wait_for_timeout(500)
        await hold_shutter(ana, 1200)
        await expect(ana.locator("#send-snap")).to_have_text("Send to…", timeout=10000)
        await ana.click("#send-snap")
        await ana.locator("#send-to-list label", has_text=GROUP).locator("input").check()
        await ana.click("#send-to-go")
        await expect(ana.locator("#toast-text")).to_have_text(f"Video sent to {GROUP}.", timeout=20000)
        await expect(ben.locator("button.snap-chip", has_text="Tap to view video")).to_be_visible(timeout=15000)
        await ben.locator("button.snap-chip", has_text="Tap to view video").click()
        await expect(ben.locator("#viewer-video")).to_be_visible(timeout=15000)
        await expect(ben.locator("#viewer")).to_be_hidden(timeout=15000)
        await expect(ben.locator(".snap-chip.done", has_text="Viewed")).to_be_visible()
        print("group videos are sealed and watched once too")

        assert not errors, errors
        await browser.close()
    print("VIDEO TEST PASSED")


asyncio.run(main())
