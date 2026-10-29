"""napsack opened from the iPhone Home Screen: it draws under the status bar,
so everything must stay clear of it (style.css, "installed on the Home
Screen"). Chromium stands in an iPhone 16 Pro's safe areas (59 pt at the top
for the status bar and Dynamic Island, 34 pt at the bottom) and the test checks
that nothing you need to tap sits under them. Settings come from the
environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
TOP, BOTTOM = 59, 34
IPHONE = {"viewport": {"width": 393, "height": 852}, "is_mobile": True, "has_touch": True, "device_scale_factor": 3}


# Every problem the app reports also goes to the console as "[napsack] ...".
PROBLEMS = []


def watch(page, who):
    page.on("console", lambda m: m.type in ("warning", "error") and m.text.startswith("[napsack]")
            and PROBLEMS.append(f"{who}: {m.text}"))
    page.on("pageerror", lambda e: PROBLEMS.append(f"{who}: uncaught {e}"))
    return page


async def installed_page(browser):
    page = watch(await (await browser.new_context(**IPHONE)).new_page(), "installed")
    cdp = await page.context.new_cdp_session(page)
    await cdp.send("Emulation.setSafeAreaInsetsOverride", {"insets": {"top": TOP, "bottom": BOTTOM, "left": 0, "right": 0}})
    await page.goto(BASE)
    return page


async def top_of(page, selector):
    # (It may still be drawing: over a real network the page takes a moment.)
    await expect(page.locator(selector).first).to_be_visible(timeout=15000)
    box = await page.locator(selector).first.bounding_box()
    assert box, f"{selector} isn't on screen"
    return box["y"]


async def bottom_of(page, selector):
    box = await page.locator(selector).first.bounding_box()
    return box["y"] + box["height"]


async def sign_up(page, name):
    await page.click("#auth-toggle")
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", "correct horse battery")
    await page.fill("#auth-form input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(page)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw, full=True)
        ana = await installed_page(browser)
        assert await ana.evaluate("getComputedStyle(document.querySelector('.auth')).paddingTop") != "0px"
        assert await top_of(ana, ".wordmark") >= TOP, "sign-in screen under the status bar"
        await sign_up(ana, ANA)

        # The chat list header, and the tabs above the home indicator.
        assert await top_of(ana, ".list-pane .bar") >= TOP
        assert await top_of(ana, "#friends-button") >= TOP
        assert await bottom_of(ana, "#tabs") <= 852, "tabs off screen"
        # Pinned to the screen, not sized from 100dvh, which an installed iPhone
        # app gets wrong when a page first opens: the tabs sit on the bottom edge.
        assert await ana.evaluate("getComputedStyle(document.querySelector('.app')).position") == "fixed"
        assert await bottom_of(ana, "#tabs") == 852, "tabs not on the bottom edge"
        for tab in ("#tab-chats", "#tab-camera", "#tab-profile"):
            assert await bottom_of(ana, tab) <= 852 - BOTTOM, f"{tab} under the home indicator"
        await shot(ana, "installed-list", full_page=False)

        # In a chat: the back button and the title are tappable.
        ben = await (await browser.new_context()).new_page()
        await ben.goto(BASE)
        await sign_up(ben, BEN)
        await ana.click("#friends-button")
        await ana.fill("#add-friend-form input[name=username]", BEN)
        await ana.click("#add-friend-form button[type=submit]")
        await expect(ana.locator("#add-friend-note")).to_contain_text("Request sent")
        await ana.click("#friends-dialog [data-close]")
        await ben.click("#friends-button")
        await ben.locator("#incoming-list li", has_text=ANA).locator("button", has_text="Accept").click()
        await ana.locator(".chat-item", has_text=BEN).click()
        await expect(ana.locator("#back-button")).to_be_visible()  # a phone opens the chat after a beat (double tap)
        assert await top_of(ana, "#back-button") >= TOP, "back button under the status bar"
        assert await top_of(ana, "#chat-title") >= TOP
        # The composer's padding fills the home-indicator area; what you tap sits above it.
        for target in ("#composer-input", "#composer .send", "#camera-button"):
            assert await bottom_of(ana, target) <= 852 - BOTTOM, f"{target} under the home indicator"
        await shot(ana, "installed-chat", full_page=False)
        await ana.click("#back-button")
        await expect(ana.locator(".chat-item", has_text=BEN)).to_be_visible()

        # The Profile tab starts below the status bar and ends above the tabs.
        await ana.click("#tab-profile")
        await expect(ana.locator("#profile-dialog")).to_be_visible()
        assert await top_of(ana, "#profile-name") >= TOP, "profile under the status bar"
        assert await bottom_of(ana, "#profile-dialog") <= await top_of(ana, "#tabs") + 1, "profile over the tabs"
        await shot(ana, "installed-profile", full_page=False)
        await ana.click("#tab-chats")
        # Sheets: their close buttons stay below the status bar.
        await ana.click("#friends-button")
        assert await top_of(ana, "#friends-dialog [data-close]") >= TOP, "close button under the status bar"
        await ana.click("#friends-dialog [data-close]")

        # In a normal browser tab there are no insets, and nothing moves.
        plain = await (await browser.new_context(**IPHONE)).new_page()
        await plain.goto(BASE)
        assert await plain.evaluate("getComputedStyle(document.querySelector('.app')).paddingTop") == "0px"

        # iPhone Safari outside the Home Screen has no notifications at all: napsack
        # must work without them, and without reporting problems about it.
        bare_ctx = await browser.new_context(**IPHONE)
        await bare_ctx.add_init_script("delete window.Notification; delete window.PushManager;")
        bare = watch(await bare_ctx.new_page(), "no-notifications")
        await bare.goto(BASE)
        await sign_up(bare, f"cal_{tag}")
        assert await bare.evaluate("typeof Notification") == "undefined"
        await bare.reload()
        await expect(bare.locator("#app")).to_be_visible(timeout=20000)
        await bare.click("#tab-profile")
        await expect(bare.locator("#push-status")).to_have_text("This browser can't show notifications.")
        await bare.wait_for_timeout(1000)
        assert not PROBLEMS, PROBLEMS

        await browser.close()
    print("INSTALLED APP TEST PASSED")


asyncio.run(main())
