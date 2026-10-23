"""The admin Metrics tab: how the machine and server are doing, drawn from
real readings of the test machine. Checks the status, the charts, hovering,
the ranges, the table, and the layout on a phone. Settings come from the
environment; see common.py."""
import asyncio, re
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, INVITE, REMOTE, launch, save_recovery_key, shot

ADMIN_PW = "correct horse battery"
errors = []

# Data marks (lines, bands, dots) that reach outside a chart's plot area.
OUTSIDE = """() => [...document.querySelectorAll('.mchart-svg')].flatMap((s) => {
  const w = s.viewBox.baseVal.width;
  return [...s.querySelectorAll('.mline, .mband, .mdot')].map((e) => e.getBBox())
    .filter((b) => b.x < 40 || b.x + b.width > w - 6)
    .map((b) => [Math.round(b.x), Math.round(b.width), w]);
})"""


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


DRAWN = """() => [...document.querySelectorAll('.mchart')].map((c) =>
  [c.querySelector('h2').textContent, c.querySelectorAll('.mline, .mdot').length])"""

# What the page was given, for a failure message.
SERIES = """async (hours) => {
  const r = await fetch(`/api/admin/metrics?hours=${hours}`, { headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } });
  const d = await r.json();
  return { generated_at: d.generated_at, hosts: d.hosts.map((h) => [h.host, h.series.length, h.series.slice(-2).map((x) => x.t)]) };
}"""


SERIES_FOR = """async (hours) => {
  const r = await fetch(`/api/admin/metrics?hours=${hours}`, { headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } });
  const d = await r.json();
  return { generated_at: d.generated_at, series: d.hosts[0].series.map((p) => [p.t, p.s]) };
}"""


async def check_series(p):
    """The data under the charts: in order, never overlapping, inside the
    range, and the last hour shows at least as much as the 24-hour view does
    for that same hour (it used to start at the server's last restart)."""
    hour = await p.evaluate(SERIES_FOR, 1)
    day = await p.evaluate(SERIES_FOR, 24)
    for name, d, hours in (("1h", hour, 1), ("24h", day, 24)):
        pts = d["series"]
        assert pts, name
        for (t, s), (t2, _) in zip(pts, pts[1:]):
            assert s > 0 and t + s <= t2 + 1, (name, "overlap or out of order", t, s, t2)
        assert pts[0][0] + pts[0][1] > d["generated_at"] - hours * 3600, (name, "starts before its range")
        assert pts[-1][0] <= d["generated_at"], (name, "ends after now")
    since = hour["generated_at"] - 3600
    day_in_hour = [t for t, s in day["series"] if t >= since]
    if day_in_hour:
        assert hour["series"][0][0] <= day_in_hour[0] + 60, (hour["series"][:3], day_in_hour[:3])


async def check_metrics(p, phase):
    await expect(p.locator("#view-metrics")).to_be_visible()
    await expect(p.locator("#tab-metrics")).to_have_attribute("aria-current", "page")
    await expect(p.locator("#m-status .mstatus")).to_have_count(1, timeout=30000)
    assert await p.locator("#m-status .mstatus").inner_text() in ("All good", "Worth watching", "In the red")
    titles = await p.locator(".mchart h2").all_inner_texts()
    for t in ("CPU", "Memory", "Server memory", "Disk space", "Requests", "Response time", "Live connections"):
        assert t in titles, titles
    if not REMOTE:
        assert "CPU credits" not in titles, "credits only on AWS"
    # Every chart drew its data: a line or, for a single reading, a dot.
    # (Charts are drawn on the next frame and redrawn on each refresh, so give it a moment.)
    await expect(p.locator(".mchart svg")).to_have_count(len(titles))
    for _ in range(50):
        drawn = await p.evaluate(DRAWN)
        # Disk activity needs a real block device, which a test box may not have.
        empty = [t for t, marks in drawn if marks == 0 and t != "Disk activity"]
        if not empty:
            break
        await asyncio.sleep(0.1)
    if empty:
        hours = await p.locator("#m-range .segment[aria-pressed=true]").get_attribute("data-hours")
        raise AssertionError(f"{phase}: nothing drawn in {empty}; the page has {await p.evaluate(SERIES, hours)}")
    if not REMOTE:  # a deployed server is on AWS, with a real estimate
        assert "Cost shows when the server runs on AWS." in await p.locator("#m-cost").inner_text()
    rows = await p.locator("#m-table tbody tr").count()
    assert rows >= len(titles), rows


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        admin = await page_for(browser, "admin", viewport={"width": 1200, "height": 900})
        await sign_up_or_in(admin, ADMIN, ADMIN_PW)
        await admin.goto(f"{BASE}/admin#metrics")
        await check_metrics(admin, "24 hours")
        await check_series(admin)
        await expect(admin.locator("#m-range .segment[aria-pressed=true]")).to_have_text("24 hours")

        # The last hour, at 10-second readings.
        await admin.locator("#m-range .segment", has_text="1 hour").click()
        await expect(admin.locator("#m-range .segment[aria-pressed=true]")).to_have_text("1 hour")
        await expect(admin.locator("#m-note")).to_contain_text("Every 10 seconds")
        await check_metrics(admin, "1 hour")

        # Hovering a chart shows the reading under the pointer.
        # (The charts redraw with each new reading; a redraw under a still
        # pointer can drop the tip, so move again if it isn't up yet.)
        cpu = admin.locator(".mchart", has=admin.locator("h2", has_text=re.compile(r"^CPU$"))).first.locator(".mhit")
        await cpu.scroll_into_view_if_needed()  # (staging's incidents can push it below the fold)
        for attempt in range(3):
            box = await cpu.bounding_box()
            await admin.mouse.move(box["x"] + box["width"] - 12, box["y"] + box["height"] / 2)
            await admin.mouse.move(box["x"] + box["width"] - 4, box["y"] + box["height"] / 2)
            try:
                await expect(admin.locator("#tip")).to_be_visible(timeout=3000)
                break
            except AssertionError:
                if attempt == 2:
                    raise
        assert "Machine:" in await admin.locator("#tip").inner_text()
        await shot(admin, "metrics-desktop")
        await admin.mouse.move(5, 5)
        await expect(admin.locator("#tip")).to_be_hidden()

        await admin.locator("#m-range .segment", has_text="3 days").click()
        await expect(admin.locator("#m-range .segment[aria-pressed=true]")).to_have_text("3 days")
        await check_metrics(admin, "3 days")

        # On AWS, CPU credits come back for the whole retention window whatever
        # the range. Whatever's outside the range must not be drawn past the
        # chart's edge (it was, before 0.26.2).
        async def with_credits(route):
            resp = await route.fetch()
            body = await resp.json()
            t = body["generated_at"]
            for h in body["hosts"]:
                # Oldest first, as CloudWatch returns them.
                h["credits"] = {"points": [[t - i * 300, 144 - i % 60, 0] for i in reversed(range(864))], "updated_at": t}
            await route.fulfill(response=resp, json=body)
        await admin.route("**/api/admin/metrics*", with_credits)
        for label in ("1 hour", "24 hours", "3 days"):
            await admin.locator("#m-range .segment", has_text=label).click()
            await expect(admin.locator("#m-range .segment[aria-pressed=true]")).to_have_text(label)
            await expect(admin.locator(".mchart h2", has_text="CPU credits")).to_have_count(1)
            await asyncio.sleep(0.4)  # drawn on the next frame
            outside = await admin.evaluate(OUTSIDE)
            assert not outside, (label, outside)
        await shot(admin, "metrics-credits-1h")
        await admin.unroute("**/api/admin/metrics*")

        # A quick second click mid-load still wins: the charts follow the highlighted range.
        await admin.locator("#m-range .segment", has_text="1 hour").click()
        await admin.locator("#m-range .segment", has_text="24 hours").click()
        await expect(admin.locator("#m-range .segment[aria-pressed=true]")).to_have_text("24 hours")
        await expect(admin.locator("#m-note")).to_have_text("Each point: a minute or more (average, with its range)")

        # A phone: one column, nothing wider than the screen.
        phone = await page_for(browser, "phone", viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        await sign_up_or_in(phone, ADMIN, ADMIN_PW)
        await phone.goto(f"{BASE}/admin#metrics")
        await check_metrics(phone, "phone")
        overflow = await phone.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert overflow <= 0, f"page scrolls sideways by {overflow}px"
        await shot(phone, "metrics-phone")

        assert not errors, errors
        await browser.close()
    print("METRICS TEST PASSED")


asyncio.run(main())
