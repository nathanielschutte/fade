"""Tabs on phones, the camera tab, and sending a pic to several chats (X26).
A phone has Chats, Camera and Profile along the bottom; a computer keeps the
side-by-side layout with a camera button in the list's bar. A pic taken from
the camera tab goes to whoever's picked in Send to…: friends and groups,
each an end-to-end encrypted copy. If one fails, Send again sends only to
the rest. Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import launch, shot, PHONE, befriend, row, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
GROUP = f"Hike {tag}"
errors = []

PICK_IMAGE = """async () => {
  const c = document.createElement('canvas'); c.width = 900; c.height = 600;
  const g = c.getContext('2d'); g.fillStyle = '#2b5'; g.fillRect(0, 0, 900, 600); g.fillStyle = '#fff'; g.fillRect(300, 150, 300, 300);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'pic.png', { type: 'image/png' }));
  const input = document.querySelector('#file-input'); input.files = dt.files; input.dispatchEvent(new Event('change'));
}"""


def pick(page, name):
    return page.locator("#send-to-list label", has_text=name).locator("input")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, **PHONE)
        ben = await sign_up(browser, BEN, errors=errors)
        cal = await sign_up(browser, CAL, errors=errors, **PHONE)
        await befriend(ana, ben, BEN, ANA)
        await befriend(ana, cal, CAL, ANA)
        # Ben (on a computer) makes a group with Ana.
        await befriend(ben, cal, CAL, BEN)
        await ben.click("#start-button")
        await ben.fill("#new-group-name", GROUP)
        await ben.locator("#new-group-friends label", has_text=ANA).locator("input").check()
        await ben.click("#new-group-submit")
        await expect(ben.locator("#chat-title")).to_have_text(GROUP)

        # Phone: tabs along the bottom; the account bar and the list's camera button are gone.
        await expect(ana.locator("#tabs")).to_be_visible()
        await expect(ana.locator(".account-bar")).to_be_hidden()
        await expect(ana.locator("#list-camera")).to_be_hidden()
        await expect(ana.locator("#tab-chats")).to_have_attribute("aria-current", "page")
        await expect(row(ana, GROUP)).to_be_visible(timeout=10000)
        await shot(ana, "tabs-chats-phone", full_page=False)
        # Computer: no tabs; a camera button in the bar, the profile at the bottom.
        await expect(ben.locator("#tabs")).to_be_hidden()
        await expect(ben.locator("#list-camera")).to_be_visible()
        await expect(ben.locator(".account-bar")).to_be_visible()
        print("tabs on phones; camera button and account bar on computers")

        # Profile tab: your profile in place of the list, with the tabs still there.
        await ana.click("#tab-profile")
        await expect(ana.locator("#profile-dialog.as-tab")).to_be_visible()
        await expect(ana.locator("#profile-name")).to_have_text(ANA)
        await expect(ana.locator("#profile-sign-out")).to_be_visible()
        await expect(ana.locator("#profile-admin-link")).to_be_hidden()
        await expect(ana.locator("#profile-dialog [data-close]")).to_be_hidden()
        await expect(ana.locator("#tab-profile")).to_have_attribute("aria-current", "page")
        box = await ana.locator("#profile-dialog").bounding_box()
        tabs = await ana.locator("#tabs").bounding_box()
        assert box["y"] == 0 and box["width"] == 390 and box["y"] + box["height"] <= tabs["y"] + 1, (box, tabs)
        await shot(ana, "tabs-profile-phone", full_page=False)
        await ana.click("#tab-chats")
        await expect(ana.locator("#profile-dialog")).to_be_hidden()
        await expect(ana.locator("#tab-chats")).to_have_attribute("aria-current", "page")
        print("profile tab shows your profile above the tabs; Chats goes back")

        # Camera tab: take a pic, then pick who it's for.
        await ana.click("#tab-camera")
        await expect(ana.locator("#camera-dialog")).to_be_visible()
        await expect(ana.locator("#tab-camera")).to_have_attribute("aria-current", "page")
        await ana.evaluate(PICK_IMAGE)
        await expect(ana.locator("#send-snap")).to_have_text("Send to…", timeout=10000)
        await ana.locator(".camera-stage").click(position={"x": 195, "y": 300})  # a tap on the picture places a caption
        await ana.fill("#snap-caption", "summit")
        await ana.click("#send-snap")
        await expect(ana.locator("#send-to-dialog")).to_be_visible()
        # The list has room for its rows (Safari once drew it with no height at all).
        listed = await ana.locator("#send-to-list").bounding_box()
        assert listed["height"] >= 3 * 40, listed
        assert await ana.locator("#send-to-list").evaluate("e => getComputedStyle(e).flexBasis") == "auto"
        names = await ana.locator("#send-to-list .send-to-name > span:first-child").all_text_contents()
        assert sorted(names) == sorted([BEN, CAL, GROUP]), names
        await expect(ana.locator("#send-to-go")).to_be_disabled()
        await expect(ana.locator("#send-to-picked")).to_have_text("Pick one or more.")
        await ana.fill("#send-to-search", "hike")
        await expect(ana.locator("#send-to-list label")).to_have_count(1)
        await pick(ana, GROUP).check()
        await ana.fill("#send-to-search", "")
        await pick(ana, BEN).check()
        await expect(ana.locator("#send-to-go")).to_have_text("Send to 2")
        await expect(ana.locator("#send-to-picked")).to_have_text(f"{GROUP} and {BEN}")  # in the list's order
        await shot(ana, "send-to-phone", full_page=False)

        # The group's copy fails (the connection drops); Ben's goes.
        async def down(route):
            await route.abort()
        await ana.route("**/api/groups/*/pics*", down)
        await ana.click("#send-to-go")
        await expect(ana.locator("#camera-message")).to_have_text(
            f"Sent to {BEN}. Couldn't send to {GROUP}. The connection dropped: tap Send to try again.", timeout=60000)
        await expect(ana.locator("#send-snap")).to_have_text("Send to 2")
        await ana.unroute("**/api/groups/*/pics*", down)
        # Send again: only the group gets it now.
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).to_be_hidden(timeout=20000)
        await expect(ana.locator("#toast-text")).to_have_text(f"Pic sent to {GROUP} and {BEN}.")
        await expect(ana.locator("#tab-chats")).to_have_attribute("aria-current", "page")
        print("sent to a friend and a group; a failed one goes on Send again")

        # Ben got one pic in his chat with Ana, and one in the group, with the caption sealed in.
        await row(ben, ANA).click()
        await expect(ben.locator("button.snap-chip")).to_have_count(1, timeout=15000)
        await asyncio.sleep(1)
        await expect(ben.locator("button.snap-chip")).to_have_count(1)  # never twice
        await row(ben, GROUP).click()
        await expect(ben.locator("button.snap-chip", has_text="Tap to view pic")).to_have_count(1, timeout=15000)
        await ben.locator("button.snap-chip").click()
        await expect(ben.locator("#viewer-caption")).to_have_text("summit", timeout=15000)
        # Cal wasn't picked: nothing for him.
        await row(cal, ANA).click()
        await expect(cal.locator("#messages")).to_contain_text("No messages yet.", timeout=10000)
        print("each recipient got one copy; no one else did")

        # In a chat, the camera still sends straight to that chat.
        await ana.click("#tab-chats")
        await row(ana, CAL).click()
        await ana.click("#camera-button")
        await ana.evaluate(PICK_IMAGE)
        await expect(ana.locator("#send-who")).to_have_text(f"To {CAL} +", timeout=10000)
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).to_be_hidden(timeout=20000)
        await expect(cal.locator("button.snap-chip")).to_have_count(1, timeout=15000)
        # A computer's camera button works the same as the tab.
        await ben.click("#list-camera")
        await ben.evaluate(PICK_IMAGE)
        await expect(ben.locator("#send-snap")).to_have_text("Send to…", timeout=10000)
        await ben.click("#send-snap")
        await pick(ben, CAL).check()
        await shot(ben, "send-to-desktop", full_page=False)
        await ben.click("#send-to-go")
        await expect(ben.locator("#toast-text")).to_have_text(f"Pic sent to {CAL}.", timeout=20000)

        # Signing out from the Profile tab.
        await ana.click("#back-button")
        await ana.click("#tab-profile")
        await ana.click("#profile-sign-out")
        await expect(ana.locator("#auth")).to_be_visible(timeout=10000)
        await expect(ana.locator("#profile-dialog")).to_be_hidden()

        assert not errors, errors
        await browser.close()
    print("TABS TEST PASSED")


asyncio.run(main())
