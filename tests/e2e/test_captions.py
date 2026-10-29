"""Captions anywhere on a pic (X33), and adding people from inside a chat
(X34). Tap the picture where the caption goes and type; Enter, or a tap
elsewhere, finishes typing without sending; drag the caption to move it. Its
place travels with the pic, sealed in (format 6), and the friend sees it
there. From a chat, "+ Add" beside Send opens Send to... with that chat
ticked. Settings come from the environment; see common.py."""
import asyncio, os, sqlite3, uuid
from playwright.async_api import async_playwright, expect

from common import DB, launch, shot, PHONE, befriend, row, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
errors = []

PICK_IMAGE = """async () => {
  const c = document.createElement('canvas'); c.width = 900; c.height = 1200;
  const g = c.getContext('2d'); g.fillStyle = '#2b5'; g.fillRect(0, 0, 900, 1200);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'pic.png', { type: 'image/png' }));
  const input = document.querySelector('#file-input'); input.files = dt.files; input.dispatchEvent(new Event('change'));
}"""

# Where the caption sits on the picture as drawn: 0 at its top, 1 at its bottom.
CAPTION_AT = """([caption, media]) => {
  const c = document.querySelector(caption).getBoundingClientRect();
  const m = document.querySelector(media);
  const box = m.getBoundingClientRect();
  const w = m.naturalWidth || m.videoWidth, h = m.naturalHeight || m.videoHeight;
  const scale = Math.min(box.width / w, box.height / h);
  const top = box.top + (box.height - h * scale) / 2;
  return (c.top + c.height / 2 - top) / (h * scale);
}"""


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana, ben, cal = [await sign_up(browser, n, errors=errors, **PHONE) for n in (ANA, BEN, CAL)]
        await befriend(ana, ben, BEN, ANA)
        await befriend(ana, cal, CAL, ANA)
        await row(ana, BEN).click()
        await ana.click("#camera-button")
        await ana.evaluate(PICK_IMAGE)
        await expect(ana.locator("#send-snap")).to_have_text("Send", timeout=10000)
        await expect(ana.locator("#send-who")).to_have_text(f"To {BEN} +")  # who it's going to
        await expect(ana.locator("#caption-hint")).to_have_text("Tap the picture to add a caption")
        await expect(ana.locator("#snap-caption-box")).to_be_hidden()

        # A tap on the picture puts the caption there, ready to type.
        stage = await ana.locator(".camera-stage").bounding_box()
        await ana.mouse.click(stage["x"] + 200, stage["y"] + 300)  # inside the picture, clear of its edges
        await expect(ana.locator("#snap-caption-box")).to_be_visible()
        await expect(ana.locator("#snap-caption")).to_be_focused()
        await expect(ana.locator("#caption-hint")).to_be_hidden()
        box = await ana.locator("#snap-caption-box").bounding_box()
        assert abs(box["y"] + box["height"] / 2 - (stage["y"] + 300)) < 6, (box, stage)
        await ana.locator("#snap-caption").press_sequentially("up top")
        # Enter finishes typing; it doesn't send.
        await ana.press("#snap-caption", "Enter")
        await expect(ana.locator("#snap-caption")).not_to_be_focused()
        await expect(ana.locator("#camera-dialog")).to_be_visible()
        await expect(ana.locator("#snap-caption")).to_have_value("up top")
        # Another tap on the picture doesn't move it (there's one caption)...
        await ana.mouse.click(stage["x"] + 200, stage["y"] + 420)
        await ana.wait_for_timeout(300)
        assert abs((await ana.locator("#snap-caption-box").bounding_box())["y"] - box["y"]) < 2
        # ...dragging does.
        cx, cy = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
        await ana.mouse.move(cx, cy)
        await ana.mouse.down()
        for i in range(1, 9):
            await ana.mouse.move(cx, cy + 25 * i)
        await ana.mouse.up()
        moved = await ana.locator("#snap-caption-box").bounding_box()
        assert abs(moved["y"] - (box["y"] + 200)) < 6, (box, moved)
        await expect(ana.locator("#snap-caption")).not_to_be_focused()  # a drag isn't a tap to edit
        sent_at = await ana.evaluate(CAPTION_AT, ["#snap-caption-box", "#camera-preview"])
        # A tap on it (no drag) edits it again; a tap on the picture finishes.
        await ana.locator("#snap-caption-box").click()
        await expect(ana.locator("#snap-caption")).to_be_focused()
        await ana.mouse.click(stage["x"] + 60, stage["y"] + 200)
        await expect(ana.locator("#snap-caption")).not_to_be_focused()
        await expect(ana.locator("#snap-caption")).to_have_value("up top")
        await shot(ana, "caption-placed-phone", full_page=False)
        print("tap to place, Enter or a tap to finish, drag to move; nothing sent")

        # From the chat: who it's going to, beside Send; a tap adds more, with Ben already ticked.
        await ana.click("#send-who")
        await expect(ana.locator("#send-to-dialog")).to_be_visible()
        await expect(ana.locator("#send-to-list label", has_text=BEN).locator("input")).to_be_checked()
        await ana.locator("#send-to-list label", has_text=CAL).locator("input").check()
        await expect(ana.locator("#send-to-go")).to_have_text("Send to 2")
        await ana.click("#send-to-go")
        await expect(ana.locator("#toast-text")).to_contain_text("Pic sent to", timeout=20000)
        print("+ Add opens Send to... with the chat ticked; adds a friend")

        # Ben sees the caption where Ana put it, on the picture itself.
        for page in (ben, cal):
            await row(page, ANA).click()
            await page.locator("button.snap-chip", has_text="Tap to view pic").click()
            await expect(page.locator("#viewer-caption")).to_have_text("up top", timeout=15000)
            seen_at = await page.evaluate(CAPTION_AT, ["#viewer-caption", "#viewer-image"])
            assert abs(seen_at - sent_at) < 0.03, (sent_at, seen_at)
        await shot(ben, "caption-seen-phone", full_page=False)
        if DB:
            formats = sqlite3.connect(DB).execute(
                "SELECT DISTINCT m.format FROM messages m JOIN users u ON u.id = m.sender_id"
                " WHERE m.kind = 'snap' AND u.username = ?", (ANA,)).fetchall()
            assert formats == [(6,)], formats
        print("the caption shows where it was put")

        assert not errors, errors
        await browser.close()
    print("CAPTIONS TEST PASSED")


asyncio.run(main())
