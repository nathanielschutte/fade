"""Editing sent texts (X29): tap your own text for Edit (for 15 minutes), and
the friend or group sees the new version live, marked "Edited", with every
version a tap away. Someone else's text has Copy and Reply, not Edit. Group
edits are sealed for the members the text went to. Settings come from the
environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import launch, no_placeholders, shot, PHONE, befriend, row, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
GROUP = f"Plans {tag}"
errors = []
CLIPBOARD = ["clipboard-read", "clipboard-write"]


def bubble(page, text):
    return page.locator("#messages .msg", has=page.locator(".msg-body", has_text=text))


async def send(page, text):
    await page.fill("#composer-input", text)
    await page.click("#composer .send")  # on a phone, Return is a new line
    await expect(bubble(page, text)).to_be_visible(timeout=10000)


async def edit(page, old, new):
    await bubble(page, old).click()
    await page.locator(".msg-actions button", has_text="Edit").click()
    await expect(page.locator("#reply-bar")).to_be_visible()
    await expect(page.locator("#reply-text")).to_have_text("Editing your message")
    await expect(page.locator("#composer-input")).to_have_value(old)
    await page.fill("#composer-input", new)
    await page.click("#composer .send")
    await expect(page.locator("#reply-bar")).to_be_hidden()


async def history(page, text, versions):
    await bubble(page, text).locator(".edited-mark").click()
    await expect(page.locator("#edits-dialog")).to_be_visible()
    await expect(page.locator("#edits-list .edit-text")).to_have_text(versions, timeout=10000)
    await no_placeholders(page, "#edits-dialog")
    await page.click("#edits-dialog [data-close]")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, permissions=CLIPBOARD)
        ben = await sign_up(browser, BEN, errors=errors, permissions=CLIPBOARD, **PHONE)
        await befriend(ana, ben, BEN, ANA)
        await row(ana, BEN).click()
        await row(ben, ANA).click()

        # Ana fixes a text; Ben sees the new one live, marked Edited.
        await send(ana, "meet at 6")
        await expect(bubble(ben, "meet at 6")).to_be_visible(timeout=10000)
        await edit(ana, "meet at 6", "meet at 7 actually")
        await expect(bubble(ana, "meet at 7 actually").locator(".edited-mark")).to_be_visible(timeout=10000)
        await expect(bubble(ben, "meet at 7 actually").locator(".edited-mark")).to_have_text("Edited", timeout=10000)
        await expect(ben.locator("#messages .msg-body", has_text="meet at 6")).to_have_count(0)
        await shot(ben, "edited-phone", full_page=False)
        await history(ben, "meet at 7 actually", ["meet at 6", "meet at 7 actually"])
        # Again: three versions, all kept.
        await edit(ana, "meet at 7 actually", "meet at 7:30")
        await expect(bubble(ben, "meet at 7:30")).to_be_visible(timeout=10000)
        await history(ana, "meet at 7:30", ["meet at 6", "meet at 7 actually", "meet at 7:30"])
        await shot(ana, "edit-history", full_page=False)
        print("a text edited twice: the newest shows, every version is kept")

        # Someone else's text: Copy and Reply, no Edit.
        await send(ben, "ok see you")
        await expect(bubble(ana, "ok see you")).to_be_visible(timeout=10000)
        await bubble(ana, "ok see you").click()
        actions = ana.locator(".msg-actions")
        await expect(actions.locator("button", has_text="Copy")).to_be_visible()
        await expect(actions.locator("button", has_text="Edit")).to_have_count(0)
        await actions.locator("button", has_text="Copy").click()
        await expect(ana.locator("#toast-text")).to_have_text("Copied.")
        assert await ana.evaluate("navigator.clipboard.readText()") == "ok see you"

        # Cancelling an edit leaves the text alone and empties the box.
        await bubble(ana, "meet at 7:30").click()
        await ana.locator(".msg-actions button", has_text="Edit").click()
        await ana.click("#reply-cancel")
        await expect(ana.locator("#composer-input")).to_have_value("")
        await expect(bubble(ana, "meet at 7:30")).to_be_visible()

        # It lasts: after a reload, and in the chat list.
        await ben.reload()
        await expect(ben.locator("#app")).to_be_visible(timeout=20000)
        await ben.click("#back-button") if await ben.locator("#back-button").is_visible() else None
        await expect(row(ben, ANA).locator(".chat-status")).to_contain_text("ok see you", timeout=10000)
        await row(ben, ANA).click()
        await expect(bubble(ben, "meet at 7:30").locator(".edited-mark")).to_be_visible(timeout=10000)
        print("Copy for anyone's text, Edit only for yours; edits last")

        # A group text, edited: sealed for the members it went to.
        await ana.click("#start-button")
        await ana.fill("#new-group-name", GROUP)
        await ana.locator("#new-group-friends label", has_text=BEN).locator("input").check()
        await ana.click("#new-group-submit")
        await expect(ana.locator("#chat-title")).to_have_text(GROUP)
        await send(ana, "bring snacks")
        await ben.click("#back-button")
        await row(ben, GROUP).click()
        await expect(bubble(ben, "bring snacks")).to_be_visible(timeout=10000)
        await edit(ana, "bring snacks", "bring snacks and water")
        await expect(bubble(ben, "bring snacks and water").locator(".edited-mark")).to_be_visible(timeout=10000)
        await history(ben, "bring snacks and water", ["bring snacks", "bring snacks and water"])
        print("group texts edit the same way")

        assert not errors, errors
        await browser.close()
    print("EDITS TEST PASSED")


asyncio.run(main())
