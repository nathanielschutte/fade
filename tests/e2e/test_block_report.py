"""Report and Block in the web app (docs/design/report-and-block.md, F28):
reporting a text in a direct chat and a message in a group from its menu
(ids only reach the server, never what it said), reporting a person and
blocking them from their profile (the friendship ends on both sides, live,
and their friend request then gets the answer a username nobody has gets),
Profile › Blocked and Unblock, and links in texts: one to the app's own site
that opens a chat or group (Team Napsack's warnings link to a message) is an
in-app link that opens at that message; every other link stays plain text.
What the API allows and refuses is the smoke test's (check_reports,
check_blocks); System › Reports is test_reports.py's. Settings come from the
environment; see common.py."""
import asyncio, json, uuid
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, PHONE, api, befriend, launch, no_placeholders, open_page, row, shot, sign_up, sign_up_or_in, swipe

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"blk_ana_{tag}", f"blk_ben_{tag}"
GROUP = f"Lake day {tag}"
TEXT = f"meet me at nine {tag}"
GROUP_TEXT = f"who brings the boat {tag}"
# The reporter's note is the reporter's own words, kept as text, never HTML.
NOTE = f"<img src=x onerror=window.pwned=1> kept at it {tag}"
DESKTOP = {"viewport": {"width": 1200, "height": 800}}
errors = []


def group_item(page):
    return page.locator(".chat-item.is-group", has_text=GROUP)


async def send(page, text):
    """Sends a text in the open chat (the button, as a phone does)."""
    await page.fill("#composer-input", text)
    await page.click("#composer button[type=submit]")
    await expect(page.locator(".msg", has_text=text.splitlines()[0]).last).to_be_visible(timeout=10000)
    # Stored, not still going: a message on its way has no menu of its own yet.
    await expect(page.locator(".msg.pending")).to_have_count(0, timeout=10000)


async def menu(page, text):
    """Taps a message open: its row of reactions and actions."""
    await page.locator(".msg", has_text=text).click()
    return page.locator(".msg-actions")


async def report_it(page, reason, note=""):
    dialog = page.locator("#report-dialog")
    await dialog.locator(".report-reason", has_text=reason).click()
    if note:
        await page.fill("#report-note", note)
    await page.click("#report-submit")
    await expect(page.locator("#report-done")).to_be_visible(timeout=10000)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, label="ana", **DESKTOP)
        ben = await sign_up(browser, BEN, errors=errors, label="ben", **PHONE)
        await befriend(ana, ben, BEN, ANA)
        # The new group's friend picker lists the friends Ana's app knows of when it opens.
        await expect(row(ana, BEN)).to_be_visible(timeout=10000)

        # A group of the two of them (it stays after a block), and a text in each.
        await ana.click("#start-button")
        await ana.fill("#new-group-name", GROUP)
        await ana.locator("#new-group-friends label", has_text=BEN).locator("input").check()
        await ana.click("#new-group-submit")
        await expect(ana.locator("#chat-title")).to_have_text(GROUP, timeout=10000)
        await group_item(ben).click()
        await send(ben, GROUP_TEXT)
        target = ana.locator(".msg", has_text=GROUP_TEXT)
        await expect(target).to_be_visible(timeout=10000)
        gid = next(g["id"] for g in await api(ana, "GET", "/groups") if g["name"] == GROUP)
        mid = int((await target.get_attribute("data-key")).split(":")[1])
        # A long message after it, so the group opens with it out of view.
        await send(ben, "\n".join(f"line {i}" for i in range(60)))
        await ben.click("#back-button")
        await row(ben, ANA).locator(".chat-item").click()
        await send(ben, TEXT)
        own = f"{BASE}/#group={gid}&message={mid}"
        await send(ben, f"look {own}. and https://example.com/#group={gid}&message={mid} or {BASE}/admin#group={gid} <b>x</b>")
        # On a phone, a chat's actions are behind a swipe: Block is the last of them.
        await ben.click("#back-button")
        await swipe(ben, row(ben, ANA), -320)
        await expect(row(ben, ANA).locator(".row-action", has_text="Block")).to_be_in_viewport()
        await shot(ben, "chat-row-actions-phone", full_page=False)
        await row(ben, ANA).locator(".chat-item").tap()  # closes the swiped row

        # Ana reports Ben's text from its menu: what's said, a reason, a note.
        await row(ana, BEN).locator(".chat-item").click()
        await expect(ana.locator(".msg", has_text=TEXT)).to_be_visible(timeout=10000)
        actions = await menu(ana, TEXT)
        await actions.locator("button", has_text="Report").click()
        await expect(ana.locator("#report-title")).to_have_text("Report this text")
        await expect(ana.locator("#report-text")).to_have_text(
            "An Admin will look at it. They'll see who sent it and when, but never what it said.")
        await expect(ana.locator("#report-dialog")).to_contain_text("Please don't paste the message here.")
        await expect(ana.locator("#report-dialog .report-reason")).to_have_count(6)
        await ana.click("#report-submit")  # no reason yet
        await expect(ana.locator("#report-error")).to_have_text("Choose why you're reporting it.")
        await shot(ana, "report-text-desktop", full_page=False)
        await ana.set_viewport_size({"width": 390, "height": 844})
        await shot(ana, "report-text-phone", full_page=False)
        await ana.set_viewport_size(DESKTOP["viewport"])
        await report_it(ana, "Harassment or bullying", NOTE)
        await expect(ana.locator("#report-done-text")).to_contain_text("Report sent.")
        await expect(ana.locator("#report-block")).to_have_text(f"Block @{BEN}")
        await shot(ana, "report-sent-desktop", full_page=False)
        await ana.locator("#report-done button", has_text="Done").click()
        await expect(ana.locator("#report-dialog")).to_be_hidden()
        # Her own messages have no Report.
        await send(ana, f"ok {tag}")
        actions = await menu(ana, f"ok {tag}")
        await expect(actions.locator("button", has_text="Reply")).to_be_visible()
        await expect(actions.locator("button", has_text="Report")).to_have_count(0)

        # Links: the one to this site's group is an in-app link; the rest stay text.
        links = ana.locator("#messages a")
        await expect(links).to_have_count(1)
        await expect(links).to_have_text(own)
        await expect(links).to_have_attribute("href", f"#group={gid}&message={mid}")
        await expect(ana.locator(".msg", has_text="https://example.com/")).to_contain_text("<b>x</b>")
        await expect(ana.locator("#messages b")).to_have_count(0)

        # The group opens at its newest, with the message out of view; the link opens it there.
        await group_item(ana).click()
        await expect(ana.locator(".msg", has_text="line 59")).to_be_in_viewport(timeout=10000)
        await expect(target).not_to_be_in_viewport()
        await row(ana, BEN).locator(".chat-item").click()
        await links.click()
        await expect(ana.locator("#chat-title")).to_have_text(GROUP, timeout=10000)
        await expect(target).to_be_in_viewport(timeout=10000)

        # Ana reports Ben's group message; then she's offered to block him.
        actions = await menu(ana, GROUP_TEXT)
        await actions.locator("button", has_text="Report").click()
        await expect(ana.locator("#report-title")).to_have_text("Report this text")
        await report_it(ana, "Spam")
        await ana.click("#report-block")
        await expect(ana.locator("#block-dialog")).to_be_visible()
        await expect(ana.locator("#block-title")).to_have_text(f"Block @{BEN}?")
        await ana.locator("#block-dialog button", has_text="Cancel").click()
        await expect(ana.locator("#block-dialog")).to_be_hidden()

        # A link to a message, as Team Napsack's warnings carry, opening the app.
        await ana.goto("about:blank")
        await ana.goto(own)
        await expect(ana.locator("#chat-title")).to_have_text(GROUP, timeout=15000)
        await expect(target).to_be_in_viewport(timeout=10000)
        assert "#" not in ana.url, ana.url  # the link is used up
        await shot(ana, "link-opened-desktop", full_page=False)

        # The Admin sees both reports and the note, as text, and never what was said.
        admin = await open_page(browser, errors, "admin", **DESKTOP)
        await sign_up_or_in(admin, ADMIN)
        listed = [r for r in (await api(admin, "GET", "/admin/reports"))["reports"] if r["reporter"]["username"] == ANA]
        assert sorted(r["kind"] for r in listed) == ["group_message", "message"], listed
        text_report = next(r for r in listed if r["kind"] == "message")
        assert text_report["note"] == NOTE and text_report["reason"] == "harassment", text_report
        assert text_report["reported"]["username"] == BEN and text_report["message"]["kind"] == "text", text_report
        group_report = next(r for r in listed if r["kind"] == "group_message")
        assert group_report["group"]["id"] == gid and group_report["message"]["id"] == mid, group_report
        said = json.dumps(listed)
        for words in (TEXT, GROUP_TEXT, "line 59"):
            assert words not in said, f"a report holds what was said: {words}"
        await admin.goto(f"{BASE}/admin#reports={text_report['id']}")
        await expect(admin.locator(f"#report-{text_report['id']}")).to_contain_text(NOTE, timeout=10000)
        assert await admin.evaluate("window.pwned") is None, "the note is text, not HTML"

        # The chat's own actions in the list (hover here; a swipe on a phone) have Block too.
        await row(ana, BEN).hover()
        await shot(ana, "chat-row-actions-desktop", full_page=False)
        await row(ana, BEN).get_by_role("button", name=f"Block {BEN}").click()
        await expect(ana.locator("#block-title")).to_have_text(f"Block @{BEN}?")
        await ana.locator("#block-dialog button", has_text="Cancel").click()
        await expect(ana.locator("#block-dialog")).to_be_hidden()

        # From Ben's profile: Report (as a person), then Block.
        await row(ana, BEN).locator(".chat-item").click()
        await ana.click("#chat-title")
        await expect(ana.locator("#profile-safety button", has_text="Block")).to_be_visible(timeout=10000)
        await ana.locator("#profile-safety button", has_text="Report").click()
        await expect(ana.locator("#report-title")).to_have_text(f"Report @{BEN}")
        await report_it(ana, "Something else")
        await ana.locator("#report-done button", has_text="Done").click()
        await ana.locator("#profile-safety button", has_text="Block").click()
        await expect(ana.locator("#block-dialog")).to_contain_text("They aren't told.")
        await expect(ana.locator("#block-dialog")).to_contain_text("Groups you're both in stay as they are.")
        await shot(ana, "block-desktop", full_page=False)
        await ana.set_viewport_size({"width": 390, "height": 844})
        await shot(ana, "block-phone", full_page=False)
        await ana.set_viewport_size(DESKTOP["viewport"])
        await ana.click("#block-confirm")
        await expect(ana.locator("#block-dialog")).to_be_hidden(timeout=10000)
        await expect(ana.locator("#profile-dialog")).to_be_hidden()
        await expect(ana.locator("#toast-text")).to_have_text(f"Blocked @{BEN}.")
        # The friendship ends on both sides, live; the group stays, his message in it too.
        await expect(row(ana, BEN)).to_have_count(0, timeout=10000)
        await expect(row(ben, ANA)).to_have_count(0, timeout=10000)
        await expect(group_item(ben)).to_be_visible()
        await group_item(ana).click()
        await expect(target).to_be_visible(timeout=10000)

        # To Ben, asking Ana to be friends looks like asking nobody.
        await ben.click("#friends-button")
        await ben.fill("#add-friend-form input[name=username]", f"nobody_{tag}")
        await ben.click("#add-friend-form button[type=submit]")
        await expect(ben.locator("#add-friend-note")).not_to_be_empty(timeout=10000)
        nobody = await ben.locator("#add-friend-note").text_content()
        await ben.fill("#add-friend-form input[name=username]", "")
        await ben.evaluate("document.querySelector('#add-friend-note').textContent = ''")
        await ben.fill("#add-friend-form input[name=username]", ANA)
        await ben.click("#add-friend-form button[type=submit]")
        await expect(ben.locator("#add-friend-note")).to_have_text(nobody, timeout=10000)

        # Profile › Blocked lists him; Unblock asks first, then he's off the list.
        await ana.click("#my-profile")
        blocked = ana.locator("#blocked-list .person", has_text=f"@{BEN}")
        await expect(blocked).to_contain_text("Blocked today", timeout=10000)
        await no_placeholders(ana, "#profile-dialog")
        await blocked.scroll_into_view_if_needed()
        await shot(ana, "blocked-list-desktop", full_page=False)
        await blocked.locator("button", has_text="Unblock").click()
        await expect(blocked.locator("button")).to_have_text("Tap again to unblock")
        await expect(ana.locator("#blocked-note")).to_contain_text("You stay unfriended")
        await ana.set_viewport_size({"width": 390, "height": 844})
        await blocked.scroll_into_view_if_needed()
        await shot(ana, "blocked-list-phone", full_page=False)
        await ana.set_viewport_size(DESKTOP["viewport"])
        await blocked.locator("button").click()
        await expect(ana.locator("#blocked-list")).to_have_text("You haven't blocked anyone.", timeout=10000)
        await expect(ana.locator("#blocked-note")).to_contain_text(f"Unblocked @{BEN}. You're not friends")
        # Unblocked: his request reaches her now.
        await ben.click("#add-friend-form button[type=submit]")
        await expect(ben.locator("#add-friend-note")).to_have_text(f"Request sent to {ANA}.", timeout=10000)

        for p in (ana, ben, admin):
            assert await p.evaluate("window.pwned") is None
        assert not errors, errors
        await browser.close()
    print("BLOCK AND REPORT TEST PASSED")


asyncio.run(main())
