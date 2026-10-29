"""Favorites and hidden chats (X3): favorites sit in their own section at the
top and follow you to your other devices live; hiding takes a chat off your
list (with Undo) until a new message or you open it again; groups are left,
not hidden. A computer reaches the actions by hovering a row, a phone by
swiping it. Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, launch, shot, PHONE, befriend, row, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
GROUP = f"Cabin {tag}"
async def swipe(page, locator, dx):
    """A finger dragging sideways `dx` pixels across `locator`."""
    box = await locator.bounding_box()
    x, y = box["x"] + box["width"] - 30, box["y"] + box["height"] / 2
    cdp = await page.context.new_cdp_session(page)
    await cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
    for i in range(1, 11):
        await cdp.send("Input.dispatchTouchEvent", {"type": "touchMove", "touchPoints": [{"x": x + dx * i / 10, "y": y + i * 0.3}]})
        await asyncio.sleep(0.02)
    await cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    await asyncio.sleep(0.3)


async def section_names(page):
    """The list as [(heading or None, name), ...], top to bottom."""
    return await page.evaluate("""() => { let h = null; const out = [];
      for (const li of document.querySelectorAll('#chat-list > li')) {
        if (li.classList.contains('list-heading')) h = li.textContent;
        else if (li.classList.contains('chat-row')) out.push([h, li.querySelector('.chat-name').textContent]);
      }
      return out; }""")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA)
        ben = await sign_up(browser, BEN, **PHONE)
        cal = await sign_up(browser, CAL)
        await befriend(ana, ben, BEN, ANA)
        await befriend(ana, cal, CAL, ANA)
        await befriend(ben, cal, CAL, BEN)

        # A group with all three, made by Ana.
        await ana.click("#start-button")
        await ana.fill("#new-group-name", GROUP)
        for name in (BEN, CAL):
            await ana.locator("#new-group-friends label", has_text=name).locator("input").check()
        await ana.click("#new-group-submit")
        await expect(ana.locator("#chat-title")).to_have_text(GROUP)
        await expect(row(ben, GROUP)).to_be_visible(timeout=10000)
        # Groups have a rounded-square picture, friends a round one (X17).
        # (Waits: the list may still be redrawing the row.)
        await expect(row(ben, GROUP).locator(".avatar")).to_have_css("border-top-left-radius", "30%")
        await expect(row(ben, ANA).locator(".avatar")).to_have_css("border-top-left-radius", "50%")
        await expect(row(ben, GROUP).locator(".visually-hidden")).to_have_text("Group: ")
        await shot(ben, "group-badge-phone")

        # Ana's laptop has a second tab open: changes there show up live.
        ana2 = await ana.context.new_page()
        await ana2.goto(BASE)
        await expect(row(ana2, CAL)).to_be_visible(timeout=10000)

        # A computer: hovering a row shows its actions. Favorite Cal and the group.
        assert await section_names(ana) and all(h is None for h, _ in await section_names(ana)), "no headings yet"
        await row(ana, CAL).hover()
        await expect(row(ana, CAL).locator(".row-action", has_text="Favorite")).to_be_visible()
        await shot(ana, "marks-hover", full_page=False)
        await row(ana, CAL).locator(".row-action", has_text="Favorite").click()
        await row(ana, GROUP).hover()
        await row(ana, GROUP).locator(".row-action", has_text="Favorite").click()
        names = await section_names(ana)
        favs = [n for h, n in names if h == "Favorites"]
        assert sorted(favs) == sorted([CAL, GROUP]), names
        assert [n for h, n in names if h == "Chats"] == [BEN], names
        # Live on the other tab, and still there after a reload.
        await expect(ana2.locator(".list-heading", has_text="Favorites")).to_be_visible(timeout=10000)
        await ana.reload()
        await expect(ana.locator("#app")).to_be_visible(timeout=10000)
        await expect(ana.locator(".list-heading", has_text="Favorites")).to_be_visible(timeout=10000)
        assert sorted(n for h, n in await section_names(ana) if h == "Favorites") == sorted([CAL, GROUP])
        # Private: Cal's list doesn't change.
        await expect(cal.locator(".list-heading")).to_have_count(0)
        # Unfavorite the group.
        await row(ana, GROUP).hover()
        await row(ana, GROUP).locator(".row-action", has_text="Unfavorite").click()
        assert [n for h, n in await section_names(ana) if h == "Favorites"] == [CAL]
        print("favorites: own section, live on other tabs, kept, private")

        # Hide Ben's chat: gone, with Undo; undo brings it back.
        await row(ana, BEN).hover()
        await row(ana, BEN).locator(".row-action", has_text="Hide").click()
        await expect(row(ana, BEN)).to_have_count(0)
        await expect(ana.locator("#toast")).to_contain_text(f"Hid your chat with {BEN}")
        await ana.click("#toast-undo")
        await expect(row(ana, BEN)).to_be_visible()
        # Hide it for real; the other tab follows; it waits under "Hidden chats".
        await row(ana, BEN).hover()
        await row(ana, BEN).locator(".row-action", has_text="Hide").click()
        await expect(row(ana2, BEN)).to_have_count(0, timeout=10000)
        await expect(ana.locator(".hidden-toggle")).to_have_text("Hidden chats (1)")
        await ana.click(".hidden-toggle button")
        await expect(row(ana, BEN).locator(".row-action", has_text="Unhide")).to_have_count(1)
        await ana.click(".hidden-toggle button")
        await expect(row(ana, BEN)).to_have_count(0)

        # Ben writes: the chat comes back on its own.
        await row(ben, ANA).click()
        await ben.fill("#composer-input", "you there?")
        await ben.click("#composer .send")
        await expect(row(ana, BEN)).to_be_visible(timeout=10000)
        await expect(ana.locator(".hidden-toggle")).to_have_count(0)
        print("hide: undo, synced, waits under Hidden chats, a new message brings it back")

        # A phone: swipe a row to reach its actions; Hide, then open it from Hidden chats.
        await ben.click("#back-button")
        await swipe(ben, row(ben, ANA), -200)
        await expect(row(ben, ANA).locator(".row-action", has_text="Hide")).to_be_in_viewport()
        await shot(ben, "marks-swiped-phone", full_page=False)
        await row(ben, ANA).locator(".row-action", has_text="Hide").tap()
        await expect(row(ben, ANA)).to_have_count(0)
        await ben.tap(".hidden-toggle button")
        await row(ben, ANA).locator(".chat-item").tap()
        await expect(ben.locator("#chat-title")).to_have_text(ANA)
        await ben.tap("#back-button")
        await expect(row(ben, ANA)).to_be_visible()
        await expect(ben.locator(".hidden-toggle")).to_have_count(0)
        # A short sideways drag springs back closed; a tap on an open row just closes it.
        await swipe(ben, row(ben, CAL), -30)
        assert await row(ben, CAL).locator(".chat-item").evaluate("e => e.style.transform") in ("", "none")
        await swipe(ben, row(ben, CAL), -200)
        await row(ben, CAL).locator(".chat-item").tap()
        await expect(ben.locator("#chat")).to_be_hidden()

        # Leaving a group from the list takes two taps.
        await swipe(ben, row(ben, GROUP), -220)
        leave = row(ben, GROUP).locator(".row-action", has_text="Leave")
        await leave.tap()
        await expect(row(ben, GROUP).locator(".row-action.danger")).to_have_text("Tap to leave")
        await row(ben, GROUP).locator(".row-action.danger").tap()
        await expect(row(ben, GROUP)).to_have_count(0, timeout=10000)
        await expect(ana.locator(".group-event", has_text=f"{BEN} left")).to_have_count(0)  # Ana isn't in the group view
        overflow = await ben.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"the list scrolls sideways by {overflow}px"
        print("phone: swipe for actions, hidden chat reopens, two-tap leave")

        # Mute: Ana mutes Cal for 8 hours; Cal's next message brings no dot or count.
        await row(ana, CAL).hover()
        await row(ana, CAL).locator(".row-action", has_text="Mute").click()
        await expect(ana.locator("#mute-dialog")).to_be_visible()
        await expect(ana.locator("#mute-title")).to_have_text(f"Mute {CAL}")
        await ana.click("#mute-dialog [data-hours='8']")
        await expect(row(ana, CAL).locator(".chat-name")).to_contain_text("🔕")
        await expect(ana.locator("#toast")).to_contain_text(f"Muted {CAL}")
        title_before = await ana.title()
        await row(cal, ANA).click()
        await cal.fill("#composer-input", "muted hello")
        await cal.click("#composer .send")
        await expect(row(ana, CAL).locator(".chat-status")).to_have_text("muted hello", timeout=10000)
        assert await row(ana, CAL).locator(".marker.text").count() == 0, "no unread dot"
        assert await ana.title() == title_before, "a muted chat doesn't add to the unread count"
        await row(ana, CAL).hover()
        await row(ana, CAL).locator(".row-action", has_text="Unmute").click()
        await expect(row(ana, CAL).locator(".chat-name")).not_to_contain_text("🔕")
        await expect(row(ana, CAL).locator(".marker.text")).to_have_count(1)
        print("mute: no dot or count while muted; unmuted, it's back")

        # Search: chats by name as you type, then messages (decrypted here, not on the server).
        await ana.fill("#chat-search", CAL[:5])
        await expect(ana.locator("#chat-list .chat-row")).to_have_count(1)
        await ana.fill("#chat-search", "you there")
        hit = ana.locator(".search-hit", has_text=BEN)
        await expect(hit).to_be_visible(timeout=15000)
        await expect(hit.locator("mark")).to_have_text("you there")
        await shot(ana, "search", full_page=False)
        await hit.click()
        await expect(ana.locator("#chat-title")).to_have_text(BEN)
        await expect(ana.locator("#messages .msg", has_text="you there?")).to_be_in_viewport()
        await ana.fill("#chat-search", "zzz no such words")
        await expect(ana.locator(".search-note", has_text="No messages")).to_be_visible(timeout=15000)
        await ana.press("#chat-search", "Escape")
        await expect(ana.locator("#chat-search")).to_have_value("")
        await expect(row(ana, CAL)).to_be_visible()
        # On a phone the search box fits.
        await ben.tap("#back-button") if await ben.locator("#back-button").is_visible() else None
        await expect(ben.locator("#chat-search")).to_be_visible()
        overflow = await ben.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"scrolls sideways by {overflow}px"
        print("search: chats by name, messages by text, a hit opens the chat at the message")

        await browser.close()
    print("MARKS TEST PASSED")


asyncio.run(main())
