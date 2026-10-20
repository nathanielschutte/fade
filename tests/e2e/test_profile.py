"""Profiles: your own (friends and counts) and a friend's (what you share),
opened from the Friends sheet and from a chat's title.
Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"


async def register(browser, name, **ctx):
    page = await (await browser.new_context(**ctx)).new_page()
    await page.goto(BASE)
    await page.click("#auth-toggle")
    await page.fill("input[name=username]", name)
    await page.fill("input[name=password]", "correct horse battery")
    await page.fill("input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)
    return page


async def befriend(asker, asked, name_of_asked, name_of_asker):
    await asker.click("#friends-button")
    await asker.fill("#add-friend-form input[name=username]", name_of_asked)
    await asker.click("#add-friend-form button[type=submit]")
    await expect(asker.locator("#add-friend-note")).to_contain_text("Request sent")
    await asker.click("#friends-dialog [data-close]")
    await asked.click("#friends-button")
    await asked.locator("#incoming-list li", has_text=name_of_asker).locator("button", has_text="Accept").click()
    await asked.click("#friends-dialog [data-close]")


def stat(page, label):
    return page.locator("#profile-stats dt", has_text=label).locator("xpath=following-sibling::dd[1]")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await register(browser, ANA)
        ben = await register(browser, BEN)
        cal = await register(browser, CAL, viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        await befriend(ana, ben, BEN, ANA)
        await befriend(ana, cal, CAL, ANA)
        await befriend(ben, cal, CAL, BEN)

        # Ana sends Ben two texts.
        await ana.locator(".chat-item", has_text=BEN).click()
        for text in ("hey", "profile test"):
            await ana.fill("#composer-input", text)
            await ana.press("#composer-input", "Enter")
        await expect(ana.locator(".msg", has_text="profile test")).to_be_visible()

        # Ana's own profile, from the Friends sheet.
        await ana.click("#friends-button")
        await ana.click("#my-profile")
        await expect(ana.locator("#profile-name")).to_have_text(ANA)
        await expect(ana.locator("#profile-sub")).to_contain_text("Joined")
        await expect(stat(ana, "Texts sent")).to_have_text("2")
        await expect(stat(ana, "Friends")).to_have_text("2")
        await expect(ana.locator("#profile-people .person-name")).to_have_text([BEN, CAL])
        await shot(ana, "profile-mine", full_page=False)

        # Click through to Ben's profile.
        await ana.locator("#profile-people .person-link", has_text=BEN).click()
        await expect(ana.locator("#profile-name")).to_have_text(BEN)
        await expect(ana.locator("#profile-sub")).to_contain_text("Friends since")
        await expect(stat(ana, "Texts between you")).to_have_text("2")
        await expect(stat(ana, "Their friends")).to_have_text("2")
        await expect(ana.locator("#profile-people-title")).to_have_text("Friends you share")
        await expect(ana.locator("#profile-people .person-name")).to_have_text([CAL])
        await shot(ana, "profile-friend", full_page=False)

        # "Message" opens the chat.
        await ana.click("#profile-actions button")
        await expect(ana.locator("#profile-dialog")).not_to_be_visible()
        await expect(ana.locator("#chat-title")).to_have_text(BEN)

        # On a phone, the chat title opens the friend's profile and nothing overflows.
        await cal.locator(".chat-item", has_text=ANA).click()
        await cal.click("#chat-title")
        await expect(cal.locator("#profile-name")).to_have_text(ANA)
        await expect(stat(cal, "Texts between you")).to_have_text("0")
        await expect(stat(cal, "First message")).to_have_text("—")
        await expect(cal.locator("#profile-people .person-name")).to_have_text([BEN])
        overflow = await cal.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"profile scrolls sideways by {overflow}px"
        await shot(cal, "profile-phone", full_page=False)
        await browser.close()
    print("PROFILE TEST PASSED")


asyncio.run(main())
