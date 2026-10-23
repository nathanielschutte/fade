"""Group chats through the real UI: create, message, add, remove, rename,
leave, all live across four browsers. Settings come from the environment;
see common.py."""
import asyncio, re, sqlite3, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, DB, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL, DEE = (f"{n}_{tag}" for n in ("ana", "ben", "cal", "dee"))
GROUP = "Road trip"

# Friend requests through the API with each page's own session (the UI for
# that is covered elsewhere); everything group-related goes through the UI.
REQUEST = """async (name) => (await fetch('/api/friends/requests', { method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + localStorage.getItem('fade.token') },
  body: JSON.stringify({ username: name }) })).status"""


# Headless Chrome has no camera here; stand in a 1280x720 canvas stream.
CAMERA = """navigator.mediaDevices.getUserMedia = async () => {
  const c = document.createElement('canvas'); c.width = 1280; c.height = 720;
  const g = c.getContext('2d');
  setInterval(() => { g.fillStyle = '#3a6'; g.fillRect(0, 0, 1280, 720); g.fillStyle = '#fd3'; g.fillRect(500, 200, 280, 280); }, 30);
  return c.captureStream(30);
};"""

# A real PNG made in the page, handed to a file input the way a person would pick one.
PICK_IMAGE = """async (selector) => {
  const c = document.createElement('canvas'); c.width = 900; c.height = 600;
  const g = c.getContext('2d'); g.fillStyle = '#2b5'; g.fillRect(0, 0, 900, 600); g.fillStyle = '#fff'; g.fillRect(300, 150, 300, 300);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'group.png', { type: 'image/png' }));
  const input = document.querySelector(selector); input.files = dt.files; input.dispatchEvent(new Event('change'));
}"""


async def register(browser, name, **ctx):
    context = await browser.new_context(**ctx)
    await context.add_init_script(CAMERA)
    page = await context.new_page()
    await page.goto(BASE)
    await page.click("#auth-toggle")
    await page.fill("input[name=username]", name)
    await page.fill("input[name=password]", "correct horse battery")
    await page.fill("input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(page)
    return page


async def friends(a, b, b_name):
    assert await a.evaluate(REQUEST, b_name) == 200
    a_name = await a.evaluate("document.querySelector('#my-name').textContent")
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
        # The bar: wordmark on the left; Friends, then +, together on the right.
        # + says what it does (today it goes straight to New group).
        await expect(ana.locator("#start-button")).to_have_attribute("aria-label", "New group")
        for page in (ana, dee):  # desktop and phone
            box = await page.evaluate("""() => Object.fromEntries(['.list-pane > .bar', '#friends-button', '#start-button']
              .map((s) => [s, document.querySelector(s).getBoundingClientRect().toJSON()]))""")
            bar, friends_b, start_b = box[".list-pane > .bar"], box["#friends-button"], box["#start-button"]
            assert friends_b["right"] <= start_b["left"] <= friends_b["right"] + 12, (friends_b, start_b)
            assert bar["right"] - start_b["right"] <= 12, "+ sits at the right edge"
        await shot(dee, "list-bar-phone", full_page=False)
        await shot(ana, "list-bar-desktop", full_page=False)
        await ana.click("#start-button")
        await ana.fill("#new-group-name", GROUP)
        await expect(ana.locator("#new-group-friends .person-name")).to_have_count(3)
        for name in (BEN, CAL):
            await ana.locator("#new-group-friends label", has_text=name).locator("input").check()
        await ana.click("#new-group-submit")
        await expect(ana.locator("#chat-title")).to_have_text(GROUP)
        await expect(ana.locator("#chat-sub")).to_have_text("3 people")
        await expect(ana.locator("#group-notice")).to_be_visible()
        await expect(ana.locator("#camera-button")).to_be_visible()  # pics work in groups
        await expect(ana.locator("#safety-button")).to_be_hidden()
        await expect(ana.locator(".group-event")).to_have_text(f"You created the group “{GROUP}”")
        print("created; notice shown, safety code hidden")

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

        # End-to-end encrypted: everyone reads it, the server holds only ciphertext,
        # and the chat says from where on (and that the name and picture aren't).
        await expect(cal.locator(".group-event", has_text="end-to-end encrypted from now on")).to_be_visible()
        await expect(cal.locator("#group-notice")).to_contain_text("The group's name and picture aren't")
        if DB:
            # (The database is shared with the other tests; look at this group only.)
            db = sqlite3.connect(DB)
            rows = db.execute("""SELECT gm.id, gm.format, gm.body FROM group_messages gm JOIN groups g ON g.id = gm.group_id
                                 WHERE g.name = ? AND gm.kind = 'text'""", (GROUP,)).fetchall()
            assert rows and all(f == 3 for _, f, _ in rows), rows
            assert not any("driving" in b for _, _, b in rows), "the server has no plaintext"
            keys = db.execute("SELECT COUNT(*) FROM group_message_keys WHERE message_id = ?", (rows[0][0],)).fetchone()[0]
            assert keys == 3, f"one key per member (ana, ben, cal): {keys}"
        print("encrypted: members read it, the database holds only ciphertext")

        # "Seen by", live: Cal opening the group shows under Ben's message.
        await expect(ben.locator(".seen-by")).to_contain_text(CAL, timeout=10000)
        await expect(ben.locator(".seen-by")).to_contain_text("Seen by")
        assert await ben.locator(".seen-by").count() == 1
        print("seen by:", await ben.locator(".seen-by").text_content())

        # Hostile text is shown as text: no element is created, nothing runs.
        xss = '<img src=x onerror="window.__xss=1"><b>bold</b>'
        await ben.fill("#composer-input", xss)
        await ben.press("#composer-input", "Enter")
        await expect(cal.locator(".msg", has_text=xss)).to_be_visible(timeout=10000)
        await expect(group_item(ana).locator(".chat-status")).to_contain_text("<img", timeout=10000)
        for p in (ana, ben, cal):
            assert await p.evaluate("window.__xss") is None, "script ran"
            assert await p.locator("#messages img[src='x'], #messages b, #chat-list b").count() == 0
        print("XSS payload rendered as plain text everywhere")

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
        await expect(ana.locator("#group-remove-hint")).to_contain_text("you can remove people")
        remove = ana.locator("#group-members .person", has_text=CAL).locator("button", has_text="Remove")
        await remove.click()                                   # two taps, like leaving
        await expect(remove).to_have_text("Tap again to remove")
        await expect(ana.locator("#group-members .person")).to_have_count(4)
        await remove.click()
        await expect(ana.locator("#group-members .person")).to_have_count(3, timeout=10000)
        await expect(group_item(cal)).to_have_count(0, timeout=10000)
        await expect(cal.locator("#chat")).to_be_hidden()
        await ana.click("#group-dialog [data-close]")
        await expect(ana.locator(".group-event", has_text=f"You removed {CAL}")).to_be_visible()
        print("added Dee; removed Cal, whose chat closed")

        # A pic in the group: view-once for Ben; Ana sees who opened it.
        await ana.click("#camera-button")
        await ana.wait_for_timeout(500)
        await ana.click("#shutter")
        await expect(ana.locator("#send-snap")).to_have_text(f"Send to {GROUP}")
        await ana.fill("#snap-caption", "<i>road</i> ✨ trip")
        await ana.click("#send-snap")
        await expect(ana.locator("#camera-dialog")).to_be_hidden(timeout=10000)
        await expect(ana.locator(".snap-chip.done", has_text="Pic sent")).to_be_visible()
        await expect(group_item(ben).locator(".chat-status")).to_have_text(f"{ANA} sent a pic", timeout=10000)
        await ben.locator("button.snap-chip", has_text="Tap to view pic").click()
        await expect(ben.locator("#viewer-image")).to_be_visible()
        await expect(ben.locator("#viewer-from")).to_contain_text(ANA)
        await expect(ben.locator("#viewer-caption")).to_have_text("<i>road</i> ✨ trip")  # as text
        assert await ben.locator("#viewer-caption i").count() == 0
        await asyncio.sleep(0.7)  # past the tap guard
        await ben.click("#viewer")
        await expect(ben.locator(".snap-chip.done", has_text="Viewed")).to_be_visible(timeout=10000)
        await expect(ana.locator(".snap-chip.done", has_text="Opened by 1")).to_be_visible(timeout=10000)
        print("group pic: sent, opened once, sender sees the count")

        # Ana sets a group picture; it shows for Ben in the header and the list.
        await ana.click("#chat-title")
        await ana.evaluate(PICK_IMAGE, "#group-picture-input")
        await expect(ana.locator("#group-note")).to_have_text("Group picture updated.", timeout=10000)
        await expect(ana.locator("#group-avatar img")).to_be_visible(timeout=10000)
        await ana.click("#group-dialog [data-close]")
        await expect(ben.locator("#chat-avatar img")).to_be_visible(timeout=10000)
        await expect(group_item(ben).locator(".avatar img")).to_be_visible()
        await expect(ben.locator(".group-event", has_text=f"{ANA} changed the group picture")).to_be_visible()
        print("group picture: set by a member, shown to the others live")

        # Dee only knows Ana. From the member list she adds Ben; Ben accepts from his.
        await group_item(dee).click()
        await dee.click("#chat-title")
        ben_row = dee.locator("#group-members .person", has_text=BEN)
        await expect(ben_row.locator("button", has_text="Add friend")).to_be_visible(timeout=10000)
        await expect(dee.locator("#group-members .person", has_text=ANA).locator("button", has_text="Add friend")).to_have_count(0)
        await ben_row.locator("button", has_text="Add friend").click()
        await expect(dee.locator("#group-note")).to_have_text(f"Request sent to {BEN}.")
        await expect(ben_row).to_contain_text("Requested")
        await ben.click("#chat-title")
        dee_row = ben.locator("#group-members .person", has_text=DEE)
        await dee_row.locator("button", has_text="Accept").click()
        await expect(ben.locator("#group-note")).to_have_text(f"You and {DEE} are now friends.", timeout=10000)
        await expect(dee_row.locator("button", has_text=re.compile("Add friend|Accept"))).to_have_count(0)  # friends now
        await expect(dee_row.locator(".link-name")).to_be_visible()                        # their name opens their profile
        await expect(ben_row.locator(".link-name")).to_be_visible(timeout=10000)  # Dee's sheet caught up live
        await expect(dee.locator(".chat-item:not(.is-group)", has_text=BEN)).to_have_count(1, timeout=10000)  # a new chat in her list
        await shot(dee, "group-befriend-phone", full_page=False)
        await dee.click("#group-dialog [data-close]")
        await dee.click("#back-button")  # (a phone: back to the chat list)
        await ben.click("#group-dialog [data-close]")
        print("befriending from a group: add, requested, accept, both sheets live")

        # Ben isn't the owner: no Remove buttons, but he can rename.
        await ben.click("#chat-title")
        await expect(ben.locator("#group-members .person")).to_have_count(3)
        await expect(ben.locator("#group-members button", has_text="Remove")).to_have_count(0)
        await expect(ben.locator("#group-remove-hint")).to_have_text(f"Only {ANA} can remove people. You can add your friends.")
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

        # A very long message: the list preview ends in "…" instead of widening the list.
        await ana.locator(".chat-item", has_text=DEE).click()
        await ana.fill("#composer-input", "word " * 300)
        await ana.press("#composer-input", "Enter")
        status = dee.locator(".chat-item", has_text=ANA).locator(".chat-status")
        await expect(status).to_contain_text("…", timeout=10000)
        assert len(await status.text_content()) <= 140
        await group_item(ana, "Road trip 2026").click()

        # Dee on a phone: the group reads well and nothing overflows.
        await group_item(dee, "Road trip 2026").click()
        await expect(dee.locator(".group-event", has_text=f"{ANA} added you")).to_be_visible()
        await expect(dee.locator(".msg", has_text="who's driving?")).to_have_count(0)  # before Dee joined
        overflow = await dee.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"group chat scrolls sideways by {overflow}px"
        await dee.click("#back-button")
        list_overflow = await dee.evaluate("document.querySelector('#chat-list').scrollWidth - document.querySelector('#chat-list').clientWidth")
        assert list_overflow <= 0, f"chat list scrolls sideways by {list_overflow}px"
        await shot(dee, "list-phone", full_page=False)
        await group_item(dee, "Road trip 2026").click()
        await shot(dee, "group-phone", full_page=False)
        await shot(ana, "group-desktop", full_page=False)
        await browser.close()
    print("GROUPS TEST PASSED")


asyncio.run(main())
