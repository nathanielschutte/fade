"""Group chats through the real UI: create, message, add, remove, rename,
leave, all live across four browsers. Settings come from the environment;
see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL, DEE = (f"{n}_{tag}" for n in ("ana", "ben", "cal", "dee"))
GROUP = "Road trip"

# Friend requests through the API with each page's own session (the UI for
# that is covered elsewhere); everything group-related goes through the UI.
REQUEST = """async (name) => (await fetch('/api/friends/requests', { method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + localStorage.getItem('fade.token') },
  body: JSON.stringify({ username: name }) })).status"""


async def register(browser, name, **ctx):
    page = await (await browser.new_context(**ctx)).new_page()
    await page.goto(BASE)
    await page.click("#auth-toggle")
    await page.fill("input[name=username]", name)
    await page.fill("input[name=password]", "correct horse battery")
    await page.fill("input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)
    return page


async def friends(a, b, b_name):
    assert await a.evaluate(REQUEST, b_name) == 200
    a_name = await a.evaluate("document.querySelector('#signed-in-as').textContent.replace('Signed in as ', '')")
    assert await b.evaluate(REQUEST, a_name) == 200  # asking back accepts


def group_item(page, name=GROUP):
    return page.locator(".chat-item.is-group", has_text=name)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await register(browser, ANA)
        ben = await register(browser, BEN)
        cal = await register(browser, CAL)
        dee = await register(browser, DEE, viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        for other, name in ((ben, BEN), (cal, CAL), (dee, DEE)):
            await friends(ana, other, name)

        # Ana creates the group with Ben and Cal.
        await ana.click("#new-group-button")
        await ana.fill("#new-group-name", GROUP)
        await expect(ana.locator("#new-group-friends .person-name")).to_have_count(3)
        for name in (BEN, CAL):
            await ana.locator("#new-group-friends label", has_text=name).locator("input").check()
        await ana.click("#new-group-submit")
        await expect(ana.locator("#chat-title")).to_have_text(GROUP)
        await expect(ana.locator("#chat-sub")).to_have_text("3 people")
        await expect(ana.locator("#group-notice")).to_be_visible()
        await expect(ana.locator("#camera-button")).to_be_hidden()
        await expect(ana.locator("#safety-button")).to_be_hidden()
        await expect(ana.locator(".group-event")).to_have_text(f"You created the group “{GROUP}”")
        print("created; notice shown, camera and safety code hidden")

        # It appears for Ben live; his message reaches the others live.
        await group_item(ben).click()
        await ben.fill("#composer-input", "who's driving?")
        await ben.press("#composer-input", "Enter")
        await expect(ana.locator(".msg", has_text="who's driving?")).to_be_visible(timeout=10000)
        await expect(ana.locator(".sender", has_text=BEN)).to_be_visible()
        await expect(group_item(cal).locator(".marker.text")).to_be_visible(timeout=10000)
        await group_item(cal).click()
        await expect(cal.locator(".msg", has_text="who's driving?")).to_be_visible()
        await expect(group_item(cal).locator(".marker.text")).to_have_count(0, timeout=10000)
        print("messages live; unread clears on open")

        # Ana (owner) adds Dee from the info sheet.
        await ana.click("#chat-title")
        await expect(ana.locator("#group-members .person")).to_have_count(3)
        await expect(ana.locator("#group-members .person", has_text=ANA).locator(".role-badge")).to_have_text("Owner")
        await ana.locator("#group-add .person", has_text=DEE).locator("button").click()
        await expect(ana.locator("#group-members .person")).to_have_count(4, timeout=10000)
        await expect(ana.locator("#group-note")).to_have_text(f"Added {DEE}.")
        await shot(ana, "group-info", full_page=False)
        await expect(group_item(dee)).to_be_visible(timeout=10000)

        # Ana removes Cal, who has the group open: it closes for Cal.
        await ana.locator("#group-members .person", has_text=CAL).locator("button", has_text="Remove").click()
        await expect(ana.locator("#group-members .person")).to_have_count(3, timeout=10000)
        await expect(group_item(cal)).to_have_count(0, timeout=10000)
        await expect(cal.locator("#chat")).to_be_hidden()
        await ana.click("#group-dialog [data-close]")
        await expect(ana.locator(".group-event", has_text=f"You removed {CAL}")).to_be_visible()
        print("added Dee; removed Cal, whose chat closed")

        # Ben isn't the owner: no Remove buttons, but he can rename.
        await ben.click("#chat-title")
        await expect(ben.locator("#group-members .person")).to_have_count(3)
        await expect(ben.locator("#group-members button", has_text="Remove")).to_have_count(0)
        await ben.fill("#rename-input", "Road trip 2026")
        await ben.click("#rename-form button")
        await expect(ana.locator("#chat-title")).to_have_text("Road trip 2026", timeout=10000)

        # Leaving takes two taps.
        await ben.click("#leave-group")
        await expect(ben.locator("#leave-group")).to_have_text("Tap again to leave")
        await expect(group_item(ben, "Road trip 2026")).to_be_visible()
        await ben.click("#leave-group")
        await expect(group_item(ben, "Road trip 2026")).to_have_count(0, timeout=10000)
        await expect(ana.locator(".group-event", has_text=f"{BEN} left")).to_be_visible(timeout=10000)
        await expect(ana.locator("#chat-sub")).to_have_text("2 people", timeout=10000)
        print("renamed live; left with two taps")

        # Dee on a phone: the group reads well and nothing overflows.
        await group_item(dee, "Road trip 2026").click()
        await expect(dee.locator(".group-event", has_text=f"{ANA} added you")).to_be_visible()
        await expect(dee.locator(".msg", has_text="who's driving?")).to_have_count(0)  # before Dee joined
        overflow = await dee.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"group chat scrolls sideways by {overflow}px"
        await shot(dee, "group-phone", full_page=False)
        await shot(ana, "group-desktop", full_page=False)
        await browser.close()
    print("GROUPS TEST PASSED")


asyncio.run(main())
