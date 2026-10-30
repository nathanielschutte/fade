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

from common import BASE, launch, no_placeholders, shot, fill_sign_up

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
    """From an invite link the form is already on signing up (its banner shows)."""
    on_invite = await page.locator("#invite-banner").is_visible()
    await fill_sign_up(page, name, code=code, toggle=not on_invite)


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
        await no_placeholders(ana, "#friends-dialog")
        await shot(ana, "add-friend-ways", full_page=False)
        size = ana.viewport_size
        await ana.set_viewport_size({"width": 390, "height": 844})
        await check_rendered(ana, mine, "#my-qr svg")
        await shot(ana, "add-friend-ways-phone", full_page=False)
        await ana.set_viewport_size(size)
        await ana.click("#friends-dialog [data-close]")
        await ana.click("#friends-button")
        await expect(ana.locator("#my-link")).to_have_text(mine)  # the same link every time
        # Nothing else to make or reset (X39): one link does both jobs.
        await expect(ana.locator("#friends-dialog details")).to_have_count(0)
        await expect(ana.locator("#invite-make, #my-link-reset")).to_have_count(0)

        # A stranger opens it on a phone: no invite code needed, and they're friends.
        cal = await (await browser.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)).new_page()
        await cal.goto(mine)
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

        # Someone signed in opens the same link: "Add Ana?"
        ben = await (await browser.new_context()).new_page()
        await ben.goto(BASE)
        await sign_up(ben, BEN)
        await ben.goto(mine)
        await expect(ben.locator("#invite-dialog")).to_be_visible(timeout=10000)
        await expect(ben.locator("#invite-text")).to_have_text(f"This is {ANA}'s napsack link. Add them as a friend?")
        await ben.click("#invite-accept")
        await expect(ben.locator("#chat-title")).to_have_text(ANA, timeout=10000)
        print("signed-in friend added through the same link")

        # It keeps working, and stays the same.
        dee = await (await browser.new_context()).new_page()
        await dee.goto(BASE)
        await sign_up(dee, f"dee_{ANA[4:]}")
        await dee.goto(mine)
        await expect(dee.locator("#invite-dialog")).to_be_visible(timeout=10000)
        await dee.click("#invite-accept")
        await expect(dee.locator("#chat-title")).to_have_text(ANA, timeout=10000)
        await ana.click("#friends-dialog [data-close]")
        await ana.click("#friends-button")
        await expect(ana.locator("#my-link")).to_have_text(mine)

        # A link that isn't anyone's says so.
        bad = await (await browser.new_context()).new_page()
        await bad.goto(f"{BASE}/i/{'A' * 22}")
        await expect(bad.locator("#invite-banner")).to_contain_text("This link doesn't work")
        print("the one link keeps adding friends; a wrong one says so")

        await browser.close()
    print("INVITES TEST PASSED")


asyncio.run(main())
