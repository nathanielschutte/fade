"""System → Users (docs/implementation/admin-users.md): an Admin opens
someone's account, turns it off (they're signed out and can't get back in;
their friend's chat stays readable but can't be sent to), turns it back on,
and posts an announcement that everyone sees live. Settings come from the
environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
PW = "correct horse battery"
PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}
errors = []


async def page_for(browser, label, **ctx):
    p = await (await browser.new_context(**ctx)).new_page()
    p.on("pageerror", lambda e: errors.append(f"{label}: {e} {(e.stack or '')[:400]}"))
    await p.goto(BASE)
    return p


async def sign_up(p, name):
    await p.click("#auth-toggle")
    await p.fill("#auth-form input[name=username]", name)
    await p.fill("#auth-form input[name=password]", PW)
    await p.fill("#auth-form input[name=invite_code]", INVITE)
    await p.click("#auth-submit")
    await expect(p.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(p)


async def sign_in(p, name):
    await p.fill("#auth-form input[name=username]", name)
    await p.fill("#auth-form input[name=password]", PW)
    await p.click("#auth-submit")


async def sign_up_or_in(p, name):
    await sign_in(p, name)
    try:
        await expect(p.locator("#app")).to_be_visible(timeout=15000)
    except AssertionError:
        await sign_up(p, name)


async def befriend(asker, asked, name_of_asked, name_of_asker):
    await asker.click("#friends-button")
    await asker.fill("#add-friend-form input[name=username]", name_of_asked)
    await asker.click("#add-friend-form button[type=submit]")
    await expect(asker.locator("#add-friend-note")).to_contain_text("Request sent")
    await asker.click("#friends-dialog [data-close]")
    await asked.click("#friends-button")
    await asked.locator("#incoming-list li", has_text=name_of_asker).locator("button", has_text="Accept").click()
    await asked.click("#friends-dialog [data-close]")


def row(page, name):
    return page.locator("#chat-list .chat-row", has=page.locator(".chat-name", has_text=name))


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await page_for(browser, "ana", viewport={"width": 1200, "height": 850})
        ben = await page_for(browser, "ben", **PHONE)
        await sign_up(ana, ANA)
        await sign_up(ben, BEN)
        await befriend(ana, ben, BEN, ANA)
        await row(ana, BEN).locator(".chat-item").click()
        await ana.fill("#composer-input", "see you at 8")
        await ana.press("#composer-input", "Enter")
        await expect(ana.locator(".msg", has_text="see you at 8")).to_be_visible(timeout=10000)

        admin = await page_for(browser, "admin", viewport={"width": 1200, "height": 900})
        await sign_up_or_in(admin, ADMIN)
        await admin.goto(f"{BASE}/admin#users")
        await expect(admin.locator("#tab-users")).to_be_visible(timeout=10000)
        await expect(admin.locator("#users tr", has_text=BEN)).to_have_count(1, timeout=10000)
        await expect(admin.locator("#u-note")).to_contain_text("accounts in use")

        # Ben's account at a glance: counts and dates, nothing he wrote.
        await admin.locator("#users tr", has_text=BEN).locator(".u-open").click()
        await expect(admin.locator("#u-detail-title")).to_have_text(BEN, timeout=10000)
        await expect(admin.locator("#u-facts")).to_contain_text("Friends · groups")
        await expect(admin.locator("#u-facts")).to_contain_text("Saved at sign-up")
        assert "see you at 8" not in await admin.content()
        await shot(admin, "users-detail", full_page=False)

        # Turn it off, with a reason: two taps.
        await admin.locator("#u-actions button", has_text="Turn account off").click()
        await expect(admin.locator("#u-turn-off")).to_be_visible()
        await admin.fill("#u-reason", "asked for a break")
        await admin.locator("#u-actions button", has_text="Tap again: turn it off").click()
        await expect(admin.locator("#u-detail-status .status-chip")).to_have_text("Turned off", timeout=10000)
        await expect(admin.locator("#u-history")).to_contain_text(f"Turned off by {ADMIN}: “asked for a break”")
        await expect(admin.locator("#act-feed")).to_contain_text(f"turned the account off for {BEN}")

        # Ben is signed out at once, and can't get back in.
        await expect(ben.locator("#auth")).to_be_visible(timeout=15000)
        await sign_in(ben, BEN)
        await expect(ben.locator("#auth-error")).to_contain_text("turned off", timeout=15000)
        await shot(ben, "users-turned-off-phone", full_page=False)

        # Ana keeps the chat, but can't send.
        await expect(row(ana, BEN).locator(".chat-status")).to_have_text("Account turned off", timeout=10000)
        await expect(ana.locator("#deactivated-note")).to_be_visible()
        await expect(ana.locator("#composer-input")).to_be_disabled()
        await expect(ana.locator(".msg", has_text="see you at 8")).to_be_visible()
        await shot(ana, "users-friend-turned-off", full_page=False)

        # Back on: two taps, and Ben signs in with everything.
        await admin.locator("#u-actions button", has_text="Turn account back on").click()
        await admin.locator("#u-actions button", has_text="Tap again: turn it back on").click()
        await expect(admin.locator("#u-detail-status .status-chip")).not_to_have_text("Turned off", timeout=10000)
        await sign_in(ben, BEN)
        await expect(ben.locator("#app")).to_be_visible(timeout=20000)
        await expect(row(ben, ANA)).to_be_visible(timeout=10000)
        await expect(ana.locator("#deactivated-note")).to_be_hidden(timeout=10000)
        await expect(ana.locator("#composer-input")).to_be_enabled()

        # An announcement reaches everyone signed in, live; dismissing hides it there.
        text = f"napsack moved to napsack.io {tag}"
        await admin.fill("#a-body", text)
        await admin.select_option("#a-hours", "24")
        await admin.click("#a-post")
        await expect(admin.locator("#a-current")).to_contain_text(text, timeout=10000)
        await expect(ana.locator("#announcement-text")).to_have_text(text, timeout=10000)
        await expect(ben.locator("#announcement-text")).to_have_text(text, timeout=10000)
        await shot(ben, "announcement-phone", full_page=False)
        await ana.click("#announcement-close")
        await expect(ana.locator("#announcement")).to_be_hidden()
        await ana.reload()
        await expect(ana.locator("#app")).to_be_visible(timeout=15000)
        await asyncio.sleep(1)
        await expect(ana.locator("#announcement")).to_be_hidden()
        # Withdrawn: gone from Ben's screen too.
        await admin.locator("#a-current button", has_text="Withdraw").click()
        await expect(ben.locator("#announcement")).to_be_hidden(timeout=10000)

        # The Users tab at phone width: nothing scrolls sideways.
        phone = await page_for(browser, "admin-phone", **PHONE)
        await sign_up_or_in(phone, ADMIN)
        await phone.goto(f"{BASE}/admin#users")
        await expect(phone.locator("#users tr", has_text=ANA)).to_have_count(1, timeout=10000)
        await shot(phone, "users-list-phone", full_page=False)
        await phone.locator("#users tr", has_text=ANA).locator(".u-open").click()
        await expect(phone.locator("#u-detail-title")).to_have_text(ANA, timeout=10000)
        await asyncio.sleep(0.8)  # (the smooth scroll to the panel)
        overflow = await phone.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        wide = await phone.evaluate("""() => [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > document.documentElement.clientWidth + 1 && !e.closest('.table-scroll')).slice(0, 8).map((e) => e.tagName + '#' + e.id + '.' + e.className + ' ' + Math.round(e.getBoundingClientRect().right))""")
        assert overflow <= 0, f"scrolls sideways by {overflow}px: {wide}"
        await shot(phone, "users-phone", full_page=False)

        assert not errors, errors
        await browser.close()
    print("ADMIN USERS TEST PASSED")


asyncio.run(main())
