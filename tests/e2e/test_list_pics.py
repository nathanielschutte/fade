"""Pics straight from the chat list (X41): a tap on a chat whose newest
message is a pic or video waiting from them shows the chat's waiting pics,
back to back, without opening the chat, and leaves you on the list. A text
of theirs from before stays unread; a group is read after only if its pics
were all that was unread; a double tap still opens the camera; and pics
opened elsewhere meanwhile make the tap open the chat instead.
Settings come from the environment; see common.py."""
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
    for i in range(count):
        await expect(viewer).to_be_visible(timeout=10000)
        await expect(page.locator("#viewer-hint")).to_have_text(
            "Tap for the next one" if i + 1 < count else "Tap to close", timeout=10000)
        if count > 1:
            await expect(page.locator("#viewer-count")).to_have_text(f"{i + 1} of {count}")
        else:
            await expect(page.locator("#viewer-count")).to_be_hidden()
        # The list stays as it was underneath: no chat opened.
        await expect(page.locator("#app")).not_to_have_class(IN_CHAT)
        await asyncio.sleep(0.7)  # a tap right as a pic appears is ignored (TAP_GUARD_MS)
        await tap(viewer)
    await expect(viewer).to_be_hidden()


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
        # and he's on the list after, with nothing waiting.
        await row(ana, BEN).click()
        await send_pics(ana, 2)
        ben_row = row(ben, ANA)
        await expect(ben_row.locator(".chat-status")).to_have_text("New pic", timeout=10000)
        # Said to screen readers, which can't see that a tap won't open the chat.
        await expect(ben_row.locator(".chat-hint")).to_have_text("Opens the pic, not the chat")
        await ben_row.tap()
        await expect(ben.locator("#viewer-count")).to_have_text("1 of 2", timeout=10000)
        await expect(ben.locator("#viewer-hint")).to_have_text("Tap for the next one", timeout=10000)
        await shot(ben, "list-pics-viewer-phone", full_page=False)
        await view(ben, 2, tap)
        await expect(ben.locator("#app")).not_to_have_class(IN_CHAT)
        await expect(ben.locator("#chat")).to_be_hidden()
        await expect(ben_row.locator(".chat-status")).to_have_text("Pic viewed", timeout=10000)
        await expect(ben_row.locator(".chat-item")).not_to_have_class(UNREAD, timeout=10000)
        await expect(ben_row.locator(".chat-hint")).to_have_text("")
        await no_placeholders(ben, "#viewer")
        await shot(ben, "list-pics-after-phone", full_page=False)
        print("two pics from the list, back to back; still on the list, nothing waiting")

        # A text, then a pic: the pic is shown; the text stays unread for the chat.
        await say(ana, f"before the pic {tag}")
        await send_pics(ana, 1)
        await expect(ben_row.locator(".chat-status")).to_have_text("New pic", timeout=10000)
        await ben_row.tap()
        await view(ben, 1, tap)
        await expect(ben_row.locator(".chat-status")).to_have_text("Pic viewed", timeout=10000)
        await expect(ben_row.locator(".chat-item")).to_have_class(UNREAD)
        await expect(ben_row.locator(".marker")).to_have_class(re.compile(r"\btext\b"))
        chats = await api(ben, "GET", "/friends")
        assert next(c for c in chats if c["id"] == ana_id)["unread"] == 1, chats
        # Opening the chat reads it.
        await ben_row.tap()
        await expect(ben.locator(".msg", has_text=f"before the pic {tag}")).to_be_visible(timeout=10000)
        await ben.click("#back-button")
        await expect(ben_row.locator(".chat-item")).not_to_have_class(UNREAD, timeout=10000)
        print("a text before the pic stays unread")

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
        pic = next(m for m in msgs if m["kind"] == "snap" and m["snap_state"] == "pending")

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

        # A group, on a computer: its pics from the list, and it's read after,
        # since they were all that was unread.
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
        await expect(cal.locator("#chat")).to_be_hidden()
        await expect(cal.locator("#chat-placeholder")).to_be_visible()
        await expect(cal_group.locator(".chat-item")).not_to_have_class(UNREAD, timeout=10000)
        groups = await api(cal, "GET", "/groups")
        assert next(g for g in groups if g["name"] == GROUP)["unread"] == 0, groups
        await shot(cal, "list-pics-after-desktop", full_page=False)
        print("a group's pics from the list; read after")

        # A text before the pic: the group stays unread. (From the keyboard
        # this time, which shows them at once.)
        await say(ana, f"group text {tag}")
        await send_pics(ana, 1)
        await expect(cal_group.locator(".chat-hint")).to_have_text("Opens the pic, not the chat", timeout=10000)
        await cal_group.locator(".chat-item").focus()
        await cal.keyboard.press("Enter")
        await view(cal, 1, click)
        await expect(cal_group.locator(".chat-status")).to_have_text(f"{ANA} sent a pic")
        await expect(cal_group.locator(".chat-item")).to_have_class(UNREAD)
        groups = await api(cal, "GET", "/groups")
        assert next(g for g in groups if g["name"] == GROUP)["unread"] == 2, groups
        print("a group text before the pic stays unread")

        # A double click on a group's pic row: the group, with the camera up.
        await send_pics(ana, 1)
        await expect(cal_group.locator(".chat-hint")).to_have_text("Opens the pic, not the chat", timeout=10000)
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
