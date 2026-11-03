"""Deleting your own account in the web app (deletion.rs, F22): the dialog
says what goes, the last button works only once the password is filled in and
the username typed exactly, a wrong password is refused, and then everything
goes: Ana is signed out with nothing kept, can't sign in again, and her friend
Ben's chat with her disappears from his list. The API's rules are in the smoke
test (check_deletion). Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import PASSWORD, befriend, launch, row, shot, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
errors = []


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors)
        ben = await sign_up(browser, BEN, errors=errors)
        await befriend(ben, ana, ANA, BEN)
        await row(ben, ANA).click()
        await ben.fill("#composer-input", "see you soon")
        await ben.press("#composer-input", "Enter")
        await expect(row(ana, BEN)).to_contain_text("see you soon", timeout=10000)

        await ana.click("#my-profile")
        await ana.click("#delete-account")
        dialog = ana.locator("#delete-dialog")
        await expect(dialog).to_be_visible()
        await expect(dialog).to_contain_text("can't be undone")
        submit = ana.locator("#delete-submit")
        await expect(submit).to_be_disabled()
        await ana.fill("#delete-form input[name=delete_password]", "not my password")
        await ana.fill("#delete-form input[name=delete_username]", BEN)          # not hers
        await expect(submit).to_be_disabled()
        await ana.fill("#delete-form input[name=delete_username]", ANA.upper())  # any case
        await expect(submit).to_be_enabled()
        await shot(ana, "delete-account", full_page=False)
        await submit.click()
        await expect(ana.locator("#delete-error")).to_contain_text("current password isn't right", timeout=20000)
        await expect(row(ben, ANA)).to_be_visible()                               # nothing happened
        print("delete account: the button waits for both fields; a wrong password is refused")

        await ana.fill("#delete-form input[name=delete_password]", PASSWORD)
        await submit.click()
        await expect(ana.locator("#auth")).to_be_visible(timeout=20000)
        await expect(ana.locator("#auth-error")).to_contain_text("Your account was deleted")
        await expect(row(ben, ANA)).to_have_count(0, timeout=10000)               # live, without a reload
        await ana.fill("#auth-form input[name=username]", ANA)
        await ana.fill("#auth-form input[name=password]", PASSWORD)
        await ana.click("#auth-submit")
        await expect(ana.locator("#auth-error")).to_contain_text("Wrong username or password", timeout=20000)
        print("deleted: signed out, can't sign in again, and her friend's chat with her is gone")

        assert not errors, errors
        print("DELETE ACCOUNT TEST PASSED")
        await browser.close()


asyncio.run(main())
