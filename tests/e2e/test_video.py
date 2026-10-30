"""Short videos (X28): hold the shutter to record (a tap still takes a photo),
slide up to zoom while recording, stop at the server's limit, send to a
friend (format 4) or a group (format 5), and watch it once. The camera and
microphone are stubs: a canvas and a quiet tone. Settings come from the
environment; see common.py."""
import asyncio, json, re, uuid
from playwright.async_api import async_playwright, expect

from common import launch, no_placeholders, open_page, shot, PHONE, befriend, row, sign_in, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
GROUP = f"Clips {tag}"
errors = []

# window.__noMic: the microphone is refused.
STUB = """
window.__noMic = false;
window.__cameras = [];  // the facing each camera request asked for
navigator.mediaDevices.getUserMedia = async (want) => {
  if (want.audio && !want.video) {
    if (window.__noMic) throw new DOMException('denied', 'NotAllowedError');
    const ctx = new AudioContext();
    const tone = ctx.createOscillator(); const out = ctx.createMediaStreamDestination();
    tone.connect(out); tone.start();
    return out.stream;
  }
  window.__cameras.push(want.video.facingMode);
  const c = document.createElement('canvas'); c.width = 720; c.height = 1280;
  const g = c.getContext('2d'); let n = 0;
  setInterval(() => { n++; g.fillStyle = n % 60 < 30 ? '#2b5' : '#25b'; g.fillRect(0, 0, 720, 1280); g.fillStyle = '#fff'; g.fillRect(260, 540, 200, 200); }, 33);
  const stream = c.captureStream(30);
  const track = stream.getVideoTracks()[0];
  const real = track.getSettings.bind(track);
  track.getSettings = () => ({ ...real(), facingMode: 'environment' });
  return stream;
};
// How many recorders were made, and what each asked for; window.__stuckRecorder: stop() never fires "stop".
window.__recorders = 0;
window.__recorderOptions = [];
window.__stuckRecorder = false;
if (window.MediaRecorder) {
  const Real = window.MediaRecorder;
  window.MediaRecorder = class extends Real {
    constructor(...args) { super(...args); window.__recorders++; window.__recorderOptions.push(args[1]); }
    stop() { if (!window.__stuckRecorder) super.stop(); }
  };
}
"""


async def three_second_videos(page):
    """The server's config says videos stop at 3 seconds, so the limit comes quickly."""
    async def shorter(route):
        res = await route.fetch()
        config = await res.json()
        config["video_max_seconds"] = 3
        await route.fulfill(response=res, body=json.dumps(config))
    await page.route("**/api/config", shorter)


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
        browser = await launch(pw, chrome=True)  # Chrome's codecs: recorded videos' sound
        ana = await sign_up(browser, ANA, errors=errors, init=STUB, prepare=three_second_videos, **PHONE)
        ben = await sign_up(browser, BEN, errors=errors, init=STUB, **PHONE)
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
        # Retake: the next one starts at 1× again, not where this one was zoomed to.
        await ana.click("#retake")
        await expect(ana.locator("#zoom-chip")).to_have_text("1×")
        await hold_shutter(ana, 1600)
        await expect(ana.locator("#camera-preview-video")).to_be_visible(timeout=10000)
        assert await ana.locator("#camera-preview-video").evaluate("v => !v.paused && v.loop"), "the preview plays, looping"
        await expect(ana.locator("#send-who")).to_have_text(f"To {BEN} +")
        await ana.locator(".camera-stage").click(position={"x": 195, "y": 300})  # a tap on the picture places a caption
        await ana.fill("#snap-caption", "listen")
        await shot(ana, "video-preview-phone", full_page=False)
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).to_be_hidden(timeout=20000)
        await expect(ana.locator(".snap-chip.done", has_text="Video sent")).to_be_visible()
        print("hold records a video; a tap is still a photo")

        # F20: H.264 High where the browser makes it, at the bitrate the
        # server's cap allows (6 MB over 3 seconds here: the 3 Mbit/s ceiling).
        asked = await ana.evaluate("() => window.__recorderOptions[0]")
        high = await ana.evaluate("() => MediaRecorder.isTypeSupported('video/mp4;codecs=avc1.64001F,mp4a.40.2')")
        assert asked["videoBitsPerSecond"] == 3_000_000, asked
        assert not high or asked["mimeType"] == "video/mp4;codecs=avc1.64001F,mp4a.40.2", asked
        print(f"recorded as {asked['mimeType']} at {asked['videoBitsPerSecond']} bit/s")

        # A quick tap the page was too busy to handle before the hold timer ran
        # (D11): still a photo, by when the finger came up, not when it was handled.
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        await ana.evaluate("""async () => {
          const shutter = document.querySelector('#shutter');
          const at = { pointerId: 7, bubbles: true, isPrimary: true, pointerType: 'touch' };
          shutter.dispatchEvent(new PointerEvent('pointerdown', at));
          const up = new PointerEvent('pointerup', at);  // let go at once...
          await new Promise((r) => setTimeout(r, 700));  // ...but handled only after the hold timer ran
          shutter.dispatchEvent(up);
          shutter.click();
        }""")
        await expect(ana.locator("#camera-preview")).to_be_visible(timeout=10000)
        await expect(ana.locator("#camera-preview-video")).to_be_hidden()
        await ana.click("#retake")
        await ana.click("#capture-controls [data-close]")
        print("a quick tap handled late is still a photo")

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

        # Sound off (X37): what's sent has no sound at all, not just a quiet player.
        # Waits for what it checks, never a fixed time: on a busy machine audio
        # can start decoding well after the picture (it failed CI that way). What
        # the player reports is kept as it plays, since the viewer resets it at the end.
        WATCH = """() => {
          window.__played = 0; window.__audio = 0;
          const v = document.querySelector('#viewer-video');
          v.ontimeupdate = () => {
            window.__played = Math.max(window.__played, v.currentTime);
            window.__audio = Math.max(window.__audio, v.webkitAudioDecodedByteCount || 0);
          };
        }"""
        async def no_sound_after_a_second(page):
            await page.wait_for_function("() => window.__played >= 1", timeout=20000)
            return await page.evaluate("window.__audio") == 0
        async def some_sound(page):
            await page.wait_for_function("() => window.__audio > 0", timeout=20000)
            return True
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        await hold_shutter(ana, 1600)
        await expect(ana.locator("#video-sound")).to_be_visible(timeout=10000)
        await expect(ana.locator("#video-sound")).to_have_attribute("aria-pressed", "false")
        await ana.click("#video-sound")
        await expect(ana.locator("#video-sound")).to_have_attribute("aria-pressed", "true")
        assert await ana.locator("#camera-preview-video").evaluate("v => v.muted")
        await shot(ana, "video-muted-phone", full_page=False)
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).to_be_hidden(timeout=20000)
        await ben.evaluate(WATCH)
        await ben.locator("button.snap-chip", has_text="Tap to view video").click()
        assert await no_sound_after_a_second(ben), "a muted video carries no sound"
        await expect(ben.locator("#viewer")).to_be_hidden(timeout=15000)
        # With sound, it has some.
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        await hold_shutter(ana, 1600)
        await expect(ana.locator("#video-sound")).to_be_visible(timeout=10000)
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).to_be_hidden(timeout=20000)
        await ben.evaluate(WATCH)
        await ben.locator("button.snap-chip", has_text="Tap to view video").click()
        assert await some_sound(ben), "with sound, there's sound"
        await expect(ben.locator("#viewer")).to_be_hidden(timeout=15000)
        print("sound off sends a video without any; the ring fills; double tap switches cameras mid-video")

        # Recording stops at the limit (3 seconds here) even while still held.
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        box = await ana.locator("#shutter").bounding_box()
        await ana.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        await ana.mouse.down()
        await expect(ana.locator("#record-time")).to_be_visible(timeout=5000)
        await ana.wait_for_timeout(800)
        # The ring is an SVG stroke, filling as the time runs out (X37).
        offset = await ana.locator(".shutter-ring .ring-fill").evaluate("c => getComputedStyle(c).strokeDashoffset")
        left = float(re.search(r"[\d.]+", offset).group())  # e.g. "calc(73.2px)": three quarters to go
        assert 0 < left < 100, offset
        await shot(ana, "video-recording-phone", full_page=False)
        # Another finger double-taps the picture: the other camera, still recording (X37).
        asked = await ana.evaluate("window.__cameras.length")
        was = await ana.evaluate("window.__cameras.at(-1)")
        await ana.evaluate("""() => {
          const stage = document.querySelector('.camera-stage'), r = stage.getBoundingClientRect();
          const at = { bubbles: true, clientX: r.left + r.width / 2, clientY: r.top + 100, detail: 1 };
          stage.dispatchEvent(new MouseEvent('click', at));
          stage.dispatchEvent(new MouseEvent('click', at));
        }""")
        await ana.wait_for_function("(n) => window.__cameras.length > n", arg=asked)
        assert await ana.evaluate("window.__cameras.at(-1)") != was, "switched to the other camera"
        await expect(ana.locator("#record-time")).to_be_visible()  # still recording
        await expect(ana.locator("#camera-preview-video")).to_be_visible(timeout=8000)
        await ana.mouse.up()
        await ana.evaluate("document.querySelector('#flip-camera').click()")  # and back again
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

        # A recorder that never says it stopped (seen on iPhones): the camera
        # doesn't stay stuck; the video finishes with what was recorded.
        await ana.click("#tab-chats")
        await row(ana, BEN).click()
        await ana.evaluate("window.__stuckRecorder = true")
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        await hold_shutter(ana, 1600)
        await expect(ana.locator("#camera-preview-video")).to_be_visible(timeout=10000)
        await expect(ana.locator("#shutter")).not_to_have_class(re.compile(r"\brecording\b"))
        await ana.click("#retake")
        await ana.click("#capture-controls [data-close]")
        await ana.evaluate("window.__stuckRecorder = false")
        print("a recorder that never stops doesn't leave the camera stuck")

        # On an iPhone (every browser there is WebKit): one recorder only, so no silent copy.
        phone = await open_page(browser, errors=errors, init=STUB, permissions=["camera", "microphone"],
                                user_agent="Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                                **PHONE)
        await sign_in(phone, ANA)
        await row(phone, BEN).click()
        await phone.click("#camera-button")
        await phone.wait_for_timeout(500)
        await hold_shutter(phone, 1600)
        await expect(phone.locator("#camera-preview-video")).to_be_visible(timeout=10000)
        assert await phone.evaluate("window.__recorders") == 1, await phone.evaluate("window.__recorders")
        await expect(phone.locator("#video-sound")).to_be_hidden()
        await phone.context.close()
        print("on an iPhone, one recorder: videos without the silent copy")

        assert not errors, errors
        await browser.close()
    print("VIDEO TEST PASSED")


asyncio.run(main())
