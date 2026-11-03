"""Easier sign-in (F23) on the web: a strength hint while a new password is
chosen (sign-up and changing it), and the recovery key downloadable as a file
that says what it is. (Password managers: the forms say `username`,
`current-password`, and `new-password`; that's in the HTML.) Settings come from
the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import fill_sign_up, launch, open_page

tag = uuid.uuid4().hex[:5]
ANA = f"ana_{tag}"
errors = []


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        page = await open_page(browser, errors=errors)
        await page.click("#auth-toggle")
        hint = page.locator("#password-strength")
        password = page.locator("#auth-form input[name=password]")
        await expect(password).to_have_attribute("autocomplete", "new-password")
        for typed, words, level in [
            ("short", "Too short", "short"),
            ("password", "Easy to guess", "weak"),
            ("lowercase", "Weak", "weak"),
            ("Mixed1case", "Good", "good"),
            ("longer lowercase", "Strong", "strong"),
        ]:
            await password.fill(typed)
            await expect(hint).to_contain_text(words)
            await expect(hint).to_have_attribute("data-level", level)
        await page.click("#auth-toggle")
        await expect(hint).to_be_hidden()                                       # not when signing in
        await expect(password).to_have_attribute("autocomplete", "current-password")
        print("strength: a hint for new passwords only, from too short to strong")

        # Sign up; the recovery key downloads as a file naming the account and what it's for.
        await page.click("#auth-toggle")
        await fill_sign_up(page, ANA, toggle=False, save_key=False)
        await expect(page.locator("#recovery-dialog")).to_be_visible(timeout=20000)
        key = (await page.locator("#recovery-key").text_content()).strip()
        async with page.expect_download() as info:
            await page.click("#recovery-download")
        download = await info.value
        assert download.suggested_filename == "napsack-recovery-key.txt", download.suggested_filename
        text = open(await download.path()).read()
        assert key in text and ANA in text and "Forgot your password?" in text, text
        print("recovery key: downloads as napsack-recovery-key.txt, with the key and what it's for")

        assert not errors, errors
        print("SIGN IN HELP TEST PASSED")
        await browser.close()


asyncio.run(main())
