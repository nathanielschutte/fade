"""What you see is what they see (X52, X53; docs/implementation/pic-framing.md).
A photo from the library zooms (Ctrl + the wheel on a computer, a pinch on a
phone) and moves, and what's sent is the part on screen, with the drawing
still on the same place of the photo. A caption is a strip across the
picture, sized by its width, the same while it's written and in the friend's
viewer, at most five lines. Texts of only one to four emoji show large,
without the rule beside them (which emoji count is a Node check:
shared/crypto/emoji-only.test.js). Settings come from the environment; see
common.py."""
import asyncio, re, uuid
from playwright.async_api import async_playwright, expect

from common import launch, shot, PHONE, befriend, row, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
errors = []

# A wide photo from "files": red on the left half, blue on the right.
PICK_WIDE = """async () => {
  const c = document.createElement('canvas'); c.width = 1600; c.height = 800;
  const g = c.getContext('2d'); g.fillStyle = '#d02020'; g.fillRect(0, 0, 800, 800);
  g.fillStyle = '#2040d0'; g.fillRect(800, 0, 800, 800);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'wide.png', { type: 'image/png' }));
  const input = document.querySelector('#file-input'); input.files = dt.files; input.dispatchEvent(new Event('change'));
}"""

# On screen: the whole photo (the sticker layer covers it) and the part of it
# on the stage (the drawing canvas covers just that), with the photo's size.
FRAMING = """() => {
  const st = document.querySelector('.camera-stage').getBoundingClientRect();
  const box = (sel) => { const s = document.querySelector(sel).style;
    return { left: st.left + parseFloat(s.left), top: st.top + parseFloat(s.top), width: parseFloat(s.width), height: parseFloat(s.height) }; };
  const img = document.querySelector('#camera-preview');
  return { photo: box('#sticker-layer'), visible: box('#draw-layer'), nw: img.naturalWidth, nh: img.naturalHeight };
}"""

# A two-finger pinch on the photo, spreading from `start` to `end` px either side of (x, y).
PINCH = """([x, y, start, end]) => {
  const img = document.querySelector('#camera-preview');
  const ev = (type, id, dx) => img.dispatchEvent(new PointerEvent(type, { pointerId: id, pointerType: 'touch',
    isPrimary: id === 1, clientX: x + dx, clientY: y, bubbles: true, cancelable: true }));
  ev('pointerdown', 1, -start); ev('pointerdown', 2, start);
  for (let i = 1; i <= 10; i++) { const d = start + (end - start) * i / 10; ev('pointermove', 1, -d); ev('pointermove', 2, d); }
  ev('pointerup', 1, -end); ev('pointerup', 2, end);
}"""

# The picture as the viewer shows it (letterboxed in its box), and the caption's strip.
VIEWER = """() => {
  const img = document.querySelector('#viewer-image'), b = img.getBoundingClientRect();
  const s = Math.min(b.width / img.naturalWidth, b.height / img.naturalHeight);
  const pic = { left: b.left + (b.width - img.naturalWidth * s) / 2, top: b.top + (b.height - img.naturalHeight * s) / 2,
    width: img.naturalWidth * s, height: img.naturalHeight * s };
  const cap = document.querySelector('#viewer-caption'), c = cap.getBoundingClientRect();
  return { pic, nw: img.naturalWidth, nh: img.naturalHeight, cap: { left: c.left, width: c.width, top: c.top, bottom: c.bottom, middle: c.top + c.height / 2 },
    font: parseFloat(getComputedStyle(cap).fontSize), screen: [innerWidth, innerHeight] };
}"""

# The pixel at (fx, fy) of the photo the viewer shows, as [r, g, b].
PIXEL = """([fx, fy]) => {
  const img = document.querySelector('#viewer-image');
  const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
  const x = c.getContext('2d'); x.drawImage(img, 0, 0);
  return [...x.getImageData(Math.round(fx * c.width), Math.round(fy * c.height), 1, 1).data.slice(0, 3)];
}"""

# The caption being written: its strip, size, lines, and words.
WRITING = """() => {
  const box = document.querySelector('#snap-caption-box').getBoundingClientRect();
  const t = document.querySelector('#snap-caption'), css = getComputedStyle(t);
  const font = parseFloat(css.fontSize);
  return { left: box.left, width: box.width, top: box.top, bottom: box.bottom, middle: box.top + box.height / 2, font, value: t.value,
    lines: Math.round((t.clientHeight - parseFloat(css.paddingTop) - parseFloat(css.paddingBottom)) / (font * 1.25)) };
}"""


def expected_size(f):
    """The part of the photo on screen, in its pixels, at most 1280 on its longest side."""
    w = f["visible"]["width"] / f["photo"]["width"] * f["nw"]
    h = f["visible"]["height"] / f["photo"]["height"] * f["nh"]
    k = min(1, 1280 / max(w, h))
    return w * k, h * k


def near(a, b, tol):
    return abs(a - b) <= tol


async def check_viewer(page, sent):
    """The friend's viewer: the photo that was on screen, its caption a strip across it where it was put."""
    await expect(page.locator("#viewer-caption")).to_have_text(sent["caption"], timeout=15000)
    await expect(page.locator("#viewer")).to_have_class(re.compile(r"\brunning\b"))
    v = await page.evaluate(VIEWER)
    w, h = sent["size"]
    assert near(v["nw"], w, 2) and near(v["nh"], h, 2), (v, sent)
    pic, cap = v["pic"], v["cap"]
    # As large as it fits (a small crop is enlarged), and all of it on screen
    # (a pic taller than a computer's screen used to run off it).
    sw, sh = v["screen"]
    assert pic["top"] >= -1 and pic["top"] + pic["height"] <= sh + 1 and pic["width"] <= sw + 1, v
    assert near(pic["width"], sw, 1) or near(pic["height"], sh, 1), v
    assert near(cap["left"], pic["left"], 1) and near(cap["width"], pic["width"], 1), v
    assert near(v["font"], 0.044 * pic["width"], 0.2), v
    assert near(cap["middle"], pic["top"] + sent["y"] * pic["height"], 2), (v, sent)
    assert cap["top"] >= pic["top"] - 1 and cap["bottom"] <= pic["top"] + pic["height"] + 1, v  # inside the picture
    return v


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors)  # a computer
        ben = await sign_up(browser, BEN, errors=errors, **PHONE)
        await befriend(ana, ben, BEN, ANA)

        # Texts of only emoji: one large, two to four a little smaller, no rule beside them; five, or words, as usual.
        await row(ana, BEN).click()
        for text in ["😂", "🍕🍣🌮", "🎉🎉🎉🎉🎉", "see you at 7 👍"]:
            await ana.fill("#composer-input", text)
            await ana.press("#composer-input", "Enter")
        for page in (ana, ben):
            if page is ben:
                await row(ben, ANA).click()
            one, three, five, words = (page.locator("li.msg", has_text=t).last for t in ["😂", "🍕🍣🌮", "🎉🎉🎉🎉🎉", "see you at 7"])
            await expect(one.locator(".msg-body")).to_have_css("font-size", "48px", timeout=15000)
            await expect(three.locator(".msg-body")).to_have_css("font-size", "36px")
            for big in (one, three):
                await expect(big).to_have_css("border-left-color", "rgba(0, 0, 0, 0)")
            for usual in (five, words):
                await expect(usual.locator(".msg-body")).to_have_css("font-size", "16px")
                await expect(usual).not_to_have_css("border-left-color", "rgba(0, 0, 0, 0)")
        await shot(ana, "emoji-texts-desktop", full_page=False)
        await shot(ben, "emoji-texts-phone", full_page=False)
        print("texts of one to four emoji are large, without the rule; five, or words, as usual")

        # Ana picks a wide photo and zooms in with Ctrl and the wheel, about the middle...
        await ana.click("#camera-button")
        await ana.evaluate(PICK_WIDE)
        await expect(ana.locator("#draw-tools")).to_be_visible(timeout=10000)
        stage = await ana.locator(".camera-stage").bounding_box()
        cx, cy = stage["x"] + stage["width"] / 2, stage["y"] + stage["height"] / 2
        whole = await ana.evaluate(FRAMING)
        assert whole["visible"] == whole["photo"], whole  # shown whole to start with
        await ana.mouse.move(cx, cy)
        await ana.keyboard.down("Control")
        for _ in range(3):
            await ana.mouse.wheel(0, -30)
        await ana.keyboard.up("Control")
        await expect(ana.locator("#camera-preview")).to_have_css("transform", re.compile(r"^matrix\(2\.4"))
        # ...then drags it left: the photo moves, and a drag doesn't start a caption.
        await ana.mouse.move(cx, cy)
        await ana.mouse.down()
        for i in range(1, 11):
            await ana.mouse.move(cx - 15 * i, cy)
        await ana.mouse.up()
        await expect(ana.locator("#snap-caption-box")).to_be_hidden()
        framed = await ana.evaluate(FRAMING)
        assert near(framed["photo"]["left"] + framed["photo"]["width"] / 2, cx - 150, 1), framed
        assert framed["visible"]["width"] == stage["width"], framed  # wider than the stage now: no gaps at the sides
        # A yellow line across the middle of what's on screen: it stays on the photo.
        await ana.click("#draw-pen")
        await ana.click("#draw-colors .swatch[aria-label='Color #ffd23f']")
        await ana.click("#draw-size")
        vis = framed["visible"]
        y_mid = vis["top"] + vis["height"] / 2
        await ana.mouse.move(vis["left"] + vis["width"] * 0.6, y_mid)
        await ana.mouse.down()
        for i in range(1, 11):
            await ana.mouse.move(vis["left"] + vis["width"] * (0.6 + 0.03 * i), y_mid)
        await ana.mouse.up()
        await ana.click("#draw-pen")  # pen away: a tap is a caption's again

        # A caption: a strip across what's on screen, its text sized by that width.
        await ana.mouse.click(vis["left"] + 200, vis["top"] + vis["height"] * 0.3)
        await expect(ana.locator("#snap-caption")).to_be_focused()
        wr = await ana.evaluate(WRITING)
        assert near(wr["left"], vis["left"], 1) and near(wr["width"], vis["width"], 1), (wr, vis)
        assert near(wr["font"], 0.044 * vis["width"], 0.2), (wr, vis)
        assert near(wr["middle"], vis["top"] + vis["height"] * 0.3, 2), (wr, vis)
        # Five lines at most: what would make a sixth is refused.
        typed = "MMMM " * 40
        await ana.locator("#snap-caption").press_sequentially(typed)
        wr = await ana.evaluate(WRITING)
        # (Spaces at a line's end don't start the next one, so those still go in.)
        assert wr["lines"] == 5 and wr["value"].count("M") < typed.count("M"), wr
        # Too tall to sit there, it's kept inside the picture.
        assert near(wr["top"], vis["top"], 1) and wr["bottom"] <= vis["top"] + vis["height"] + 1, (wr, vis)
        await ana.locator("#snap-caption").press_sequentially("MMMM")
        assert (await ana.evaluate(WRITING))["value"] == wr["value"], "a sixth line is refused"
        await shot(ana, "caption-five-lines-desktop", full_page=False)
        # No line breaks: pasted ones become spaces.
        await ana.fill("#snap-caption", "a wide\nview")
        await expect(ana.locator("#snap-caption")).to_have_value("a wide view")
        await expect(ana.locator("#snap-caption-count")).to_be_hidden()
        await shot(ana, "camera-zoomed-writing-desktop", full_page=False)
        await ana.press("#snap-caption", "Enter")
        await expect(ana.locator("#snap-caption")).not_to_be_focused()
        wr = await ana.evaluate(WRITING)
        assert near(wr["width"], vis["width"], 1), wr  # placed, the same strip
        await shot(ana, "camera-zoomed-placed-desktop", full_page=False)
        # Where the boundary between red and blue falls in what's sent.
        f = framed
        x0 = (f["visible"]["left"] - f["photo"]["left"]) / f["photo"]["width"]
        edge = (0.5 - x0) / (f["visible"]["width"] / f["photo"]["width"])
        sent = {"caption": "a wide view", "size": expected_size(f), "y": (wr["middle"] - vis["top"]) / vis["height"]}
        assert 0.2 < edge < 0.6, edge
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).not_to_be_visible(timeout=15000)
        print("zoomed with Ctrl and the wheel, dragged, drew, captioned at five lines at most, sent")

        # Ben gets the part Ana had on screen, the line where she drew it, and the caption where she put it.
        await ben.locator("#messages .snap-chip", has_text="Tap to view pic").click(timeout=15000)
        await check_viewer(ben, sent)
        for fx, want in [(edge - 0.06, "red"), (edge + 0.06, "blue"), (0.72, "yellow")]:
            r, g, b = await ben.evaluate(PIXEL, [fx, 0.5 if want == "yellow" else 0.85])
            got = "yellow" if r > 180 and g > 150 and b < 120 else "red" if r > 150 and g < 100 and b < 100 else "blue" if b > 150 and r < 100 else (r, g, b)
            assert got == want, (fx, want, got)
        await shot(ben, "viewer-phone", full_page=False)
        await ben.keyboard.press("Escape")
        await expect(ben.locator("#viewer")).to_be_hidden()
        print("the friend sees what was on screen: the crop, the drawing on it, the caption across it")

        # On a phone, a pinch zooms; Retake starts again from the whole photo.
        await ben.click("#camera-button")
        await ben.evaluate(PICK_WIDE)
        await expect(ben.locator("#draw-tools")).to_be_visible(timeout=10000)
        box = await ben.locator(".camera-stage").bounding_box()
        mid = [box["x"] + box["width"] / 2, box["y"] + box["height"] / 2]
        await ben.evaluate(PINCH, [*mid, 40, 80])
        await expect(ben.locator("#camera-preview")).to_have_css("transform", re.compile(r"^matrix\(2, 0, 0, 2,"))
        await ben.tap("#retake")
        await ben.evaluate(PICK_WIDE)
        await expect(ben.locator("#draw-tools")).to_be_visible(timeout=10000)
        await expect(ben.locator("#camera-preview")).to_have_css("transform", "none")
        # A little zoom: still wide and short. A five-line caption put near its
        # top is kept inside it, while it's written, placed, and for Ana.
        await ben.evaluate(PINCH, [*mid, 40, 48])
        await expect(ben.locator("#camera-preview")).to_have_css("transform", re.compile(r"^matrix\(1\.2, 0, 0, 1\.2,"))
        framed = await ben.evaluate(FRAMING)
        vis = framed["visible"]
        assert near(vis["width"], box["width"], 1) and vis["height"] < box["width"] * 0.7, framed
        await ben.tap(".camera-stage", position={"x": box["width"] / 2, "y": vis["top"] - box["y"] + vis["height"] * 0.1})
        await expect(ben.locator("#snap-caption")).to_be_focused()
        await ben.locator("#snap-caption").press_sequentially("MMMM " * 30)
        wr = await ben.evaluate(WRITING)
        assert wr["lines"] == 5, wr
        assert near(wr["width"], vis["width"], 1) and near(wr["font"], 0.044 * vis["width"], 0.2), (wr, vis)
        assert near(wr["top"], vis["top"], 1) and wr["bottom"] <= vis["top"] + vis["height"] + 1, (wr, vis)
        await shot(ben, "camera-zoomed-writing-phone", full_page=False)
        await ben.press("#snap-caption", "Enter")
        await expect(ben.locator("#snap-caption")).not_to_be_focused()
        wr = await ben.evaluate(WRITING)
        assert near(wr["top"], vis["top"], 1), (wr, vis)
        await shot(ben, "camera-zoomed-placed-phone", full_page=False)
        sent = {"caption": wr["value"].strip(), "size": expected_size(framed), "y": (wr["middle"] - vis["top"]) / vis["height"]}
        await ben.tap("#send-snap")
        await expect(ben.locator("#camera-dialog")).not_to_be_visible(timeout=15000)

        # Ana, on a computer, sees it as Ben framed it.
        await ana.locator("#messages .snap-chip", has_text="Tap to view pic").click(timeout=15000)
        await check_viewer(ana, sent)
        await shot(ana, "viewer-desktop", full_page=False)
        await ana.keyboard.press("Escape")
        print("a pinch zooms on a phone, Retake resets it, and a computer shows the same framing")

        assert not errors, errors
        await browser.close()
    print("PIC FRAMING TEST PASSED")


asyncio.run(main())
