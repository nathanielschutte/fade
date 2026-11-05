"""See who reacted (F21): a tap on a reaction under a message shows who
reacted with that emoji, and "All", every emoji on the message with who gave
it, each person with their picture and the name I know them by (X45, X47),
opening their profile on a tap (X46). A direct chat's reactions are opened in
the browser (they're end-to-end encrypted); a group's come from the server.
A reaction arriving while it's open shows in it, and a button there reacts
with the emoji shown or takes mine back. On a desktop it works from the
keyboard too. Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import PHONE, api, befriend, launch, no_placeholders, shot, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"who_ana_{tag}", f"who_ben_{tag}", f"who_cal_{tag}"
BENS_NAME = "Benjamin"
GROUP = f"Who reacted {tag}"
DESKTOP = {"viewport": {"width": 1200, "height": 800}}
THUMBS, HEART, LAUGH, FOX = "\U0001F44D", "❤️", "\U0001F602", "\U0001F98A"
errors = []


def pill(page, emoji):
    return page.locator("#messages .reaction", has_text=emoji)


def person(page, name):
    return page.locator("#reaction-people .person", has_text=name)


async def react_from_menu(page, text, emoji):
    """Taps a message open and reacts from its quick row."""
    await page.locator(".msg", has_text=text).click()
    await page.locator(f".msg-actions button[aria-label='React {emoji}']").click()
    await expect(page.locator(".msg-actions")).to_have_count(0)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, label="ana", **DESKTOP)
        ben = await sign_up(browser, BEN, errors=errors, label="ben", **DESKTOP)
        cal = await sign_up(browser, CAL, errors=errors, label="cal", **PHONE)
        await befriend(ana, ben, BEN, ANA)
        await befriend(ana, cal, CAL, ANA)
        ben_id = (await api(ben, "GET", "/me"))["id"]
        cal_id = (await api(cal, "GET", "/me"))["id"]
        await api(ben, "PUT", "/me/name", {"name": BENS_NAME})

        # A direct chat: Ben writes, they both react, each with their own emoji.
        await ana.locator(".chat-item", has_text=BENS_NAME).click()
        await ben.locator(".chat-item", has_text=ANA).click()
        await ben.fill("#composer-input", "lunch at noon?")
        await ben.press("#composer-input", "Enter")
        await expect(ana.locator(".msg", has_text="lunch at noon?")).to_be_visible(timeout=10000)
        await react_from_menu(ana, "lunch at noon?", THUMBS)
        await react_from_menu(ben, "lunch at noon?", HEART)
        await expect(pill(ana, HEART)).to_be_visible(timeout=10000)
        # The pills still name who reacted (X49), and say a tap shows them.
        await expect(pill(ana, THUMBS)).to_have_attribute("title", "You")
        await expect(pill(ana, HEART)).to_have_attribute("title", BENS_NAME)
        await expect(pill(ana, HEART)).to_have_attribute("aria-label", f"{HEART} from {BENS_NAME}. Shows who reacted")

        # A tap shows who reacted with that one; it doesn't react.
        await pill(ana, HEART).click()
        sheet = ana.locator("#reactions-dialog")
        await expect(sheet).to_be_visible()
        tabs = ana.locator("#reaction-tabs .reaction-tab")
        await expect(tabs).to_have_text([f"All2", f"{THUMBS}1", f"{HEART}1"])
        await expect(tabs.nth(2)).to_have_attribute("aria-pressed", "true")
        await expect(ana.locator("#reaction-people .person")).to_have_count(1)
        await expect(person(ana, BENS_NAME).locator(".person-name")).to_have_text(BENS_NAME)
        await expect(person(ana, BENS_NAME).locator(".person-meta")).to_have_text(f"@{BEN}")
        await expect(ana.locator("#reaction-mine")).to_have_text(f"React {HEART} instead")
        await expect(ana.locator("#messages .reaction.is-mine")).to_have_text([THUMBS])  # still mine
        await expect(ana.locator("#reactions-privacy")).to_have_text("End-to-end encrypted: only the two of you can see these.")
        await no_placeholders(ana, "#reactions-dialog")
        await shot(ana, "who-reacted-direct-desktop", full_page=False)

        # All: everyone, each with their emoji, me first.
        await tabs.nth(0).click()
        await expect(ana.locator("#reaction-people .person .person-name")).to_have_text([f"{ANA} (you)", BENS_NAME])
        await expect(ana.locator("#reaction-people .reaction-of")).to_have_text([THUMBS, HEART])
        await expect(ana.locator("#reaction-mine")).to_have_text(f"Take back your {THUMBS}")
        print("direct chat: a tap shows who reacted with it, and All with every emoji")

        # Live: Ben's changes to a 👍 while it's open; the ❤️ goes, and the 👍 has two.
        await react_from_menu(ben, "lunch at noon?", THUMBS)
        await expect(tabs).to_have_text([f"All2", f"{THUMBS}2"], timeout=10000)
        await expect(ana.locator("#reaction-people .reaction-of")).to_have_text([THUMBS, THUMBS])
        # Taking mine back from there: it stays open, without me.
        await ana.click("#reaction-mine")
        await expect(ana.locator("#reaction-people .person .person-name")).to_have_text([BENS_NAME], timeout=10000)
        await expect(ana.locator("#reaction-mine")).to_be_hidden()  # All, and nothing of mine to take back
        print("live: a reaction arriving shows in it; taking mine back from it")

        # And when Ben takes his back too, it says so rather than showing what's gone.
        await ben.locator(".msg", has_text="lunch at noon?").click()
        await ben.locator(f".msg-actions button[aria-label='Take back your {THUMBS}']").click()
        await expect(ana.locator("#reactions-none")).to_be_visible(timeout=10000)
        await expect(ana.locator("#reaction-people .person")).to_have_count(0)
        await expect(ana.locator("#reaction-tabs")).to_be_hidden()
        await ana.click("#reactions-dialog [data-close]")
        await expect(pill(ana, THUMBS)).to_have_count(0)

        # The keyboard (a desktop): to a reaction, Enter opens it, Tab and Enter pick, Escape closes.
        await react_from_menu(ben, "lunch at noon?", LAUGH)
        await expect(pill(ana, LAUGH)).to_be_visible(timeout=10000)
        await pill(ana, LAUGH).focus()
        await ana.keyboard.press("Enter")
        await expect(sheet).to_be_visible()
        await expect(tabs.nth(1)).to_have_attribute("aria-pressed", "true")
        await expect(ana.locator("#reactions-dialog [data-close]")).to_be_focused()  # the sheet's first button
        await ana.keyboard.press("Tab")
        await expect(tabs.nth(0)).to_be_focused()
        await ana.keyboard.press("Enter")
        await expect(tabs.nth(0)).to_have_attribute("aria-pressed", "true")
        await expect(tabs.nth(0)).to_be_focused()  # drawn again, the focus stays put
        await ana.keyboard.press("Escape")
        await expect(sheet).to_be_hidden()
        print("desktop: the keyboard opens it, picks, and closes it")

        # A person there opens their profile (X46).
        await pill(ana, LAUGH).click()
        await person(ana, BENS_NAME).locator(".person-open").click()
        await expect(sheet).to_be_hidden()
        await expect(ana.locator("#profile-name")).to_have_text(BENS_NAME, timeout=10000)
        await ana.click("#profile-dialog [data-close]")
        print("a person in it opens their profile")

        # A group: Ben and Cal aren't friends, so Ben sees Cal by username, with the initial.
        gid = (await api(ana, "POST", "/groups", {"name": GROUP, "member_ids": [ben_id, cal_id]}))["id"]
        for page in (ana, ben, cal):
            await page.locator(".chat-item.is-group", has_text=GROUP).click()
            await expect(page.locator("#chat-title")).to_have_text(GROUP, timeout=10000)
        await cal.fill("#composer-input", "who's driving?")
        await cal.click("#composer button[type=submit]")  # (a phone: Enter is a new line)
        await expect(ben.locator(".msg", has_text="who's driving?")).to_be_visible(timeout=10000)
        mid = int((await ben.locator(".msg", has_text="who's driving?").get_attribute("data-key")).split(":")[1])
        await api(cal, "PUT", f"/groups/{gid}/messages/{mid}/reaction", {"emoji": LAUGH})
        await api(ana, "PUT", f"/groups/{gid}/messages/{mid}/reaction", {"emoji": THUMBS})
        await expect(pill(ben, THUMBS)).to_be_visible(timeout=10000)
        await react_from_menu(ben, "who's driving?", LAUGH)
        await expect(pill(ben, LAUGH)).to_have_text(f"{LAUGH}2", timeout=10000)
        await expect(pill(ben, LAUGH)).to_have_attribute("title", f"You, {CAL}")

        await pill(ben, LAUGH).click()
        await expect(ben.locator("#reaction-tabs .reaction-tab")).to_have_text([f"All3", f"{LAUGH}2", f"{THUMBS}1"])
        await expect(ben.locator("#reaction-people .person .person-name")).to_have_text([f"{BENS_NAME} (you)", CAL])
        cal_row = person(ben, CAL)
        await expect(cal_row.locator(".person-meta")).to_have_count(0)  # the name is the username
        await expect(cal_row.locator(".avatar")).to_have_text(CAL[0].upper())
        await ben.locator("#reaction-tabs .reaction-tab").nth(0).click()
        await expect(ben.locator("#reaction-people .person .person-name")).to_have_text([f"{BENS_NAME} (you)", CAL, ANA])
        await expect(ben.locator("#reactions-privacy")).to_contain_text("Reactions in groups aren't end-to-end encrypted yet")
        await no_placeholders(ben, "#reactions-dialog")
        await shot(ben, "who-reacted-group-desktop", full_page=False)
        # Live in a group: Cal changes hers while it's open.
        await api(cal, "PUT", f"/groups/{gid}/messages/{mid}/reaction", {"emoji": FOX})
        await expect(ben.locator("#reaction-tabs .reaction-tab")).to_have_text([f"All3", f"{THUMBS}1", f"{LAUGH}1", f"{FOX}1"], timeout=10000)
        await expect(ben.locator("#reaction-people .reaction-of")).to_have_text([THUMBS, LAUGH, FOX])
        # Cal isn't Ben's friend: her row opens what he may see of her.
        await cal_row.locator(".person-open").click()
        await expect(ben.locator("#profile-name")).to_have_text(CAL, timeout=10000)
        await expect(ben.locator("#profile-sub")).to_have_text("Not your friend")
        await ben.click("#profile-dialog [data-close]")
        print("group: who reacted with what, by the names Ben knows them by, live")

        # A phone (390 wide): Cal's view, Ana a friend by her name, Ben by username.
        await expect(pill(cal, FOX)).to_be_visible(timeout=10000)
        await pill(cal, FOX).tap()
        await expect(cal.locator("#reactions-dialog")).to_be_visible()
        await cal.locator("#reaction-tabs .reaction-tab").nth(0).tap()
        await expect(cal.locator("#reaction-people .person .person-name")).to_have_text([ANA, BEN, f"{CAL} (you)"])
        await expect(cal.locator("#reaction-mine")).to_have_text(f"Take back your {FOX}")
        width = await cal.evaluate("document.querySelector('#reactions-dialog').scrollWidth - document.querySelector('#reactions-dialog').clientWidth")
        assert width <= 0, f"the reactions sheet scrolls sideways by {width}px"
        await no_placeholders(cal, "#reactions-dialog")
        await shot(cal, "who-reacted-group-390", full_page=False)
        print("phone: the sheet fits")

        assert not errors, errors
        await browser.close()
    print("WHO REACTED TEST PASSED")


asyncio.run(main())
