"""Long chats load the newest page first and the rest on scrolling up, with
nothing missing, repeated, or out of order, and the view staying in place.
Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import launch, shot, sign_up

tag = uuid.uuid4().hex[:5]
SENDER, READER = f"ola_{tag}", f"rio_{tag}"
COUNT = 130

# Sends real, decryptable messages the way the app does, using the signed-in
# user's own key from the browser, without typing them one by one.
SEND_MANY = """async ([friendName, count]) => {
  const e2e = await import('/crypto.js');
  const keystore = await import('/keystore.js');
  const auth = { Authorization: 'Bearer ' + localStorage.getItem('fade.token') };
  const me = await (await fetch('/api/me', { headers: auth })).json();
  const friend = (await (await fetch('/api/friends', { headers: auth })).json()).find(f => f.username === friendName);
  const identity = await keystore.loadLocal('identity');
  const key = await e2e.pairKey(identity.privateKey, friend.public_key, me.id, friend.id);
  for (let i = 1; i <= count; i++) {
    const ciphertext = await e2e.encryptText(key, `msg ${i}`, me.id, friend.id);
    const r = await fetch(`/api/chats/${friend.id}/messages`, {
      method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ciphertext, format: e2e.FORMAT }) });
    if (!r.ok) throw new Error('send failed ' + r.status);
  }
}"""

TEXTS = "() => [...document.querySelectorAll('#messages .msg')].map(e => e.textContent)"


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        sender = await sign_up(browser, SENDER, viewport={"width": 900, "height": 700})
        reader = await sign_up(browser, READER, viewport={"width": 900, "height": 700})
        await sender.click("#friends-button")
        await sender.fill("#add-friend-form input[name=username]", READER)
        await sender.click("#add-friend-form button[type=submit]")
        await expect(sender.locator("#add-friend-note")).to_contain_text("Request sent")
        await reader.click("#friends-button")
        await reader.locator("#incoming-list button", has_text="Accept").click()
        await reader.click("#friends-dialog [data-close]")
        await expect(reader.locator(".chat-item", has_text=SENDER)).to_be_visible()
        await sender.wait_for_timeout(300)
        await sender.evaluate(SEND_MANY, [READER, COUNT])

        # Opening the chat shows the newest messages, not the whole history.
        await reader.reload()
        await reader.locator(".chat-item", has_text=SENDER).click()
        await expect(reader.locator(".msg", has_text=f"msg {COUNT}")).to_be_visible(timeout=10000)
        first = await reader.evaluate(TEXTS)
        assert 50 <= len(first) < COUNT, f"loaded {len(first)} on open"
        assert "msg 1" not in first
        print(f"opened with the newest {len(first)} of {COUNT}")

        # Scrolling up loads earlier pages and keeps the view in place.
        anchor = reader.locator(".msg", has_text=first[0])
        for _ in range(10):
            texts = await reader.evaluate(TEXTS)
            if len(texts) == COUNT:
                break
            await reader.evaluate("document.querySelector('#messages').scrollTop = 0")
            await expect(reader.locator("#messages .msg")).not_to_have_count(len(texts), timeout=10000)
            if len(texts) == len(first):
                # After the first page back, the old top message is still on screen.
                box = await anchor.bounding_box()
                view = await reader.locator("#messages").bounding_box()
                assert box and view and view["y"] <= box["y"] <= view["y"] + view["height"], (box, view)
        texts = await reader.evaluate(TEXTS)
        assert texts == [f"msg {i}" for i in range(1, COUNT + 1)], texts[:5]
        await expect(reader.locator(".history-edge")).to_contain_text(f"beginning of your chat with {SENDER}")
        await reader.evaluate("document.querySelector('#messages').scrollTop = 0")
        await shot(reader, "pagination-top", full_page=False)
        print(f"scrolled back through all {COUNT}, in order, no repeats")

        # A new message while scrolled back still arrives, and history stays loaded.
        await sender.evaluate(SEND_MANY.replace("`msg ${i}`", "`late ${i}`"), [READER, 1])
        await expect(reader.locator(".msg", has_text="late 1")).to_have_count(1, timeout=10000)
        assert len(await reader.evaluate(TEXTS)) == COUNT + 1
        await browser.close()
    print("PAGINATION TEST PASSED")


asyncio.run(main())
