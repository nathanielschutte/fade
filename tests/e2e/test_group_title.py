"""A group's name in the chat header shows in full when there's room (X38: it
was cut to its first letters, "Rats" as "R..."). Phone and desktop widths.
Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import befriend, launch, row, shot, sign_up, PHONE

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
errors = []

# The title's text fits: nothing is hidden behind the ellipsis.
FITS = "e => e.scrollWidth <= e.clientWidth + 1"


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, **PHONE)
        ben = await sign_up(browser, BEN, errors=errors)
        await befriend(ana, ben, BEN, ANA)
        async def fits(page, name):
            await expect(page.locator("#chat-title")).to_have_text(name)
            assert await page.locator("#chat-title").evaluate(FITS), (name, await page.locator("#chat-title").evaluate("e => [e.scrollWidth, e.clientWidth]"))
        # Ana (phone) makes one, Ben (desktop) the other; each header is checked on both.
        for name, maker, friend, other in (("Rats", ana, BEN, ben), (f"Dusty Relics {tag}", ben, ANA, ana)):
            await maker.click("#start-button")
            await maker.fill("#new-group-name", name)
            await maker.locator("#new-group-friends label", has_text=friend).locator("input").check()
            await maker.click("#new-group-submit")
            await fits(maker, name)
            await expect(row(other, name)).to_be_visible(timeout=15000)
            await row(other, name).click()
            await fits(other, name)
            await shot(ana, f"group-title-phone-{len(name)}", full_page=False)
            await ana.click("#back-button")
        # A name too long for a phone still ends in an ellipsis, and nothing spills off the screen.
        long = f"A very long group name for phones {tag}"[:40]  # (names stop at 40)
        await ana.click("#start-button")
        await ana.fill("#new-group-name", long)
        await ana.locator("#new-group-friends label", has_text=BEN).locator("input").check()
        await ana.click("#new-group-submit")
        await expect(ana.locator("#chat-title")).to_have_text(long)
        assert not await ana.locator("#chat-title").evaluate(FITS), "a long name is cut with an ellipsis"
        assert await ana.evaluate("document.documentElement.scrollWidth <= innerWidth"), "the header stays on screen"
        print("group names show in full in the chat header, phone and desktop; a long one ends in an ellipsis")
        assert not errors, errors
        await browser.close()
    print("GROUP TITLE TEST PASSED")


asyncio.run(main())
