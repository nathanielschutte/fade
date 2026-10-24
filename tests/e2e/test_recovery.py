"""Getting back in (F2) and account safety (F8), in the browser:
- Sign-up shows a recovery key once; the recovery key restores everything.
- Changing the password keeps history; "sign out other devices" works.
- An admin's reset code gets an account back with a new key and no history.
  Friends see why the safety code changed and choose: compare codes, or
  accept without checking. They can still read their old messages.
Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
PW = "correct horse battery"


async def open_page(browser, **ctx):
    page = await (await browser.new_context(**ctx)).new_page()
    await page.goto(BASE)
    return page


async def sign_up(page, name, password=PW):
    await page.click("#auth-toggle")
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", password)
    await page.fill("#auth-form input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)


async def sign_in(page, name, password):
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", password)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)


async def sign_out(page):
    await page.click("#sign-out")
    await expect(page.locator("#auth")).to_be_visible()


async def recover(page, name, secret, password):
    await page.click("#auth-forgot")
    await page.fill("#recover-form input[name=recover_username]", name)
    await page.fill("#recover-secret", secret)
    await page.fill("#recover-form input[name=new_password]", password)
    await page.fill("#recover-form input[name=new_confirm]", password)
    await page.click("#recover-submit")


async def befriend(asker, asked, name_of_asked, name_of_asker):
    await asker.click("#friends-button")
    await asker.fill("#add-friend-form input[name=username]", name_of_asked)
    await asker.click("#add-friend-form button[type=submit]")
    await expect(asker.locator("#add-friend-note")).to_contain_text("Request sent")
    await asker.click("#friends-dialog [data-close]")
    await asked.click("#friends-button")
    await asked.locator("#incoming-list li", has_text=name_of_asker).locator("button", has_text="Accept").click()
    await asked.click("#friends-dialog [data-close]")


async def send(page, friend, text):
    await page.locator(".chat-item", has_text=friend).click()
    await page.fill("#composer-input", text)
    await page.click("#composer .send")  # works on phones too, where Return is a new line
    await expect(page.locator(".msg", has_text=text)).to_be_visible(timeout=10000)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)

        # Sign-up shows the recovery key once, and won't go away until it's saved.
        ana = await open_page(browser)
        await sign_up(ana, ANA)
        await expect(ana.locator("#recovery-dialog")).to_be_visible(timeout=20000)
        await expect(ana.locator("#recovery-done")).to_be_disabled()
        await ana.keyboard.press("Escape")
        await expect(ana.locator("#recovery-dialog")).to_be_visible()
        await shot(ana, "recovery-key", full_page=False)
        ana_key = await save_recovery_key(ana)
        assert len(ana_key.replace("-", "")) == 32, ana_key
        await expect(ana.locator("#recovery-key")).to_have_text("")       # not left in the page
        await expect(ana.locator("#recovery-nudge")).to_be_hidden()

        ben = await open_page(browser)
        await sign_up(ben, BEN)
        await save_recovery_key(ben)
        cal = await open_page(browser, viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        await sign_up(cal, CAL)
        await save_recovery_key(cal)
        await befriend(ana, ben, BEN, ANA)
        await befriend(cal, ben, BEN, CAL)
        await send(ben, ANA, "before the reset")
        await send(cal, BEN, "cal says hi")
        await send(ben, CAL, "ben to cal, early")
        print("signed up with recovery keys; befriended; texts sent")

        # Ana forgets her password: the recovery key brings everything back.
        await sign_out(ana)
        await recover(ana, ANA, "not a key", "first new password")
        await expect(ana.locator("#recover-error")).to_contain_text("32 letters and numbers")
        await ana.fill("#recover-secret", ana_key.lower().replace("-", " "))   # typed sloppily
        await expect(ana.locator("#recover-kind")).to_contain_text("keep all your messages")
        await ana.click("#recover-submit")
        await expect(ana.locator("#app")).to_be_visible(timeout=20000)
        await ana.locator(".chat-item", has_text=BEN).click()
        await expect(ana.locator(".msg", has_text="before the reset")).to_be_visible(timeout=10000)
        await sign_out(ana)
        await ana.fill("#auth-form input[name=username]", ANA)
        await ana.fill("#auth-form input[name=password]", PW)
        await ana.click("#auth-submit")
        await expect(ana.locator("#auth-error")).to_contain_text("Wrong username or password", timeout=20000)
        await sign_in(ana, ANA, "first new password")
        print("recovery key: back in with history; the old password stopped working")

        # Change password from the profile, with a second device signed in; then sign that device out.
        ana2 = await open_page(browser)
        await sign_in(ana2, ANA, "first new password")
        await ana.click("#my-profile")
        await expect(ana.locator("#security-status")).to_contain_text("Recovery key saved")
        await expect(ana.locator("#security-status")).to_contain_text("Signed in on 1 other device")
        await shot(ana, "profile-security", full_page=False)
        await ana.click("#security-password")
        await ana.fill("#password-form input[name=current_password]", "wrong password")
        await ana.fill("#password-form input[name=change_password]", "second new password")
        await ana.fill("#password-form input[name=change_confirm]", "second new password")
        await ana.click("#password-submit")
        await expect(ana.locator("#password-error")).to_contain_text("current password isn't right", timeout=20000)
        await ana.fill("#password-form input[name=current_password]", "first new password")
        await ana.click("#password-submit")
        await expect(ana.locator("#security-note")).to_contain_text("Password changed. Signed out 1 other device.", timeout=20000)
        await expect(ana2.locator("#auth")).to_be_visible(timeout=10000)         # its socket was closed
        await sign_in(ana2, ANA, "second new password")
        await expect(ana2.locator(".chat-item", has_text=BEN)).to_be_visible()
        await ana.click("#security-sessions")
        await expect(ana.locator("#security-note")).to_have_text("Signed out 1 other device.", timeout=10000)
        await expect(ana2.locator("#auth")).to_be_visible(timeout=10000)
        await ana.click("#profile-dialog [data-close]")
        print("password changed, history kept; other devices signed out")

        # Ben loses everything: an admin issues a reset code.
        admin = await open_page(browser)
        await admin.fill("#auth-form input[name=username]", ADMIN)
        await admin.fill("#auth-form input[name=password]", PW)
        await admin.click("#auth-submit")
        try:
            await expect(admin.locator("#app")).to_be_visible(timeout=15000)
        except AssertionError:
            await sign_up(admin, ADMIN)
            await save_recovery_key(admin)
        await admin.goto(f"{BASE}/admin#users")
        await admin.locator("#users tr", has_text=BEN).locator(".u-open").click()
        await expect(admin.locator("#u-detail-title")).to_have_text(BEN, timeout=10000)
        await admin.locator("#u-actions button", has_text="Reset password").click()
        await admin.locator("#u-actions button", has_text="Tap again: issue a reset code").click()
        await expect(admin.locator("#reset-result")).to_contain_text(f"Reset code for {BEN}", timeout=10000)
        code = (await admin.locator(".reset-code").text_content()).strip()
        assert len(code) == 19, code
        await shot(admin, "admin-reset-code", full_page=False)

        await sign_out(ben)
        await recover(ben, BEN, code, "ben's new password")
        await expect(ben.locator("#recover-kind")).to_contain_text("messages from before can't be read")
        await expect(ben.locator("#app")).to_be_visible(timeout=20000)
        await save_recovery_key(ben)                                             # a new key for the new account key
        await ben.locator(".chat-item", has_text=ANA).click()
        await expect(ben.locator(".msg.undecryptable", has_text="before your account was reset")).to_be_visible(timeout=10000)
        print("reset code: back in with a new key; old messages explained")

        # Ana sees why the code changed, still reads the old messages, and verifies by safety code.
        await ana.locator(".chat-item", has_text=BEN).click()
        await expect(ana.locator("#key-warning")).to_be_visible(timeout=10000)
        await expect(ana.locator("#key-warning-why")).to_contain_text("an admin reset")
        await expect(ana.locator("#composer-input")).to_be_disabled()
        await expect(ana.locator(".msg", has_text="before the reset")).to_be_visible()
        await shot(ana, "key-changed-reset", full_page=False)
        await ana.click("#key-compare")
        await expect(ana.locator("#safety-trust-row")).to_be_visible()
        await expect(ana.locator("#safety-code")).not_to_have_text("…")
        ana_code = await ana.locator("#safety-code").text_content()
        await ben.click("#safety-button")
        await expect(ben.locator("#safety-code")).not_to_have_text("…")
        assert await ben.locator("#safety-code").text_content() == ana_code, "both see the new code"
        await expect(ben.locator("#safety-trust-row")).to_be_hidden()
        await ben.click("#safety-dialog [data-close]")
        await ana.click("#safety-trust")
        await expect(ana.locator("#key-warning")).to_be_hidden(timeout=10000)
        await expect(ana.locator(".msg", has_text="before the reset")).to_be_visible()
        await send(ana, BEN, "welcome back")
        await expect(ben.locator(".msg", has_text="welcome back")).to_be_visible(timeout=10000)
        print("verified the new key by safety code; old messages still readable")

        # Cal accepts without checking: two taps. (On a phone, back to the list first.)
        await cal.click("#back-button")
        await cal.locator(".chat-item", has_text=BEN).click()
        await expect(cal.locator("#key-warning")).to_be_visible(timeout=10000)
        await shot(cal, "key-changed-phone", full_page=False)
        await cal.click("#key-accept")
        await expect(cal.locator("#key-accept")).to_have_text("Tap again to accept the new key")
        await expect(cal.locator("#key-warning")).to_be_visible()
        await cal.click("#key-accept")
        await expect(cal.locator("#key-warning")).to_be_hidden(timeout=10000)
        await expect(cal.locator(".msg", has_text="ben to cal, early")).to_be_visible()
        await cal.fill("#composer-input", "accepted unchecked")
        await cal.click("#composer .send")  # a phone: Return is a new line there
        await expect(cal.locator(".msg", has_text="accepted unchecked")).to_be_visible(timeout=10000)
        await expect(ben.locator(".chat-item", has_text=CAL)).to_be_visible()
        await ben.locator(".chat-item", has_text=CAL).click()
        await expect(ben.locator(".msg", has_text="accepted unchecked")).to_be_visible(timeout=10000)
        overflow = await cal.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"scrolls sideways by {overflow}px"
        print("accepted without checking; new messages flow both ways")

        await browser.close()
    print("RECOVERY TEST PASSED")


asyncio.run(main())
