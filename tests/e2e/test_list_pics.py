"""Pics straight from the chat list (X41): a tap on a chat whose newest
message is a pic or video waiting from them shows the chat's waiting pics,
back to back, over the list; when they're done the chat opens (X59), reading
what was unread there. Each counts as opened the moment it's shown, in the
list and the chat, before the server has heard (D27). A double tap still
opens the camera, and pics opened elsewhere meanwhile make the tap open the
chat straight away. Settings come from the environment; see common.py."""
import asyncio, re, uuid
from playwright.async_api import async_playwright, expect

from common import (BASE, PHONE, api, befriend, double_tap, launch, no_placeholders, row, send_pics,
                    shot, sign_up)

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
GROUP = f"trip {tag}"
errors = []

UNREAD = re.compile(r"\bhas-unread\b")
IN_CHAT = re.compile(r"\bin-chat\b")


async def view(page, count, tap):
    """Taps through the viewer's `count` pics, waiting for each to show
    (and past the tap guard, app.js), until it closes."""
    viewer = page.locator("#viewer")
    underneath = await page.locator("#app").get_attribute("class")
    for i in range(count):
        await expect(viewer).to_be_visible(timeout=10000)
        await expect(page.locator("#viewer-hint")).to_have_text(
            "Tap for the next one" if i + 1 < count else "Tap to close", timeout=10000)
        if count > 1:
            await expect(page.locator("#viewer-count")).to_have_text(f"{i + 1} of {count}")
        else:
            await expect(page.locator("#viewer-count")).to_be_hidden()
        # What's underneath stays as it was while they show: no chat opened yet.
        await expect(page.locator("#app")).to_have_class(underneath)
        await asyncio.sleep(0.7)  # a tap right as a pic appears is ignored (TAP_GUARD_MS)
        await tap(viewer)
    await expect(viewer).to_be_hidden()


async def group_read(page, name):
    """Waits for the server to have the group read: opening it reads it, a
    moment after it shows (and the page's CSP rules out wait_for_function)."""
    for _ in range(100):
        groups = await api(page, "GET", "/groups")
        if next(g for g in groups if g["name"] == name)["unread"] == 0:
            return
        await asyncio.sleep(0.1)
    raise AssertionError(f"{name} still unread: {groups}")


async def say(page, text):
    await page.fill("#composer-input", text)
    await page.press("#composer-input", "Enter")
    await expect(page.locator(".msg", has_text=text)).to_be_visible()


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, label="ana")
        ben = await sign_up(browser, BEN, errors=errors, label="ben", **PHONE)
        cal = await sign_up(browser, CAL, errors=errors, label="cal")
        await befriend(ana, ben, BEN, ANA)
        await befriend(ana, cal, CAL, ANA)
        ana_id = (await api(ana, "GET", "/me"))["id"]
        cal_id = (await api(cal, "GET", "/me"))["id"]
        tap = lambda loc: loc.tap()

        # Two pics from Ana: Ben's tap on her row shows both, back to back,
        # then her chat opens; back on the list, nothing waits.
        await row(ana, BEN).click()
        await send_pics(ana, 2)
        ben_row = row(ben, ANA)
        await expect(ben_row.locator(".chat-status")).to_have_text("New pic", timeout=10000)
        # Said to screen readers, which can't see that a tap won't open the chat.
        await expect(ben_row.locator(".chat-hint")).to_have_text("Opens the pic, then the chat")
        await ben_row.tap()
        await expect(ben.locator("#viewer-count")).to_have_text("1 of 2", timeout=10000)
        await expect(ben.locator("#viewer-hint")).to_have_text("Tap for the next one", timeout=10000)
        await shot(ben, "list-pics-viewer-phone", full_page=False)
        await view(ben, 2, tap)
        await expect(ben.locator("#app")).to_have_class(IN_CHAT)
        await expect(ben.locator("#chat-title")).to_have_text(ANA)
        await expect(ben.locator("button.snap-chip")).to_have_count(0)
        await shot(ben, "list-pics-then-chat-phone", full_page=False)
        await ben.click("#back-button")
        await expect(ben_row.locator(".chat-status")).to_have_text("Pic viewed", timeout=10000)
        await expect(ben_row.locator(".chat-item")).not_to_have_class(UNREAD, timeout=10000)
        await expect(ben_row.locator(".chat-hint")).to_have_text("")
        await no_placeholders(ben, "#viewer")
        await shot(ben, "list-pics-after-phone", full_page=False)
        print("two pics from the list, back to back, then the chat; nothing waiting")

        # A text, then a pic: the pic is shown, then the chat opens on the text, which is read.
        await say(ana, f"before the pic {tag}")
        await send_pics(ana, 1)
        await expect(ben_row.locator(".chat-status")).to_have_text("New pic", timeout=10000)
        await ben_row.tap()
        await view(ben, 1, tap)
        await expect(ben.locator(".msg", has_text=f"before the pic {tag}")).to_be_visible(timeout=10000)
        await ben.click("#back-button")
        await expect(ben_row.locator(".chat-status")).to_have_text("Pic viewed")
        await expect(ben_row.locator(".chat-item")).not_to_have_class(UNREAD, timeout=10000)
        print("a text before the pic: read in the chat that opens after")

        # The server doesn't hear it was opened (the confirmation can't get
        # through): the row and the chat say it was viewed all the same, at
        # once, and the chat doesn't offer it again (D27).
        await send_pics(ana, 1)
        await expect(ben_row.locator(".chat-status")).to_have_text("New pic", timeout=10000)
        confirms = re.compile(r"/api/snaps/\d+/opened$")
        await ben.route(confirms, lambda route: route.abort())
        await ben_row.tap()
        await view(ben, 1, tap)
        await expect(ben.locator("#chat-title")).to_have_text(ANA, timeout=10000)
        await expect(ben.locator("button.snap-chip")).to_have_count(0)
        msgs = await api(ben, "GET", f"/chats/{ana_id}/messages?limit=5")
        assert [m["snap_state"] for m in msgs if m["kind"] == "snap"][-1] == "pending", msgs  # the server hasn't heard
        await ben.click("#back-button")
        await expect(ben_row.locator(".chat-status")).to_have_text("Pic viewed")
        await expect(ben_row.locator(".chat-item")).not_to_have_class(UNREAD)
        await ben.unroute(confirms)
        print("shown is opened at once, before the server hears")

        # A double tap is still the chat with the camera up, and the pic waits.
        await send_pics(ana, 1)
        await expect(ben_row.locator(".chat-status")).to_have_text("New pic", timeout=10000)
        await double_tap(ben, ben_row)
        await expect(ben.locator("#camera-dialog")).to_be_visible(timeout=5000)
        await expect(ben.locator("#chat-title")).to_have_text(ANA)
        await expect(ben.locator("#viewer")).to_be_hidden()
        await ben.click("#camera-dialog [data-close]")
        await expect(ben.locator("button.snap-chip", has_text="Tap to view pic")).to_be_visible()
        await ben.click("#back-button")
        await expect(ben_row.locator(".chat-status")).to_have_text("New pic")
        print("a double tap opens the camera, the pic still unopened")

        # Opened on another device between the tap and the viewer: the server
        # refuses it, and the tap opens the chat instead.
        token = await ben.evaluate("localStorage.getItem('fade.token')")
        msgs = await api(ben, "GET", f"/chats/{ana_id}/messages?limit=10")
        # The newest: the one shown with blocked confirmations above may still be waiting on the server.
        pic = [m for m in msgs if m["kind"] == "snap" and m["snap_state"] == "pending"][-1]

        async def elsewhere(route):
            answer = await route.fetch()  # as it was: the pic still waiting
            opened = await ben.request.post(f"{BASE}/api/snaps/{pic['id']}/opened",
                                            headers={"Authorization": f"Bearer {token}"})
            assert opened.ok, opened.status
            await route.fulfill(response=answer)

        refused = []
        ben.on("response", lambda r: r.url.endswith(f"/api/snaps/{pic['id']}") and refused.append(r.status))
        messages = re.compile(rf"/api/chats/{ana_id}/messages\?limit=")
        await ben.route(messages, elsewhere, times=1)
        await ben_row.tap()
        await expect(ben.locator("#chat-title")).to_have_text(ANA, timeout=10000)
        await expect(ben.locator("#app")).to_have_class(IN_CHAT)
        await expect(ben.locator("#viewer")).to_be_hidden()
        assert refused == [410], refused  # it tried, and the server said it's gone
        await ben.unroute(messages)
        await expect(ben.locator("button.snap-chip")).to_have_count(0, timeout=10000)
        await ben.click("#back-button")
        print("opened elsewhere: the tap opens the chat")

        # A group, on a computer: its pics from the list, then the group, read.
        await api(ana, "POST", "/groups", {"name": GROUP, "member_ids": [cal_id]})
        ana_group, cal_group = row(ana, GROUP), row(cal, GROUP)
        await ana_group.click()
        await expect(ana.locator("#chat-title")).to_have_text(GROUP)
        await send_pics(ana, 2)
        await expect(cal_group.locator(".chat-status")).to_have_text(f"{ANA} sent a pic", timeout=10000)
        await expect(cal_group.locator(".chat-item")).to_have_class(UNREAD)
        click = lambda loc: loc.click()
        await cal_group.click()
        await expect(cal.locator("#viewer-from")).to_contain_text(GROUP, timeout=10000)
        await shot(cal, "list-pics-viewer-desktop", full_page=False)
        await view(cal, 2, click)
        await expect(cal.locator("#chat-title")).to_have_text(GROUP)
        await expect(cal.locator("#chat")).to_be_visible()
        await expect(cal_group.locator(".chat-item")).not_to_have_class(UNREAD, timeout=10000)
        await group_read(cal, GROUP)
        await shot(cal, "list-pics-after-desktop", full_page=False)
        print("a group's pics from the list, then the group, read")

        # A text before the pic: shown, then the group opens on the text. (From
        # the keyboard this time, which shows them at once; from another chat.)
        await row(cal, ANA).click()
        await expect(cal.locator("#chat-title")).to_have_text(ANA)
        await say(ana, f"group text {tag}")
        await send_pics(ana, 1)
        await expect(cal_group.locator(".chat-hint")).to_have_text("Opens the pic, then the chat", timeout=10000)
        await cal_group.locator(".chat-item").focus()
        await cal.keyboard.press("Enter")
        await view(cal, 1, click)
        await expect(cal.locator("#chat-title")).to_have_text(GROUP)
        await expect(cal.locator(".msg", has_text=f"group text {tag}")).to_be_visible(timeout=10000)
        await expect(cal_group.locator(".chat-item")).not_to_have_class(UNREAD, timeout=10000)
        await group_read(cal, GROUP)
        print("a group text before the pic: read in the group that opens after")

        # A double click on a group's pic row: the group, with the camera up.
        await send_pics(ana, 1)
        await row(cal, ANA).click()  # elsewhere, so the group's own row is what opens it
        await expect(cal.locator("#chat-title")).to_have_text(ANA)
        await expect(cal_group.locator(".chat-hint")).to_have_text("Opens the pic, then the chat", timeout=10000)
        await cal_group.dblclick()
        await expect(cal.locator("#camera-dialog")).to_be_visible(timeout=5000)
        await expect(cal.locator("#chat-title")).to_have_text(GROUP)
        await expect(cal.locator("#viewer")).to_be_hidden()
        await cal.click("#camera-dialog [data-close]")
        await expect(cal.locator("button.snap-chip", has_text="Tap to view pic")).to_be_visible()
        print("a double click opens the group's camera")

        assert not errors, errors
        await browser.close()
    print("LIST PICS TEST PASSED")


asyncio.run(main())
