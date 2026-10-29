"""Profiles: your own (friends and counts) and a friend's (what you share),
opened from the Friends sheet and from a chat's title.
Settings come from the environment; see common.py."""
import asyncio, datetime, re, sqlite3, time, uuid
from playwright.async_api import async_playwright, expect

from common import DB, launch, no_placeholders, shot, befriend, sign_up, PHONE

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"


# A real PNG made in the page, handed to a file input the way a person would pick one.
PICK_IMAGE = """async (selector) => {
  const c = document.createElement('canvas'); c.width = 900; c.height = 600;
  const g = c.getContext('2d'); g.fillStyle = '#c84'; g.fillRect(0, 0, 900, 600); g.fillStyle = '#fff'; g.fillRect(300, 150, 300, 300);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'me.png', { type: 'image/png' }));
  const input = document.querySelector(selector); input.files = dt.files; input.dispatchEvent(new Event('change'));
}"""


def stat(page, label):
    """The value next to exactly this label ("Pic streak", not "Longest pic streak")."""
    return page.locator("#profile-stats dt", has_text=re.compile(f"^{re.escape(label)}$")).locator("xpath=following-sibling::dd[1]")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA)
        ben = await sign_up(browser, BEN)
        cal = await sign_up(browser, CAL, **PHONE)
        await befriend(ana, ben, BEN, ANA)
        await befriend(ana, cal, CAL, ANA)
        await befriend(ben, cal, CAL, BEN)

        # Ana sends Ben two texts.
        await ana.locator(".chat-item", has_text=BEN).click()
        for text in ("hey", "profile test"):
            await ana.fill("#composer-input", text)
            await ana.press("#composer-input", "Enter")
        await expect(ana.locator(".msg", has_text="profile test")).to_be_visible()

        # Ana's own profile, from the account bar on the main screen.
        await expect(ana.locator("#my-name")).to_have_text(ANA)
        await ana.click("#my-profile")
        await expect(ana.locator("#profile-name")).to_have_text(ANA)
        await expect(ana.locator("#profile-sub")).to_contain_text(f"@{ANA} · joined")
        await expect(stat(ana, "Texts sent")).to_have_text("2")
        await expect(stat(ana, "Friends")).to_have_text("2")
        await expect(ana.locator("#profile-people .person-name")).to_have_text([BEN, CAL])
        await no_placeholders(ana, "#profile-dialog")
        # The stats are only label and value pairs: nothing else in the grid.
        assert await ana.locator("#profile-stats > :not(dt, dd)").count() == 0
        await shot(ana, "profile-mine", full_page=False)

        # Click through to Ben's profile.
        await ana.locator("#profile-people .person-link", has_text=BEN).click()
        await expect(ana.locator("#profile-name")).to_have_text(BEN)
        await expect(ana.locator("#profile-sub")).to_contain_text("friends since")
        await expect(stat(ana, "Texts between you")).to_have_text("2")
        await expect(stat(ana, "Their friends")).to_have_text("2")
        await expect(ana.locator("#profile-people-title")).to_have_text("Friends you share")
        await expect(ana.locator("#profile-people .person-name")).to_have_text([CAL])
        await no_placeholders(ana, "#profile-dialog")
        assert await ana.locator("#profile-stats > :not(dt, dd)").count() == 0
        await shot(ana, "profile-friend", full_page=False)

        # "Message" opens the chat.
        await ana.click("#profile-actions button")
        await expect(ana.locator("#profile-dialog")).not_to_be_visible()
        await expect(ana.locator("#chat-title")).to_have_text(BEN)

        # Ana names herself and adds a picture; her friends see both, live.
        await ana.click("#my-profile")
        await ana.fill("#profile-name-input", "  Ana   Banana ")
        await ana.press("#profile-name-input", "Enter")
        await expect(ana.locator("#profile-edit-note")).to_have_text("Saved.")
        await expect(ana.locator("#profile-name")).to_have_text("Ana Banana")
        await expect(ana.locator("#my-name")).to_have_text("Ana Banana")
        await ana.evaluate(PICK_IMAGE, "#profile-picture-input")
        await expect(ana.locator("#profile-edit-note")).to_have_text("Picture updated.", timeout=10000)
        await expect(ana.locator("#profile-avatar img")).to_be_visible()
        await expect(ana.locator("#my-avatar img")).to_be_visible()
        await shot(ana, "profile-edit", full_page=False)
        # Tapping the picture shows it bigger, round; outside it or × closes it (X24).
        await ana.click("#profile-avatar")
        await expect(ana.locator("#picture-viewer")).to_be_visible()
        await expect(ana.locator("#picture-big img")).to_be_visible()
        await expect(ana.locator("#picture-big")).to_have_css("border-top-left-radius", "50%")
        await asyncio.sleep(0.3)
        await shot(ana, "picture-bigger", full_page=False)
        await ana.mouse.click(8, 400)  # the backdrop
        await expect(ana.locator("#picture-viewer")).to_be_hidden()
        await ana.click("#profile-avatar")
        await ana.click("#picture-viewer [data-close]")
        await expect(ana.locator("#picture-viewer")).to_be_hidden()
        await expect(ana.locator("#profile-dialog")).to_be_visible()  # back where you were
        await ana.click("#profile-dialog [data-close]")
        ana_row = ben.locator(".chat-item", has_text="Ana Banana")
        await expect(ana_row).to_be_visible(timeout=10000)
        await expect(ana_row.locator(".avatar img")).to_be_visible(timeout=10000)

        # Ben gives her a nickname only he sees; the username stays visible as the identity.
        await ana_row.click()
        await expect(ben.locator("#chat-sub")).to_contain_text(f"@{ANA}")  # after "Active now"
        await ben.click("#chat-title")
        await expect(ben.locator("#profile-name-label")).to_have_text("Nickname")
        await ben.fill("#profile-name-input", "Sis")
        await ben.press("#profile-name-input", "Enter")
        await expect(ben.locator("#profile-name")).to_have_text("Sis", timeout=10000)
        await expect(ben.locator("#profile-sub")).to_contain_text(f"@{ANA} · goes by “Ana Banana”")
        await ben.click("#profile-dialog [data-close]")
        await expect(ben.locator("#chat-title")).to_have_text("Sis")
        await expect(ben.locator(".chat-item .chat-name", has_text="Sis")).to_be_visible()
        await expect(ben.locator(".sender", has_text="Sis").first).to_be_visible()
        await shot(ben, "nickname", full_page=False)
        await expect(cal.locator(".chat-item .chat-name", has_text="Ana Banana")).to_be_visible(timeout=10000)
        assert await cal.locator(".chat-item", has_text="Sis").count() == 0, "nicknames are private"

        # Removing the picture goes back to the initial, for everyone.
        await ana.click("#my-profile")
        await ana.click("#profile-picture-clear")
        await expect(ana.locator("#profile-edit-note")).to_have_text("Picture removed.", timeout=10000)
        await expect(ana.locator("#profile-avatar img")).to_have_count(0)
        await ana.click("#profile-avatar")  # just an initial: nothing to see bigger
        await expect(ana.locator("#picture-viewer")).to_be_hidden()
        await ana.click("#profile-dialog [data-close]")
        await expect(ben.locator(".chat-item", has_text="Sis").locator(".avatar img")).to_have_count(0, timeout=10000)
        await expect(ben.locator(".chat-item", has_text="Sis").locator(".avatar")).to_have_text("S")
        print("names, private nicknames, and pictures: set, seen live, removed")

        # A birthday: today's date, so friends see the cake in their list today.
        today = datetime.date.today()
        await ana.click("#my-profile")
        await ana.click("#profile-birthday-form button[type=submit]")          # nothing picked yet
        await expect(ana.locator("#profile-edit-note")).to_have_text("Pick a month and a day.")
        await ana.select_option("#birthday-month", str(today.month))
        await ana.select_option("#birthday-day", str(today.day))
        await ana.fill("#birthday-year", "94")
        await ana.click("#profile-birthday-form button[type=submit]")
        await expect(ana.locator("#profile-edit-note")).to_have_text("The year is four digits, or leave it empty.")
        await ana.fill("#birthday-year", "1994")
        await ana.click("#profile-birthday-form button[type=submit]")
        await expect(ana.locator("#profile-edit-note")).to_have_text("Birthday saved.", timeout=10000)
        await expect(stat(ana, "Birthday")).to_contain_text(f"{today.day}, 1994")
        await ana.click("#profile-dialog [data-close]")
        await expect(ben.locator(".chat-item .chat-name", has_text="Sis 🎂")).to_be_visible(timeout=10000)
        print("birthday: set with checks, on the profile, a cake on the day")

        # A three-day pic streak between Ana and Ben (backdated straight into the
        # test database; the API only stamps "now"): a flame and the count.
        if DB:
            db = sqlite3.connect(DB)
            ids = dict(db.execute("SELECT username, id FROM users WHERE username IN (?, ?)", (ANA, BEN)).fetchall())
            # Days count in the viewer's own zone: put each pic just after Ben's local midnight.
            off = await ben.evaluate("-new Date().getTimezoneOffset()") * 60
            today = (int(time.time()) + off) // 86400
            for d in (today - 2, today - 1, today):
                for frm, to, sec in ((ids[ANA], ids[BEN], 60), (ids[BEN], ids[ANA], 61)):
                    db.execute("INSERT INTO messages (sender_id, recipient_id, kind, created_at, snap_state, format) VALUES (?, ?, 'snap', ?, 'opened', 2)",
                               (frm, to, d * 86400 - off + sec))
            db.commit()
            await ben.reload()
            await expect(ben.locator("#app")).to_be_visible(timeout=10000)
            await expect(ben.locator(".chat-item .chat-name", has_text="Sis")).to_contain_text("🔥3", timeout=10000)
            await ben.locator(".chat-item", has_text="Sis").click()
            await ben.click("#chat-title")
            await expect(stat(ben, "Pic streak")).to_contain_text("🔥 3 days")
            await expect(stat(ben, "Longest pic streak")).to_have_text("3 days")
            await ben.click("#profile-dialog [data-close]")
            print("streaks: a flame and the count in the list, and on the profile")

        # On a phone, the chat title opens the friend's profile and nothing overflows.
        await cal.locator(".chat-item", has_text="Ana Banana").click()
        await cal.click("#chat-title")
        await expect(cal.locator("#profile-name")).to_have_text("Ana Banana")
        await expect(stat(cal, "Texts between you")).to_have_text("0")
        await expect(stat(cal, "First message")).to_have_text("—")
        await expect(stat(cal, "Birthday")).to_contain_text(", 1994")
        await expect(cal.locator("#profile-people .person-name")).to_have_text([BEN])
        overflow = await cal.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"profile scrolls sideways by {overflow}px"
        await shot(cal, "profile-phone", full_page=False)
        await browser.close()
    print("PROFILE TEST PASSED")


asyncio.run(main())
