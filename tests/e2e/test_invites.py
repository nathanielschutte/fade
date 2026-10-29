"""Invite links and QR codes (F14), in the browser:
- The QR encoder (server/static/qr.js) matches an independent one, Python's
  qrcode, module for module, for every mask and several lengths.
- A link signs a stranger up with no invite code and makes them friends.
- Someone signed in who opens a link adds the person who made it.
Settings come from the environment; see common.py."""
import asyncio, struct, uuid, zlib

import qrcode
from qrcode.util import MODE_8BIT_BYTE, QRData
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"


def reference(text, version, mask):
    q = qrcode.QRCode(version=version, error_correction=qrcode.constants.ERROR_CORRECT_M, border=0, mask_pattern=mask)
    q.add_data(QRData(text.encode(), mode=MODE_8BIT_BYTE))
    q.make(fit=False)
    return [[bool(c) for c in row] for row in q.get_matrix()]


def png_pixels(data):
    """(width, height, rows of (r, g, b)) from a PNG screenshot: 8-bit RGB or RGBA, no imaging library needed."""
    assert data[:8] == bytes([0x89]) + b"PNG" + bytes([13, 10, 26, 10]), "not a PNG"
    pos, idat, width = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", chunk[:10])
            assert depth == 8 and color in (2, 6), (depth, color)
            bpp = 3 if color == 2 else 4
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(idat), width * bpp, [], bytearray(width * bpp)
    for y in range(height):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            pred = {0: 0, 1: a, 2: b, 3: (a + b) // 2}.get(f)
            if pred is None:  # Paeth
                p0 = a + b - c
                pa, pb, pc = abs(p0 - a), abs(p0 - b), abs(p0 - c)
                pred = a if pa <= pb and pa <= pc else b if pb <= pc else c
            line[i] = (line[i] + pred) & 0xFF
        rows.append([tuple(line[x * bpp:x * bpp + 3]) for x in range(width)])
        prev = line
    return width, height, rows


async def check_rendered(page, link, selector="#invite-qr svg"):
    """The QR on screen, pixel by pixel: every module dark or light as the code says,
    with a white quiet zone (what a phone camera actually needs)."""
    m = await page.evaluate("async (t) => (await import('/qr.js')).qrMatrix(t)", link)
    width, height, rows = png_pixels(await page.locator(selector).screenshot())
    full = m["size"] + 8
    dark = lambda x, y: sum(rows[y][x]) / 3 < 128
    for my in range(-4, m["size"] + 4):
        for mx in range(-4, m["size"] + 4):
            px, py = int((mx + 4 + 0.5) * width / full), int((my + 4 + 0.5) * height / full)
            want = 0 <= mx < m["size"] and 0 <= my < m["size"] and m["modules"][my][mx]
            assert dark(px, py) == want, f"module ({mx}, {my}) renders wrong"


async def sign_up(page, name, code=True):
    if not await page.locator("#invite-banner").is_visible():
        await page.click("#auth-toggle")
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", "correct horse battery")
    if code:
        await page.fill("#auth-form input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(page)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)

        # The encoder, against Python's qrcode.
        page = await browser.new_page()
        await page.goto(BASE)
        samples = [
            "https://napsack.getattr.com/i/AbCdEfGhIjKlMnOpQrStUv",
            "http://127.0.0.1:8099/i/0123456789_-abcdefghij",
            "a",
            "napsack 🌿 " * 8,
            "x" * 200,
        ]
        checked = 0
        for text in samples:
            for mask in range(8):
                got = await page.evaluate("async ([t, m]) => (await import('/qr.js')).qrMatrix(t, { mask: m })", [text, mask])
                assert got["modules"] == reference(text, got["version"], mask), (text[:30], got["version"], mask)
                checked += 1
        auto = await page.evaluate("async (t) => (await import('/qr.js')).qrMatrix(t)", samples[0])
        assert auto["modules"] == reference(samples[0], auto["version"], auto["mask"])
        print(f"QR codes match an independent encoder ({checked} codes, versions up to {got['version']})")

        # Ana makes a link.
        ana = await (await browser.new_context()).new_page()
        await ana.goto(BASE)
        await sign_up(ana, ANA)
        await ana.click("#friends-button")
        # Her own add-me code is right there (X25), and it's a real QR of her link.
        await expect(ana.locator("#my-qr svg")).to_be_visible(timeout=10000)
        mine = await ana.locator("#my-link").text_content()
        assert mine.startswith(f"{BASE}/i/") and len(mine) == len(f"{BASE}/i/") + 22, mine
        await check_rendered(ana, mine, "#my-qr svg")
        await shot(ana, "add-friend-ways", full_page=False)
        size = ana.viewport_size
        await ana.set_viewport_size({"width": 390, "height": 844})
        await check_rendered(ana, mine, "#my-qr svg")
        await shot(ana, "add-friend-ways-phone", full_page=False)
        await ana.set_viewport_size(size)
        await ana.click("#friends-dialog [data-close]")
        await ana.click("#friends-button")
        await expect(ana.locator("#my-link")).to_have_text(mine)  # the same link every time
        # One-time invite links are one step further in.
        await ana.locator(".more-invites summary").click()
        await ana.click("#invite-make")
        await expect(ana.locator("#invite-qr svg")).to_be_visible()
        link = await ana.locator("#invite-link").text_content()
        await check_rendered(ana, link)
        assert link.startswith(f"{BASE}/i/") and len(link) == len(f"{BASE}/i/") + 22, link
        await expect(ana.locator("#invite-list .person").first).to_contain_text("0 of 10 used")
        await shot(ana, "invite-link", full_page=False)

        # A stranger opens it on a phone: no invite code needed, and they're friends.
        cal = await (await browser.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)).new_page()
        await cal.goto(link)
        await expect(cal.locator("#invite-banner")).to_contain_text(f"{ANA} invited you")
        await expect(cal.locator("#invite-field")).to_be_hidden()
        assert await cal.evaluate("location.pathname") == "/"
        await shot(cal, "invite-signup", full_page=False)
        await sign_up(cal, CAL, code=False)
        await expect(cal.locator("#chat-title")).to_have_text(ANA, timeout=10000)
        await expect(ana.locator(".chat-item", has_text=CAL)).to_be_visible(timeout=10000)
        overflow = await cal.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"scrolls sideways by {overflow}px"
        print("stranger signed up through the link and is friends")

        # Someone signed in opens it: "Add Ana?"
        ben = await (await browser.new_context()).new_page()
        await ben.goto(BASE)
        await sign_up(ben, BEN)
        await ben.goto(link)
        await expect(ben.locator("#invite-dialog")).to_be_visible(timeout=10000)
        await expect(ben.locator("#invite-text")).to_have_text(f"This is {ANA}'s napsack link. Add them as a friend?")
        await ben.click("#invite-accept")
        await expect(ben.locator("#chat-title")).to_have_text(ANA, timeout=10000)
        print("signed-in friend added through the link")

        # Ana sees who joined, and can turn the link off.
        await ana.click("#friends-dialog [data-close]")
        await ana.click("#friends-button")
        if not await ana.locator(".more-invites").evaluate("e => e.open"):
            await ana.locator(".more-invites summary").click()
        row = ana.locator("#invite-list .person").first
        await expect(row).to_contain_text("2 of 10 used")
        await expect(row).to_contain_text(CAL)
        await expect(row).to_contain_text(BEN)
        await row.locator("button", has_text="Turn off").click()
        await expect(ana.locator("#invite-note")).to_have_text("That link no longer works.")
        await expect(ana.locator("#invite-list .person").first).to_contain_text("turned off")
        late = await (await browser.new_context()).new_page()
        await late.goto(link)
        await expect(late.locator("#invite-banner")).to_contain_text("expired, been used up, or been turned off")
        print("inviter sees who joined; a turned-off link stops working")

        # Ana's personal link: someone signed in adds her with it, any number of times.
        dee = await (await browser.new_context()).new_page()
        await dee.goto(BASE)
        await sign_up(dee, f"dee_{ANA[4:]}")
        await dee.goto(mine)
        await expect(dee.locator("#invite-dialog")).to_be_visible(timeout=10000)
        await dee.click("#invite-accept")
        await expect(dee.locator("#chat-title")).to_have_text(ANA, timeout=10000)
        # Resetting it (two taps): the old one stops working, and there's a new one.
        await ana.click("#my-link-reset")
        await expect(ana.locator("#my-link-reset")).to_have_text("Tap again: your old code stops working")
        await ana.click("#my-link-reset")
        await expect(ana.locator("#my-link-note")).to_contain_text("The old ones don't work any more")
        renewed = await ana.locator("#my-link").text_content()
        assert renewed != mine and renewed.startswith(f"{BASE}/i/")
        gone = await (await browser.new_context()).new_page()
        await gone.goto(mine)
        await expect(gone.locator("#invite-banner")).to_contain_text("expired, been used up, or been turned off")
        print("a personal link adds friends until it's reset")

        await browser.close()
    print("INVITES TEST PASSED")


asyncio.run(main())
