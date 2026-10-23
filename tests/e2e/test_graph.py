"""The friend map (docs/friend-graph.md): a person's own map, with their
friends, who knows who, and a ? for a friend of a friend; tapping someone;
the list view; the admin graph's switch, people picker, and depth; and the
phone layout. Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL, DEE = (f"{n}_{tag}" for n in ("ana", "ben", "cal", "dee"))
PW = "correct horse battery"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}
errors = []

# SVG nodes inside the friend map, by kind.
NODES = """(sel) => [...document.querySelectorAll(sel + ' .gnode')].map((g) =>
  [g.classList.contains('unknown') ? '?' : g.classList.contains('center') ? 'center' : 'person', g.getAttribute('aria-label')])"""


async def page_for(browser, label, **ctx):
    p = await (await browser.new_context(**ctx)).new_page()
    p.on("pageerror", lambda e: errors.append(f"{label}: {e}"))
    p.on("console", lambda m: m.type == "error" and "status of 4" not in m.text and errors.append(f"{label}: {m.text}"))
    await p.goto(BASE)
    return p


async def sign_up(p, name):
    await p.click("#auth-toggle")
    await p.fill("#auth-form input[name=username]", name)
    await p.fill("#auth-form input[name=password]", PW)
    await p.fill("#auth-form input[name=invite_code]", INVITE)
    await p.click("#auth-submit")
    await expect(p.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(p)


async def sign_up_or_in(p, name):
    await p.fill("input[name=username]", name)
    await p.fill("input[name=password]", PW)
    await p.click("#auth-submit")
    try:
        await expect(p.locator("#app")).to_be_visible(timeout=15000)
    except AssertionError:
        await sign_up(p, name)


async def befriend(asker, asked, name_of_asked, name_of_asker):
    await asker.click("#friends-button")
    await asker.fill("#add-friend-form input[name=username]", name_of_asked)
    await asker.click("#add-friend-form button[type=submit]")
    await expect(asker.locator("#add-friend-note")).to_contain_text("Request sent")
    await asker.click("#friends-dialog [data-close]")
    await asked.click("#friends-button")
    await asked.locator("#incoming-list li", has_text=name_of_asker).locator("button", has_text="Accept").click()
    await asked.click("#friends-dialog [data-close]")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await page_for(browser, "ana", viewport={"width": 1200, "height": 900})
        ben = await page_for(browser, "ben", **PHONE)
        cal = await page_for(browser, "cal")
        dee = await page_for(browser, "dee")
        for p, n in ((ana, ANA), (ben, BEN), (cal, CAL), (dee, DEE)):
            await sign_up(p, n)
        await befriend(ana, ben, BEN, ANA)
        await befriend(ana, cal, CAL, ANA)
        await befriend(ben, cal, CAL, BEN)
        await befriend(cal, dee, DEE, CAL)

        # Ana's map: her in the middle, Ben and Cal (who know each other), and
        # a ? for Dee (Cal's friend she doesn't know). Never Dee's name.
        await ana.click("#friends-button")
        await ana.click("#graph-open")
        await expect(ana.locator("#graph-dialog")).to_be_visible()
        await expect(ana.locator("#graph-host .gnode")).to_have_count(4, timeout=10000)
        nodes = await ana.evaluate(NODES, "#graph-host")
        assert sorted(nodes, key=str) == sorted([["center", "You"], ["person", BEN], ["person", CAL], ["?", None]], key=str), nodes
        assert DEE not in await ana.locator("#graph-dialog").inner_text()
        await expect(ana.locator("#graph-host .gedge")).to_have_count(4)  # you–ben, you–cal, ben–cal, cal–?
        await expect(ana.locator("#graph-host .ghull")).to_have_count(1)  # Ben, Cal and the ? are one group
        await expect(ana.locator("#graph-host .graph-legend")).to_contain_text("Group A")
        await expect(ana.locator("#graph-host .graph-legend")).to_contain_text("1 person your friends know that you don't")
        await asyncio.sleep(0.9)  # the entrance animation
        await shot(ana, "graph-desktop", full_page=False)

        # Tap Cal: who they are, and who they know.
        await ana.locator(f"#graph-host .gnode[aria-label='{CAL}'] .ghit").click()
        await expect(ana.locator(".graph-caption")).to_contain_text(f"{CAL} · Group A · knows 1 of your friends and 1 person you don't")
        await expect(ana.locator("#graph-host .graph-svg")).to_have_class("graph-svg has-focus")
        await expect(ana.locator("#graph-host .gedge.lit")).to_have_count(3)
        # The ?: a friend of Cal, nothing more.
        await ana.locator("#graph-host .gnode.unknown").dispatch_event("click")
        await expect(ana.locator(".graph-caption")).to_have_text(f"Someone you don't know yet: a friend of {CAL}.")
        # Tapping the background clears it; the list has everything in words.
        await ana.locator("#graph-host .graph-svg").click(position={"x": 5, "y": 5})
        await expect(ana.locator("#graph-host .graph-svg")).to_have_class("graph-svg")
        await ana.locator("#graph-host .graph-list summary").click()
        await expect(ana.locator("#graph-host .graph-list")).to_contain_text(f"Group A: {BEN}, {CAL} and 1 you don't know")
        # Message from the map opens the chat.
        await ana.locator(f"#graph-host .gnode[aria-label='{BEN}'] .ghit").click()
        await ana.locator(".graph-caption button", has_text="Message").click()
        await expect(ana.locator("#graph-dialog")).not_to_be_visible()
        await expect(ana.locator("#chat-title")).to_have_text(BEN)

        # Dee knows only Cal: one friend, and Cal's other friends as ?s.
        await dee.click("#friends-button")
        await dee.click("#graph-open")
        await expect(dee.locator("#graph-host .gnode")).to_have_count(4, timeout=10000)  # Dee, Cal, and Ana and Ben as ?s
        await expect(dee.locator("#graph-host .gnode.unknown")).to_have_count(2)
        assert ANA not in await dee.locator("#graph-dialog").inner_text()

        # A phone: the map fits, nothing scrolls sideways.
        await ben.click("#friends-button")
        await ben.click("#graph-open")
        await expect(ben.locator("#graph-host .gnode")).to_have_count(4, timeout=10000)
        overflow = await ben.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert overflow <= 0, f"scrolls sideways by {overflow}px"
        box = await ben.locator("#graph-host .graph-svg").bounding_box()
        assert box["width"] <= 390, box
        await asyncio.sleep(0.9)
        await shot(ben, "graph-phone", full_page=False)

        # Admin: you by default; everyone with the switch; chosen people; depth.
        admin = await page_for(browser, "admin", viewport={"width": 1200, "height": 900})
        await sign_up_or_in(admin, ADMIN)
        await admin.goto(f"{BASE}/admin#graph")
        await expect(admin.locator("#tab-graph")).to_have_attribute("aria-current", "page")
        await expect(admin.locator("#g-host .gnode, #g-host p")).not_to_have_count(0, timeout=10000)
        await admin.locator(".switch").click()
        await expect(admin.locator("#g-note")).to_contain_text("Everyone", timeout=10000)
        everyone = await admin.locator("#g-host .gnode").count()
        assert everyone >= 5, everyone
        await expect(admin.locator("#g-people")).to_be_hidden()
        await admin.locator(".switch").click()
        await expect(admin.locator("#g-people")).to_be_visible()
        await admin.locator("#g-people summary").click()
        await admin.fill("#g-search", ANA)
        await admin.locator("#g-people-list label", has_text=ANA).locator("input").check()
        await expect(admin.locator(f"#g-host .gnode[aria-label='{CAL}']")).to_have_count(1, timeout=10000)
        await expect(admin.locator(f"#g-host .gnode[aria-label='{DEE}']")).to_have_count(0)
        await admin.locator("#g-people summary").click()  # close the picker
        # Uncheck the admin themself, so it's only Ana's graph: Ana in the middle.
        await admin.locator("#g-people summary").click()
        await admin.fill("#g-search", "")
        boxes = admin.locator("#g-people-list input:checked")
        for i in range(await boxes.count() - 1, -1, -1):
            label = await boxes.nth(i).evaluate("e => e.parentElement.textContent.trim()")
            if label != ANA:
                await boxes.nth(i).uncheck()
        await admin.locator("#g-people summary").click()
        await expect(admin.locator("#g-host .gnode.center")).to_have_attribute("aria-label", ANA, timeout=10000)
        await admin.locator("#g-depth .segment", has_text="Friends of friends").click()
        await expect(admin.locator(f"#g-host .gnode[aria-label='{DEE}']")).to_have_count(1, timeout=10000)
        await asyncio.sleep(0.9)
        await shot(admin, "graph-admin", full_page=False)
        # "Show their graph" from a picked person.
        await admin.locator(f"#g-host .gnode[aria-label='{DEE}'] .ghit").click()
        await admin.locator(".graph-caption button", has_text="Show their graph").click()
        await expect(admin.locator("#g-host .gnode.center")).to_have_attribute("aria-label", DEE, timeout=10000)

        assert not errors, errors
        await browser.close()
    print("GRAPH TEST PASSED")


asyncio.run(main())
