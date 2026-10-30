"""Team Napsack (docs/implementation/team-napsack.md): napsack's own account
writes to someone who isn't its friend; their app lists the chat, decrypts
the message with the same scheme as any friend's, and keeps the chat
read-only. Settings come from the environment; see common.py."""
import asyncio
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, launch, shot, PHONE, row, sign_up_or_in

errors = []

TRY = """async (id) => {
  const r = await fetch(`/api/admin/occasions/${id}/try`,
    { method: 'POST', headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } });
  return [r.status, await r.json()];
}"""


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        p = await (await browser.new_context(**PHONE)).new_page()
        p.on("pageerror", lambda e: errors.append(str(e)))
        await p.goto(BASE)
        await sign_up_or_in(p, ADMIN)

        # Try the first occasion: it comes to you, now, from Team Napsack.
        status, body = await p.evaluate(TRY, "test-hello")
        assert status == 200 and body["sent"], (status, body)
        await expect(row(p, "Team Napsack")).to_be_visible(timeout=10000)
        await expect(row(p, "Team Napsack").locator(".chat-status")).to_contain_text("first message", timeout=10000)
        await row(p, "Team Napsack").locator(".chat-item").click()
        # (The newest: on staging the Admin account stays, with each earlier run's message too.)
        await expect(p.locator(".msg", has_text=f"Hi {ADMIN}! This is Team Napsack's first message").last).to_be_visible(timeout=10000)
        # Read-only: a note, and nothing to send with.
        await expect(p.locator("#deactivated-note")).to_contain_text("You can't reply here")
        await expect(p.locator("#composer-input")).to_be_disabled()
        await expect(p.locator("#camera-button")).to_be_disabled()
        await asyncio.sleep(0.5)
        # A two-word name stays on one line in the phone's header.
        title = await p.locator("#chat-title").bounding_box()
        assert title["height"] < 40, title
        await shot(p, "team-chat-phone", full_page=False)
        # No profile behind its name.
        await p.click("#chat-title")
        await asyncio.sleep(0.5)
        await expect(p.locator("#profile-dialog")).not_to_be_visible()

        # A birthday one fills in your name; it isn't a friend you can put in a group.
        status, body = await p.evaluate(TRY, "birthday-wish")
        assert status == 200, body
        await expect(p.locator(".msg", has_text=f"Happy birthday, {ADMIN}!").last).to_be_visible(timeout=10000)
        await p.click("#back-button")
        await p.click("#start-button")
        await expect(p.locator("#new-group-friends")).not_to_contain_text("Team Napsack")

        assert not errors, errors
        await browser.close()
    print("TEAM TEST PASSED")


asyncio.run(main())
