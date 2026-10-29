"""Roles (docs/implementation/roles.md) in the browser: an Admin makes someone a PowerUser on
the Roles page; the PowerUser gets the System link and the tabs for their role
(no Logs), the overview without the users table, metrics without cost, the
graph with strangers anonymous, and can make a friend a PowerUser but not take
it away. Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, REMOTE, launch, shot, befriend, sign_up_or_in, fill_sign_up, open_page

tag = uuid.uuid4().hex[:5]
PWR, FRIEND, STRANGER = (f"{n}_{tag}" for n in ("pwr", "fri", "str"))
errors = []


def row(p, name):
    return p.locator("#r-rows tr", has=p.locator("td", has_text=name))


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        pwr = await open_page(browser, errors, "pwr", console=True, viewport={"width": 1200, "height": 900})
        friend = await open_page(browser, errors, "friend", console=True)
        stranger = await open_page(browser, errors, "stranger", console=True)
        for p, n in ((pwr, PWR), (friend, FRIEND), (stranger, STRANGER)):
            await fill_sign_up(p, n)
        await befriend(pwr, friend, FRIEND, PWR)
        await befriend(friend, stranger, STRANGER, FRIEND)
        await expect(pwr.locator("#admin-link")).to_be_hidden()  # a User: no System link

        # An Admin makes them a PowerUser on the Roles page.
        admin = await open_page(browser, errors, "admin", console=True, viewport={"width": 1200, "height": 900})
        await sign_up_or_in(admin, ADMIN)
        await expect(admin.locator("#admin-link")).to_contain_text("System")
        # System also sits at the foot of their own profile, as a button like
        # Sign out beside it: the same height, colors, and centered words.
        await admin.click("#my-profile")
        await expect(admin.locator("#profile-admin-link")).to_be_visible(timeout=10000)
        link, out = admin.locator("#profile-admin-link"), admin.locator("#profile-sign-out")
        assert (await link.bounding_box())["height"] == (await out.bounding_box())["height"]
        style = "e => [getComputedStyle(e).color, getComputedStyle(e).alignItems]"
        assert await link.evaluate(style) == [(await out.evaluate(style))[0], "center"], await link.evaluate(style)
        await admin.click("#profile-dialog [data-close]")
        await admin.goto(f"{BASE}/admin#roles")
        await expect(admin.locator("#tab-logs")).to_be_visible()
        await admin.fill("#r-search", PWR)
        await expect(row(admin, PWR).locator(".role-badge")).to_have_text("User", timeout=10000)
        await row(admin, PWR).locator("button", has_text="Make PowerUser").click()
        await expect(row(admin, PWR).locator(".role-badge")).to_have_text("PowerUser", timeout=10000)
        await expect(admin.locator("#r-result")).to_contain_text(f"{PWR} is a PowerUser now.")

        # The PowerUser: the System link, and their tabs only.
        await pwr.reload()
        await expect(pwr.locator("#admin-link")).to_be_visible(timeout=10000)
        await pwr.click("#admin-link")
        await expect(pwr.locator("#view-overview")).to_be_visible(timeout=10000)
        for tab in ("overview", "metrics", "graph", "roles"):
            await expect(pwr.locator(f"#tab-{tab}")).to_be_visible()
        await expect(pwr.locator("#tab-logs")).to_be_hidden()
        await expect(pwr.locator("#t-users")).not_to_be_empty()
        await expect(pwr.locator("#tab-users")).to_be_hidden()  # People and account tools: Admins only
        assert await pwr.locator("#u-actions button").count() == 0
        # Asking for Logs directly lands on the overview.
        await pwr.goto(f"{BASE}/admin#logs")
        await expect(pwr.locator("#view-overview")).to_be_visible(timeout=10000)
        await expect(pwr.locator("#view-logs")).to_be_hidden()
        # Metrics without cost.
        await pwr.goto(f"{BASE}/admin#metrics")
        await expect(pwr.locator(".mchart").first).to_be_visible(timeout=30000)
        await expect(pwr.locator("#m-cost")).to_be_hidden()
        await expect(pwr.locator("#m-incidents-panel")).to_be_hidden()  # incidents: Admins only
        # The graph: the friend by name, the stranger anonymous.
        await pwr.goto(f"{BASE}/admin#graph")
        await pwr.locator("#g-depth .segment", has_text="Friends of friends").click()
        await expect(pwr.locator(f"#g-host .gnode[aria-label='{FRIEND}']")).to_have_count(1, timeout=10000)
        await expect(pwr.locator("#g-host .gnode[aria-label^='Someone ']")).to_have_count(1)
        await expect(pwr.locator("#g-note")).to_contain_text("anonymous")
        assert STRANGER not in await pwr.content()
        await asyncio.sleep(0.9)
        await shot(pwr, "roles-poweruser-graph", full_page=False)
        # Roles: themselves and their friend; can grant, can't take away.
        await pwr.goto(f"{BASE}/admin#roles")
        await expect(row(pwr, FRIEND).locator(".role-badge")).to_have_text("User", timeout=10000)
        assert await pwr.locator("#r-rows tr").count() == 2
        await row(pwr, FRIEND).locator("button", has_text="Make PowerUser").click()
        await expect(row(pwr, FRIEND).locator(".role-badge")).to_have_text("PowerUser", timeout=10000)
        assert await pwr.locator("#r-rows button", has_text="Remove PowerUser").count() == 0
        await expect(pwr.locator("#r-admin")).to_be_hidden()
        await shot(pwr, "roles-poweruser-roles", full_page=False)

        # Incidents on Metrics: Admins only. Locally there's no monitor to read.
        await admin.goto(f"{BASE}/admin#metrics")
        await expect(admin.locator("#m-incidents-panel")).to_be_visible(timeout=30000)
        await expect(admin.locator("#m-incidents")).to_contain_text("no health monitor here" if not REMOTE else "")
        await admin.goto(f"{BASE}/admin#roles")

        # Only an Admin takes it away: two taps.
        await admin.reload()  # (already on #roles: fetch the list afresh)
        await admin.fill("#r-search", FRIEND)
        await row(admin, FRIEND).locator("button", has_text="Remove PowerUser").click()
        await row(admin, FRIEND).locator("button", has_text="Tap again: remove PowerUser").click()
        await expect(row(admin, FRIEND).locator(".role-badge")).to_have_text("User", timeout=10000)
        await shot(admin, "roles-admin", full_page=False)

        assert not errors, errors
        await browser.close()
    print("ROLES TEST PASSED")


asyncio.run(main())
