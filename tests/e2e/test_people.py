"""Lists of people (X45, X46, X47, X48): a group's members and the friends to
add, friend requests both ways, the new-group picker, a profile's friends,
and Profile › Blocked each show every person's picture (a friend's; anyone
else keeps the initial, since pictures go only to friends), the name I know
them by with @username beside it when that differs, and open their profile
on a tap. Someone who isn't my friend gets what I may see: their username,
and adding, reporting, or blocking them. In the chat list, a row's picture
opens the chat like the rest of the row. What the server sends to whom is
the smoke test's (check_profiles, check_blocks). Settings come from the
environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import PHONE, api, befriend, launch, no_placeholders, row, shot, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL, DEE = f"ppl_ana_{tag}", f"ppl_ben_{tag}", f"ppl_cal_{tag}", f"ppl_dee_{tag}"
# Ben's display name, as long as one can be: lists end it in "…" rather than spill.
LONG = "Benjamin Alexander Thistlewood"
GROUP = f"Picnic {tag}"
DESKTOP = {"viewport": {"width": 1200, "height": 800}}
errors = []

# A profile picture, set through the API (the profile's own picker is test_profile.py's).
SET_PICTURE = """async () => {
  const c = document.createElement('canvas'); c.width = 200; c.height = 200;
  const g = c.getContext('2d'); g.fillStyle = '#c84'; g.fillRect(0, 0, 200, 200);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const r = await fetch('/api/me/avatar', { method: 'POST', body: blob,
    headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token'), 'Content-Type': 'image/png' } });
  return r.status;
}"""


def member(page, name):
    return page.locator("#group-members .person", has_text=name)


async def open_group_info(page):
    await page.locator(".chat-item.is-group", has_text=GROUP).click()
    await expect(page.locator("#chat-title")).to_have_text(GROUP, timeout=10000)
    await page.click("#chat-title")
    await expect(page.locator("#group-dialog")).to_be_visible()


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, label="ana", **DESKTOP)
        ben = await sign_up(browser, BEN, errors=errors, label="ben", **DESKTOP)
        cal = await sign_up(browser, CAL, errors=errors, label="cal", **PHONE)
        dee = await sign_up(browser, DEE, errors=errors, label="dee", **DESKTOP)
        await befriend(ana, ben, BEN, ANA)
        await befriend(ben, cal, CAL, BEN)
        ben_id = (await api(ben, "GET", "/me"))["id"]
        cal_id = (await api(cal, "GET", "/me"))["id"]
        ana_id = (await api(ana, "GET", "/me"))["id"]
        # Ben names himself and adds a picture; Cal calls him "Benny".
        await api(ben, "PUT", "/me/name", {"name": LONG})
        assert await ben.evaluate(SET_PICTURE) == 200
        await api(cal, "PUT", f"/friends/{ben_id}/nickname", {"name": "Benny"})
        # Ben makes a group of the three: Ana and Cal aren't friends.
        await api(ben, "POST", "/groups", {"name": GROUP, "member_ids": [ana_id, cal_id]})

        # X48: in the chat list, Ben's picture opens his chat, not his profile.
        ben_row = row(ana, LONG)
        await expect(ben_row.locator(".avatar img")).to_be_visible(timeout=10000)
        await ben_row.locator(".avatar").click()
        await expect(ana.locator("#chat-title")).to_have_text(LONG, timeout=10000)
        await expect(ana.locator("#profile-dialog")).to_be_hidden()
        print("chat list: a row's picture opens the chat")

        # X45, X47: the group's members, each with a picture or initial, named as Ana knows them.
        await open_group_info(ana)
        await expect(ana.locator("#group-members .person")).to_have_count(3, timeout=10000)
        await expect(member(ana, BEN).locator(".person-name")).to_have_text(LONG)
        await expect(member(ana, BEN).locator(".person-meta")).to_have_text(f"@{BEN}")
        await expect(member(ana, BEN).locator(".avatar img")).to_be_visible(timeout=10000)
        await expect(member(ana, BEN).locator(".role-badge")).to_have_text("Owner")
        await expect(member(ana, ANA).locator(".person-name")).to_have_text(f"{ANA} (you)")
        cal_row = member(ana, CAL)
        await expect(cal_row.locator(".person-name")).to_have_text(CAL)
        await expect(cal_row.locator(".person-meta")).to_have_count(0)  # the name is the username
        await expect(cal_row.locator(".avatar")).to_have_text(CAL[0].upper())
        await expect(cal_row.locator(".avatar img")).to_have_count(0)  # not a friend: no picture
        await expect(cal_row.locator("button", has_text="Add friend")).to_be_visible()
        await no_placeholders(ana, "#group-dialog")
        await shot(ana, "people-group-info-desktop", full_page=False)
        print("group members: pictures for friends, initials otherwise, names as Ana knows them")

        # X46: a tap on someone who isn't her friend: what she may see of them.
        await cal_row.locator(".person-open").click()
        await expect(ana.locator("#group-dialog")).to_be_hidden()
        await expect(ana.locator("#profile-name")).to_have_text(CAL)
        await expect(ana.locator("#profile-sub")).to_have_text(f"@{CAL} · not your friend")
        await expect(ana.locator("#profile-message")).to_have_text("Only friends see each other's profiles, pictures, and names.")
        await expect(ana.locator("#profile-safety button")).to_have_text(["Report", "Block"])
        await expect(ana.locator("#profile-stats")).to_be_empty()
        await no_placeholders(ana, "#profile-dialog")
        await shot(ana, "people-stranger-desktop", full_page=False)
        await ana.locator("#profile-actions button", has_text="Add friend").click()
        await expect(ana.locator("#profile-actions")).to_have_text("Friend request sent", timeout=10000)
        await expect(ana.locator("#profile-edit-note")).to_have_text(f"Request sent to {CAL}.")
        await ana.click("#profile-dialog [data-close]")

        # ...and a friend's opens their profile.
        await open_group_info(ana)
        await member(ana, BEN).locator(".person-open").click()
        await expect(ana.locator("#profile-name")).to_have_text(LONG, timeout=10000)
        await expect(ana.locator("#profile-actions button")).to_have_text(f"Message {LONG}")
        await expect(ana.locator("#profile-people .person-name")).to_have_count(0)
        await ana.click("#profile-dialog [data-close]")
        print("group members open their profiles: a friend's in full, anyone else's as far as allowed")

        # Waiting on them: Cal, with his initial, opens the same way.
        await ana.click("#friends-button")
        waiting = ana.locator("#outgoing-list .person", has_text=CAL)
        await expect(waiting.locator(".avatar")).to_have_text(CAL[0].upper())
        await expect(waiting.locator("button.button")).to_have_text("Cancel request")
        await ana.click("#friends-dialog [data-close]")

        # The new-group picker: Ben's picture, name and @username. A tap picks him.
        await ana.click("#start-button")
        pick = ana.locator("#new-group-friends .person", has_text=LONG)
        await expect(pick.locator(".person-meta")).to_have_text(f"@{BEN}")
        await expect(pick.locator(".avatar img")).to_be_visible(timeout=10000)
        await pick.locator(".person-name").click()
        await expect(pick.locator("input")).to_be_checked()
        await expect(ana.locator("#profile-dialog")).to_be_hidden()
        await shot(ana, "people-new-group-desktop", full_page=False)
        await ana.click("#new-group-dialog [data-close]")
        print("new-group picker: pictures and @usernames; a tap picks")

        # Cal, on a phone: Ana's request, opened from the list, accepted from her profile.
        await cal.click("#friends-button")
        asking = cal.locator("#incoming-list .person", has_text=ANA)
        await expect(asking.locator(".avatar")).to_have_text(ANA[0].upper(), timeout=10000)
        await shot(cal, "people-requests-phone", full_page=False)
        await asking.locator(".person-open").click()
        await expect(cal.locator("#friends-dialog")).to_be_hidden()
        await expect(cal.locator("#profile-name")).to_have_text(ANA)
        await shot(cal, "people-stranger-phone", full_page=False)
        await cal.locator("#profile-actions button", has_text="Accept friend request").click()
        await expect(cal.locator("#profile-sub")).to_contain_text("friends since", timeout=10000)
        await expect(cal.locator("#profile-actions button")).to_have_text(f"Message {ANA}")
        await no_placeholders(cal, "#profile-dialog")
        await cal.click("#profile-dialog [data-close]")
        print("requests: a tap opens who's asking; accepting from there makes friends")

        # Cal's view of the group: Ben by her nickname for him, Ana a friend now.
        await expect(row(cal, "Benny")).to_be_visible(timeout=10000)
        await open_group_info(cal)
        await expect(member(cal, BEN).locator(".person-name")).to_have_text("Benny")
        await expect(member(cal, BEN).locator(".person-meta")).to_have_text(f"@{BEN}")
        await expect(member(cal, BEN).locator(".avatar img")).to_be_visible(timeout=10000)
        await expect(member(cal, ANA).locator("button", has_text="Add friend")).to_have_count(0, timeout=10000)
        await no_placeholders(cal, "#group-dialog")
        await shot(cal, "people-group-info-phone", full_page=False)
        await member(cal, BEN).locator(".avatar").click()
        await expect(cal.locator("#profile-name")).to_have_text("Benny", timeout=10000)
        await expect(cal.locator("#profile-sub")).to_contain_text(f"@{BEN} · goes by “{LONG}”")
        await cal.click("#profile-dialog [data-close]")
        print("nicknames win, with @username beside them")

        # Dee asks Ana; Ana opens Dee from the request and blocks her there.
        await dee.click("#friends-button")
        await dee.fill("#add-friend-form input[name=username]", ANA)
        await dee.click("#add-friend-form button[type=submit]")
        await expect(dee.locator("#add-friend-note")).to_contain_text("Request sent", timeout=10000)
        await ana.click("#friends-button")
        await ana.locator("#incoming-list .person", has_text=DEE).locator(".person-open").click()
        await expect(ana.locator("#profile-actions button")).to_have_text("Accept friend request")
        await ana.locator("#profile-safety button", has_text="Block").click()
        await ana.click("#block-confirm")
        await expect(ana.locator("#profile-dialog")).to_be_hidden(timeout=10000)

        # Profile › Blocked: Dee, with her initial, opens to what Ana knows: Report only.
        await ana.click("#my-profile")
        blocked = ana.locator("#blocked-list .person", has_text=DEE)
        await expect(blocked.locator(".person-meta")).to_have_text("Blocked today", timeout=10000)
        await expect(blocked.locator(".avatar")).to_have_text(DEE[0].upper())
        await blocked.locator(".person-open").click()
        await expect(ana.locator("#profile-name")).to_have_text(DEE)
        await expect(ana.locator("#profile-sub")).to_have_text(f"@{DEE} · you block them")
        await expect(ana.locator("#profile-safety button")).to_have_text(["Report"])
        await expect(ana.locator("#profile-actions")).to_be_empty()
        await expect(ana.locator("#profile-account")).to_be_hidden()
        print("blocked: a picture or initial, and their profile as far as allowed")

        # Narrow: long names end in "…" and nothing spills sideways.
        await ana.click("#profile-dialog [data-close]")
        await open_group_info(ana)
        await ana.set_viewport_size({"width": 390, "height": 844})
        await expect(member(ana, BEN).locator(".person-name")).to_have_css("text-overflow", "ellipsis")
        width = await ana.evaluate("document.querySelector('#group-dialog').scrollWidth - document.querySelector('#group-dialog').clientWidth")
        assert width <= 0, f"the group sheet scrolls sideways by {width}px"
        await shot(ana, "people-group-info-390", full_page=False)

        assert not errors, errors
        await browser.close()
    print("PEOPLE TEST PASSED")


asyncio.run(main())
