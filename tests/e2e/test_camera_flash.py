"""Camera flash (X50): a button only where the camera has a light the browser
can turn on (`torch`: Chrome on Android, for a back camera). Off whenever the
camera opens; on, it's lit while taking pics and goes off over what was
taken, on switching to a camera without one, and with the camera. Headless
Chromium's cameras have no light, so the first part uses the real one; the
rest a stub whose back camera says it has one and records what it's asked.
Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import launch, shot, PHONE, sign_up

tag = uuid.uuid4().hex[:5]
ANA = f"flash_{tag}"
errors = []

# A camera stub: the back one ("environment") has a torch, the front one none.
# window.__torch: every torch setting it was asked for; window.__lit: the last.
STUB = """
window.__torch = [];
window.__lit = false;
navigator.mediaDevices.getUserMedia = async (want) => {
  const back = want?.video?.facingMode === 'environment';
  const c = document.createElement('canvas'); c.width = 640; c.height = 480;
  const g = c.getContext('2d');
  setInterval(() => { g.fillStyle = back ? '#246' : '#642'; g.fillRect(0, 0, 640, 480); }, 30);
  const stream = c.captureStream(30);
  const track = stream.getVideoTracks()[0];
  const real = track.getSettings.bind(track);
  track.getSettings = () => ({ ...real(), facingMode: back ? 'environment' : 'user' });
  track.getCapabilities = () => (back ? { torch: true } : {});
  track.applyConstraints = async (c) => {
    const t = c?.advanced?.[0]?.torch;
    if (typeof t === 'boolean') { window.__torch.push(t); window.__lit = t; }
  };
  const stop = track.stop.bind(track);
  track.stop = () => { if (back) window.__lit = false; stop(); }; // a stopped camera's light is off
  return stream;
};
"""


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw, args=["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"])

        # The browser's own (fake) camera has no light: no button.
        plain = await sign_up(browser, f"{ANA}_p", errors=errors, label="plain", permissions=["camera"], **PHONE)
        await plain.click("#tab-camera")
        await expect(plain.locator("#zoom-chip")).to_be_visible(timeout=10000)  # the camera is running
        await expect(plain.locator("#torch")).to_be_hidden()
        await plain.click("#capture-controls [data-close]")
        print("no light on the camera: no flash button")

        ana = await sign_up(browser, ANA, errors=errors, label="ana", init=STUB, **PHONE)
        torch = ana.locator("#torch")
        lit = lambda: ana.evaluate("window.__lit")  # noqa: E731

        # The front camera (where it starts) has no light; the back one does.
        await ana.click("#tab-camera")
        await expect(ana.locator("#zoom-chip")).to_be_visible(timeout=10000)
        await expect(torch).to_be_hidden()
        await ana.click("#flip-camera")
        await expect(torch).to_be_visible(timeout=10000)
        await expect(torch).to_have_attribute("aria-pressed", "false")
        assert not await lit()
        await shot(ana, "flash-off-phone", full_page=False)

        # On: lit. Over the photo taken: dark, and no button. Retake: lit again.
        await torch.click()
        await expect(torch).to_have_attribute("aria-pressed", "true")
        await expect(torch).to_have_attribute("aria-label", "Flash on. Tap to turn it off")
        await ana.wait_for_function("() => window.__lit === true")
        await shot(ana, "flash-on-phone", full_page=False)
        await ana.wait_for_timeout(200)  # a frame in the preview to take
        await ana.click("#shutter")
        await expect(ana.locator("#camera-preview")).to_be_visible(timeout=10000)
        await expect(torch).to_be_hidden()
        await ana.wait_for_function("() => window.__lit === false")
        await ana.click("#retake")
        await expect(torch).to_be_visible()
        await ana.wait_for_function("() => window.__lit === true")
        print("on: lit while taking pics, dark over the one taken")

        # To the front camera: no light there, so no button and nothing lit.
        await ana.click("#flip-camera")
        await expect(torch).to_be_hidden(timeout=10000)
        await ana.wait_for_function("() => window.__lit === false")
        await ana.click("#flip-camera")
        await expect(torch).to_be_visible(timeout=10000)
        await ana.wait_for_function("() => window.__lit === true")  # still on, for this camera
        print("switching cameras checks again for a light")

        # Closing the camera puts it out, and the next time it starts off.
        await ana.click("#capture-controls [data-close]")
        await ana.wait_for_function("() => window.__lit === false")
        await ana.click("#tab-camera")
        await expect(torch).to_be_visible(timeout=10000)  # (the back camera, as last used)
        await expect(torch).to_have_attribute("aria-pressed", "false")
        assert not await lit()
        await torch.click()
        await ana.wait_for_function("() => window.__lit === true")
        await torch.click()
        await ana.wait_for_function("() => window.__lit === false")
        await ana.click("#capture-controls [data-close]")
        print("off when the camera closes, and when it next opens")

        assert not errors, errors
        await browser.close()
    print("FLASH TEST PASSED")


asyncio.run(main())
