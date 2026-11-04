"""System › Reports (docs/design/report-and-block.md, F28): an Admin sees who
reported whom, when, why, and what kind of message, never what it said;
warns (Team Napsack tells the reported person, end-to-end encrypted, which
message, and the web app opens it like any text); suspends for a day (they're
signed out, and signing in says until when, and why); and follows the link
to their System › Users entry. People report through the API here: the
apps' Report buttons are the next step. Settings come from the environment;
see common.py."""
import asyncio, re, uuid
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, PHONE, befriend, fill_sign_up, launch, open_page, row, shot, sign_in, sign_up_or_in

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"rep_ana_{tag}", f"rep_ben_{tag}"
# The reporter's note is shown as text, never as HTML.
NOTE = f"<img src=x onerror=window.pwned=1> kept at it {tag}"
errors = []

API = """async ([method, path, body]) => {
  const r = await fetch('/api' + path, { method, headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token'),
    'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  return [r.status, await r.json()];
}"""


async def api(page, method, path, body=None):
    status, out = await page.evaluate(API, [method, path, body])
    assert status == 200, (method, path, status, out)
    return out


def card(page, text):
    return page.locator("#reports .report", has_text=text)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await open_page(browser, errors, "ana", **PHONE)
        ben = await open_page(browser, errors, "ben", **PHONE)
        await fill_sign_up(ana, ANA)
        await fill_sign_up(ben, BEN)
        await befriend(ana, ben, BEN, ANA)
        await row(ben, ANA).locator(".chat-item").click()
        await ben.fill("#composer-input", "see you at 8")
        await ben.click("#composer button[type=submit]")  # (a phone: Enter is a new line)
        await expect(ben.locator(".msg", has_text="see you at 8")).to_be_visible(timeout=10000)
        await ben.fill("#composer-input", "and bring snacks")
        await ben.click("#composer button[type=submit]")  # (a phone: Enter is a new line)
        await expect(ben.locator(".msg", has_text="and bring snacks")).to_be_visible(timeout=10000)

        # Ana reports Ben's text, and Ben himself.
        ben_id = next(f["id"] for f in await api(ana, "GET", "/friends") if f["username"] == BEN)
        # Both stored (the chat shows a text as it goes, before the server has it).
        await expect(row(ana, BEN).locator(".chat-item")).to_be_visible()
        await row(ana, BEN).locator(".chat-item").click()
        await expect(ana.locator(".msg", has_text="and bring snacks")).to_be_visible(timeout=10000)
        text, snacks = (await api(ana, "GET", f"/chats/{ben_id}/messages"))[-2:]
        first = await api(ana, "POST", "/reports", {"kind": "message", "message_id": text["id"], "reason": "harassment", "note": NOTE})
        second = await api(ana, "POST", "/reports", {"kind": "person", "user_id": ben_id, "reason": "spam"})
        third = await api(ana, "POST", "/reports", {"kind": "message", "message_id": snacks["id"], "reason": "other"})
        again = await api(ana, "POST", "/reports", {"kind": "message", "message_id": text["id"], "reason": "spam"})
        assert again == {"id": first["id"], "already": True}, "once per message"

        admin = await open_page(browser, errors, "admin", viewport={"width": 1200, "height": 900})
        await sign_up_or_in(admin, ADMIN)
        await admin.goto(f"{BASE}/admin#reports")
        await expect(admin.locator("#tab-reports")).to_be_visible(timeout=10000)
        await expect(admin.locator("#tab-reports")).to_have_text(re.compile(r"Reports \(\d+\)"))
        one = card(admin, f"#{first['id']} ·")
        await expect(one).to_contain_text(f"{ANA} reported {BEN}", timeout=10000)
        await expect(one).to_contain_text("Harassment or bullying")
        await expect(one).to_contain_text(f"a text in their chat, sent ")
        await expect(one).to_contain_text(f"(message {text['id']})")
        await expect(one).to_contain_text(NOTE)
        await expect(one.locator(".status-chip").first).to_have_text("Open")
        await expect(one).to_contain_text("Other reports about them2")
        await expect(card(admin, f"#{second['id']} ·")).to_contain_text("their profile")
        assert "see you at 8" not in await admin.content(), "never what it said"
        assert await admin.evaluate("window.pwned") is None, "the note is text, not HTML"
        await shot(admin, "reports-desktop", full_page=False)

        # Warn: the words box opens on the first tap; the second sends it.
        await one.locator("button[data-action=warn]").click()
        await expect(one.locator("button[data-action=warn]")).to_have_text("Tap again: warn them")
        await one.locator("input").fill(f"Please keep it friendly {tag}")
        await shot(admin, "reports-warning", full_page=False)
        await one.locator("button[data-action=warn]").click()
        await expect(admin.locator("#rep-result")).to_contain_text("Team Napsack told them why", timeout=10000)
        await expect(one.locator(".status-chip").first).to_have_text("Warned")
        await expect(one).to_contain_text(f"They were told: “Please keep it friendly {tag}”")
        await expect(one.locator("button")).to_have_count(0)

        # Ben's app opens Team Napsack's message like any text: the Admin's words, and
        # never the note, what it said (the server doesn't know), or anything that says who reported it.
        await ben.click("#back-button")
        await expect(row(ben, "Team Napsack")).to_be_visible(timeout=10000)
        await row(ben, "Team Napsack").locator(".chat-item").click()
        told = ben.locator(".msg", has_text="An Admin reviewed a report about a message you sent")
        await expect(told).to_contain_text(f"Please keep it friendly {tag}", timeout=10000)
        # A direct message names neither whom it went to nor where: only Ana could have reported it.
        await expect(told).not_to_contain_text(ANA)
        await expect(told).not_to_contain_text("#chat=")
        await expect(told).not_to_contain_text("kept at it")
        await shot(ben, "reports-warned-phone", full_page=False)

        # Suspend for a day: Ben is signed out, and signing in says until when, and why.
        two = card(admin, f"#{second['id']} ·")
        await two.locator("button[data-action=suspend]").click()
        await two.locator(".segment", has_text="1 day").click()
        await expect(two.locator(".segment", has_text="1 day")).to_have_attribute("aria-pressed", "true")
        await two.locator("input").fill(f"A day off {tag}")
        await two.locator("button[data-action=suspend]").click()
        await expect(two.locator(".status-chip").first).to_have_text("Suspended", timeout=10000)
        await expect(two).to_contain_text("Suspended until")
        await expect(ben.locator("#auth")).to_be_visible(timeout=15000)
        await sign_in(ben, BEN, wait=False)
        await expect(ben.locator("#auth-error")).to_contain_text("This account is suspended until", timeout=15000)
        await expect(ben.locator("#auth-error")).to_contain_text(f"A day off {tag}")
        await shot(ben, "reports-suspended-phone", full_page=False)

        # Their System › Users entry, from the report.
        await two.locator(".report-who a", has_text=BEN).click()
        await expect(admin.locator("#u-detail-title")).to_have_text(BEN, timeout=10000)
        await expect(admin.locator("#u-history")).to_contain_text(f"They were told: “A day off {tag}”")
        await expect(admin.locator("#u-history")).to_contain_text("Suspended until")
        await expect(admin.locator("#act-feed")).to_contain_text(f"sent a warning over a report to {BEN} (report #{first['id']})")

        # A link to one report (as the support email will carry) opens on it.
        await admin.goto(f"{BASE}/admin#reports={first['id']}")
        await expect(admin.locator(f"#report-{first['id']}.focused")).to_be_visible(timeout=10000)

        # The Reports tab at phone width: nothing scrolls sideways.
        phone = await open_page(browser, errors, "admin-phone", **PHONE)
        await sign_up_or_in(phone, ADMIN)
        await phone.goto(f"{BASE}/admin#reports")
        await expect(card(phone, f"#{first['id']} ·")).to_contain_text("Warned", timeout=10000)
        await shot(phone, "reports-phone", full_page=False)
        # An open one, with its words box out: nothing scrolls sideways.
        three = card(phone, f"#{third['id']} ·")
        await three.locator("button[data-action=dismiss]").click()
        await expect(three.locator("input")).to_be_visible()
        await three.scroll_into_view_if_needed()
        overflow = await phone.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        wide = await phone.evaluate("""() => [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > document.documentElement.clientWidth + 1 && !e.closest('.table-scroll')).slice(0, 8).map((e) => e.tagName + '#' + e.id + '.' + e.className + ' ' + Math.round(e.getBoundingClientRect().right))""")
        assert overflow <= 0, f"scrolls sideways by {overflow}px: {wide}"
        await shot(phone, "reports-open-phone", full_page=False)
        await three.locator("input").fill("the same as the others")
        await three.locator("button[data-action=dismiss]").click()
        await expect(three.locator(".status-chip").first).to_have_text("Dismissed", timeout=10000)
        await expect(three).to_contain_text("Dismissed by")

        # An Admin turns Ben back on (System › Users), so nothing here lingers.
        await admin.goto(f"{BASE}/admin#users={ben_id}")
        await expect(admin.locator("#u-detail-title")).to_have_text(BEN, timeout=10000)
        await admin.locator("#u-actions button", has_text="Turn account back on").click()
        await admin.locator("#u-actions button", has_text="Tap again: turn it back on").click()
        await expect(admin.locator("#u-detail-status .status-chip")).not_to_have_text("Turned off", timeout=10000)

        assert not errors, errors
        await browser.close()
    print("REPORTS TEST PASSED")


asyncio.run(main())
