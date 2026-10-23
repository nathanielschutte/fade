"""The admin Metrics tab: how the machine and server are doing, drawn from
real readings of the test machine. Checks the status, the charts, hovering,
the ranges, the table, and the layout on a phone. Settings come from the
environment; see common.py."""
import asyncio
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, INVITE, launch, save_recovery_key, shot

ADMIN_PW = "correct horse battery"
errors = []


async def page_for(browser, label, **ctx):
    context = await browser.new_context(**ctx)
    p = await context.new_page()
    p.on("pageerror", lambda e: errors.append(f"{label}: {e}"))
    # (A failed sign-in before signing up logs a 400; that one is expected.)
    p.on("console", lambda m: m.type == "error" and "status of 4" not in m.text and errors.append(f"{label}: {m.text}"))
    await p.goto(BASE)
    return p


async def sign_up_or_in(p, name, pw):
    await p.fill("input[name=username]", name)
    await p.fill("input[name=password]", pw)
    await p.click("#auth-submit")
    try:
        await expect(p.locator("#app")).to_be_visible(timeout=15000)
        return
    except AssertionError:
        pass
    await p.click("#auth-toggle")
    await p.fill("input[name=username]", name)
    await p.fill("input[name=password]", pw)
    await p.fill("input[name=invite_code]", INVITE)
    await p.click("#auth-submit")
    await expect(p.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(p)


async def check_metrics(p):
    await expect(p.locator("#view-metrics")).to_be_visible()
    await expect(p.locator("#tab-metrics")).to_have_attribute("aria-current", "page")
    await expect(p.locator("#m-status .mstatus")).to_have_count(1, timeout=30000)
    assert await p.locator("#m-status .mstatus").inner_text() in ("All good", "Worth watching", "In the red")
    titles = await p.locator(".mchart h2").all_inner_texts()
    for t in ("CPU", "Memory", "Server memory", "Disk space", "Requests", "Response time", "Live connections"):
        assert t in titles, titles
    assert "CPU credits" not in titles, "credits only on AWS"
    # Every chart drew its data: a line or, for a single reading, a dot.
    await expect(p.locator(".mchart svg")).to_have_count(len(titles))
    drawn = await p.evaluate("""() => [...document.querySelectorAll('.mchart')].map((c) =>
      [c.querySelector('h2').textContent, c.querySelectorAll('.mline, .mdot').length])""")
    for title, marks in drawn:
        if title != "Disk activity":  # needs a real block device, which a test box may not show
            assert marks > 0, (title, drawn)
    assert "Cost shows when the server runs on AWS." in await p.locator("#m-cost").inner_text()
    rows = await p.locator("#m-table tbody tr").count()
    assert rows >= len(titles), rows


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        admin = await page_for(browser, "admin", viewport={"width": 1200, "height": 900})
        await sign_up_or_in(admin, ADMIN, ADMIN_PW)
        await admin.goto(f"{BASE}/admin#metrics")
        await check_metrics(admin)
        await expect(admin.locator("#m-range .segment[aria-pressed=true]")).to_have_text("24 hours")

        # The last hour, at 10-second readings.
        await admin.locator("#m-range .segment", has_text="1 hour").click()
        await expect(admin.locator("#m-range .segment[aria-pressed=true]")).to_have_text("1 hour")
        await expect(admin.locator("#m-note")).to_have_text("Every 10 seconds")
        await check_metrics(admin)

        # Hovering a chart shows the reading under the pointer.
        cpu = admin.locator(".mchart", has=admin.locator("h2", has_text="CPU")).first.locator(".mhit")
        box = await cpu.bounding_box()
        await admin.mouse.move(box["x"] + box["width"] - 4, box["y"] + box["height"] / 2)
        await expect(admin.locator("#tip")).to_be_visible()
        assert "Machine:" in await admin.locator("#tip").inner_text()
        await shot(admin, "metrics-desktop")
        await admin.mouse.move(5, 5)
        await expect(admin.locator("#tip")).to_be_hidden()

        await admin.locator("#m-range .segment", has_text="3 days").click()
        await expect(admin.locator("#m-range .segment[aria-pressed=true]")).to_have_text("3 days")
        await check_metrics(admin)

        # A phone: one column, nothing wider than the screen.
        phone = await page_for(browser, "phone", viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        await sign_up_or_in(phone, ADMIN, ADMIN_PW)
        await phone.goto(f"{BASE}/admin#metrics")
        await check_metrics(phone)
        overflow = await phone.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert overflow <= 0, f"page scrolls sideways by {overflow}px"
        await shot(phone, "metrics-phone")

        assert not errors, errors
        await browser.close()
    print("METRICS TEST PASSED")


asyncio.run(main())
