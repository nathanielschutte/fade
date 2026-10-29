"""Changing your username (X30): from your profile, with your password. The
private key is locked again under the new name (the username salts the
password), so signing in with the new name still opens every old message.
The old name stays yours: it can't be signed up with, signing in with it
says it changed, and adding a friend by it finds you. Friends see "was
@old". Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import INVITE, launch, no_placeholders, shot, PASSWORD, befriend, row, fill_sign_up, open_page, sign_in

tag = uuid.uuid4().hex[:5]
ANA, ANNA, BEN, CAL = f"ana_{tag}", f"anna_{tag}", f"ben_{tag}", f"cal_{tag}"
errors = []


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana, ben = await open_page(browser, errors), await open_page(browser, errors)
        await fill_sign_up(ana, ANA)
        await fill_sign_up(ben, BEN)
        await befriend(ana, ben, BEN, ANA)
        await row(ana, BEN).click()
        await ana.fill("#composer-input", "before the rename")
        await ana.press("#composer-input", "Enter")
        await row(ben, ANA).click()
        await expect(ben.locator(".msg-body", has_text="before the rename")).to_be_visible(timeout=10000)

        # Ana changes her username in her profile, with her password.
        await ana.click("#my-profile")
        await expect(ana.locator("#username-status")).to_have_text(f"Your username is @{ANA}.", timeout=10000)
        await ana.click("#username-change")
        await ana.fill("#username-form input[name=username]", BEN)  # taken
        await ana.fill("#username-form input[name=password]", PASSWORD)
        await ana.click("#username-submit")
        await expect(ana.locator("#username-error")).to_have_text("That username is taken.", timeout=20000)
        await ana.fill("#username-form input[name=username]", ANNA)
        await ana.fill("#username-form input[name=password]", "wrong password!")
        await ana.click("#username-submit")
        await expect(ana.locator("#username-error")).to_contain_text("password", timeout=20000)
        await ana.fill("#username-form input[name=password]", PASSWORD)
        await ana.click("#username-submit")
        await expect(ana.locator("#security-note")).to_have_text(f"Your username is now @{ANNA}. Sign in with it from now on.", timeout=20000)
        await expect(ana.locator("#profile-sub")).to_contain_text(f"@{ANNA} · was @{ANA}")
        await expect(ana.locator("#username-status")).to_contain_text("You can change it again on")
        await expect(ana.locator("#username-change")).to_be_hidden()  # once a week
        await expect(ana.locator("#my-name")).to_have_text(ANNA)
        await no_placeholders(ana, "#profile-dialog")
        await shot(ana, "username-changed", full_page=False)
        await ana.click("#profile-dialog [data-close]")
        print("renamed with the password; once a week")

        # Ben sees the new name, "was @ana", and a note in the chat.
        await expect(row(ben, ANNA)).to_be_visible(timeout=10000)
        await row(ben, ANNA).click()
        await expect(ben.locator("#chat-sub")).to_contain_text(f"was @{ANA}")
        await expect(ben.locator(".rename-note")).to_have_text(f"{ANA} is now @{ANNA}")
        await shot(ben, "username-friend-sees", full_page=False)

        # Signing in: the old name says it changed; the new one opens everything.
        await ana.click("#sign-out")
        await sign_in(ana, ANA, wait=False)
        await expect(ana.locator("#auth-error")).to_have_text("That username was changed. Sign in with the new one.", timeout=20000)
        await sign_in(ana, ANNA, wait=False)
        await expect(ana.locator("#app")).to_be_visible(timeout=20000)
        await row(ana, BEN).click()
        await expect(ana.locator(".msg-body", has_text="before the rename")).to_be_visible(timeout=10000)
        print("old name says it changed; the new one signs in, history and all")

        # The old name stays hers: nobody can sign up with it, and it finds her.
        cal = await open_page(browser, errors)
        await cal.click("#auth-toggle")
        await cal.fill("#auth-form input[name=username]", ANA)
        await cal.fill("#auth-form input[name=password]", PASSWORD)
        await cal.fill("#auth-form input[name=invite_code]", INVITE)
        await cal.click("#auth-submit")
        await expect(cal.locator("#auth-error")).to_have_text("That username is taken.", timeout=20000)
        await cal.click("#auth-toggle")
        await fill_sign_up(cal, CAL)
        await cal.click("#friends-button")
        await cal.fill("#add-friend-form input[name=username]", ANA)
        await cal.click("#add-friend-form button[type=submit]")
        await expect(cal.locator("#add-friend-note")).to_have_text(f"Request sent to {ANNA} (was @{ANA}).")
        print("the old name is reserved and still finds her")

        assert not errors, errors
        await browser.close()
    print("USERNAME TEST PASSED")


asyncio.run(main())
