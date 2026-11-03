"""The chat list and an open chat follow what happens in place (speed: Nate,
2026-11-02). A message changes its row, the unread marker, and the tab's
count without the list being fetched again, and reading clears them; typing
changes one row; the same for a group. Another device of mine reading a chat
clears it there too. Rows and messages that didn't change stay the very same
elements: a new message is a new row, and a reaction doesn't rebuild the
message it's on. Settings come from the environment; see common.py."""
import asyncio, re, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, launch, shot, befriend, row, sign_up, type_a_while

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"
GROUP = f"Lake {tag}"
errors = []


async def api(page, path, method="GET", body=None):
    return await page.evaluate("""async ([path, method, body]) => {
      const r = await fetch('/api' + path, { method, headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token'),
        'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
      return r.json();
    }""", [path, method, body])


async def say(page, text):
    await page.fill("#composer-input", text)
    await page.press("#composer-input", "Enter")
    await expect(page.locator("#messages .msg", has_text=text)).to_be_visible(timeout=10000)


def probe(locator):
    """Marks the element `locator` finds now, to tell later whether it's still the same one."""
    return locator.evaluate("(e) => { e.dataset.probe = 'kept'; }")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ana = await sign_up(browser, ANA, errors=errors, label="ana", viewport={"width": 1100, "height": 760})
        ben = await sign_up(browser, BEN, errors=errors, label="ben", viewport={"width": 1100, "height": 760})
        await befriend(ana, ben, BEN, ANA)
        ben_id = (await api(ben, "/me"))["id"]
        await api(ana, "/groups", "POST", {"name": GROUP, "member_ids": [ben_id]})
        # Ana's other tab, the same account: a second device of hers.
        ana2 = await ana.context.new_page()
        ana2.on("pageerror", lambda e: errors.append(f"ana2: {e}"))
        await ana2.goto(BASE)
        for page in (ana, ana2):
            await expect(row(page, BEN)).to_be_visible(timeout=10000)
            await expect(row(page, GROUP)).to_be_visible(timeout=10000)
        await expect(row(ben, GROUP)).to_be_visible(timeout=10000)
        await expect(row(ana, GROUP).locator(".chat-status")).to_contain_text("created the group", timeout=10000)

        # From here on, Ana's tab never fetches the chat list or groups again.
        fetched = []
        ana.on("request", lambda r: r.method == "GET" and r.url.split("?")[0].endswith(("/api/friends", "/api/groups"))
               and fetched.append(r.url))
        await probe(row(ana, BEN))
        await probe(row(ana, GROUP))

        # Ben writes three texts: Ana's row shows the last, unread, and the tab counts them.
        await row(ben, ANA).locator(".chat-item").click()
        for text in ("first", "second", "third"):
            await say(ben, text)
        status = row(ana, BEN).locator(".chat-status")
        await expect(status).to_have_text("third", timeout=10000)
        await expect(row(ana, BEN).locator(".chat-item")).to_have_class(re.compile(r"\bhas-unread\b"), timeout=10000)
        await expect(ana).to_have_title(re.compile(r"^\(3\) napsack"), timeout=10000)
        await expect(ana2).to_have_title(re.compile(r"^\(3\) napsack"), timeout=10000)
        # Ben types: the row says so.
        await type_a_while(ben)
        await expect(status).to_have_text("typing…", timeout=5000)
        await ben.fill("#composer-input", "")
        await expect(row(ana, BEN)).to_have_attribute("data-probe", "kept", timeout=10000)
        await shot(ana, "list-live-unread", full_page=False)
        print("messages and typing change the row in place; the tab counts unread")

        # Ana opens the chat: read here, and on her other tab (which asks the server what she read).
        await row(ana, BEN).locator(".chat-item").click()
        await expect(ana.locator("#messages .msg", has_text="third")).to_be_visible(timeout=10000)
        await expect(ana).to_have_title(re.compile(r"^napsack"), timeout=10000)
        await expect(row(ana, BEN).locator(".chat-item")).not_to_have_class(re.compile(r"\bhas-unread\b"), timeout=10000)
        await expect(ana2).to_have_title(re.compile(r"^napsack"), timeout=10000)
        await expect(row(ana2, BEN).locator(".chat-item")).not_to_have_class(re.compile(r"\bhas-unread\b"), timeout=10000)
        print("reading clears it, on the other tab too")

        # In the open chat, a new message is a new row, and a reaction leaves its message as it is.
        await probe(ana.locator("#messages .msg", has_text="first"))
        await probe(ana.locator("#messages .msg", has_text="second"))
        await say(ben, "fourth")
        await expect(ana.locator("#messages .msg", has_text="fourth")).to_be_visible(timeout=10000)
        await ben.locator("#messages .msg", has_text="first").click()
        await ben.locator(".msg-actions button[aria-label='React \U0001F602']").click()
        await expect(ana.locator("#messages .reaction", has_text="\U0001F602")).to_be_visible(timeout=10000)
        await expect(ana.locator("#messages .msg[data-probe='kept']")).to_have_count(2, timeout=10000)
        await expect(ana).to_have_title(re.compile(r"^napsack"), timeout=10000)  # read as it came, while open
        print("the open chat adds what's new and keeps the rest")

        # A group message: the group's row and the count; opening the group reads it.
        await row(ben, GROUP).locator(".chat-item").click()
        await say(ben, "group one")
        await expect(row(ana, GROUP).locator(".chat-status")).to_have_text(f"{BEN}: group one", timeout=10000)
        await expect(ana).to_have_title(re.compile(r"^\(1\) napsack"), timeout=10000)
        await expect(row(ana, GROUP)).to_have_attribute("data-probe", "kept", timeout=10000)
        await row(ana, GROUP).locator(".chat-item").click()
        await expect(ana.locator("#messages .msg", has_text="group one")).to_be_visible(timeout=10000)
        await expect(ana).to_have_title(re.compile(r"^napsack"), timeout=10000)
        await expect(ana2).to_have_title(re.compile(r"^napsack"), timeout=10000)
        print("a group's messages and reads, the same")

        assert not fetched, f"the list was fetched again: {fetched}"
        assert not errors, errors
        await browser.close()
    print("LIST LIVE TEST PASSED")


asyncio.run(main())
