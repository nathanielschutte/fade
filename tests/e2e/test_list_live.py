"""The chat list and an open chat follow what happens in place (speed: Nate,
2026-11-02). A message changes its row, the unread marker, and the tab's
count without the list being fetched again, and reading clears them; typing
changes one row; the same for a group. Another device of mine reading a chat
clears it there too. What arrives in the chat I'm reading never shows as
unread, not even while the read is on its way. A mute for some hours ends by
itself, without the list being fetched again. A two-tap Leave in the list
disarms when the pointer moves away. Rows and messages that didn't change stay the very same
elements: a new message is a new row, and a reaction doesn't rebuild the
message it's on. Settings come from the environment; see common.py."""
import asyncio, datetime, re, uuid
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
    """Sends `text` and waits until it has gone, so the next one is stored after it."""
    await page.fill("#composer-input", text)
    await page.press("#composer-input", "Enter")
    await expect(page.locator("#messages .msg", has_text=text)).to_be_visible(timeout=10000)
    await expect(page.locator("#messages .msg-meta", has_text="Sending…")).to_have_count(0, timeout=10000)


# Records every moment the page shows something unread: a count in the tab's
# title, or the open chat's row marked unread.
WATCH_UNREAD = """() => {
  window.shownUnread = [];
  const look = () => {
    if (/^\\(/.test(document.title)) window.shownUnread.push(document.title);
    const open = document.querySelector('#chat-list .chat-item[aria-current]');
    if (open && open.classList.contains('has-unread')) window.shownUnread.push('the open row');
  };
  new MutationObserver(look).observe(document, { subtree: true, childList: true, characterData: true,
    attributes: true, attributeFilter: ['class', 'aria-current'] });
}"""


async def open_row(page, name):
    """Opens a chat from the list with the keyboard. Two clicks on one spot in
    quick succession are a double tap (straight to the camera), which clicks
    on rows that just moved can be."""
    await row(page, name).locator(".chat-item").press("Enter")


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
        await open_row(ben, ANA)
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
        await open_row(ana, BEN)
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
        await open_row(ben, GROUP)
        await say(ben, "group one")
        await expect(row(ana, GROUP).locator(".chat-status")).to_have_text(f"{BEN}: group one", timeout=10000)
        await expect(ana).to_have_title(re.compile(r"^\(1\) napsack"), timeout=10000)
        await expect(row(ana, GROUP)).to_have_attribute("data-probe", "kept", timeout=10000)
        await open_row(ana, GROUP)
        await expect(ana.locator("#messages .msg", has_text="group one")).to_be_visible(timeout=10000)
        await expect(ana).to_have_title(re.compile(r"^napsack"), timeout=10000)
        await expect(ana2).to_have_title(re.compile(r"^napsack"), timeout=10000)
        print("a group's messages and reads, the same")

        # What comes into the chat Ana is reading is read as it comes: neither the
        # tab nor the row shows it as unread, even while the read is on its way.
        await ana.evaluate(WATCH_UNREAD)
        await say(ben, "group two")
        await expect(ana.locator("#messages .msg", has_text="group two")).to_be_visible(timeout=10000)
        await expect(row(ana, GROUP).locator(".chat-status")).to_have_text(f"{BEN}: group two", timeout=10000)
        await expect(row(ana2, GROUP).locator(".chat-status")).to_have_text(f"{BEN}: group two", timeout=10000)
        await expect(ana2).to_have_title(re.compile(r"^napsack"), timeout=10000)  # the server has her read
        await open_row(ana, BEN)
        await expect(ana.locator("#chat-title")).to_have_text(BEN)
        await expect(ana.locator("#messages .msg", has_text="fourth")).to_be_visible(timeout=10000)
        await open_row(ben, ANA)
        await say(ben, "fifth")
        await expect(ana.locator("#messages .msg", has_text="fifth")).to_be_visible(timeout=10000)
        await expect(row(ana, BEN).locator(".chat-status")).to_have_text("fifth", timeout=10000)
        await expect(row(ana2, BEN).locator(".chat-status")).to_have_text("fifth", timeout=10000)
        await expect(row(ana2, BEN).locator(".chat-item")).not_to_have_class(re.compile(r"\bhas-unread\b"), timeout=10000)
        assert await ana.evaluate("window.shownUnread") == [], "the chat being read showed as unread"
        print("what arrives in the open chat never shows as unread")

        assert not fetched, f"the list was fetched again: {fetched}"

        # Leave, in the list, takes two taps; moving away disarms the first.
        leave = row(ana, GROUP).locator(".row-action.danger")
        await row(ana, GROUP).hover()
        await leave.click()
        await expect(leave).to_have_text("Tap to leave")
        await row(ana, BEN).hover()
        await row(ana, GROUP).hover()
        await expect(leave).to_have_text("Leave")
        await expect(leave).to_have_attribute("aria-label", f"Leave {GROUP}")
        print("an armed Leave disarms when the pointer moves away")

        # A mute for some hours ends by itself: once it's over, Ben's messages
        # show as unread again, in a tab that never fetched the list again.
        await open_row(ana, GROUP)
        await expect(ana.locator("#chat-title")).to_have_text(GROUP)
        await row(ana, BEN).hover()
        await row(ana, BEN).locator(".row-action", has_text="Mute").click()
        await ana.click("#mute-dialog [data-hours='8']")
        await expect(row(ana, BEN).locator(".chat-name")).to_contain_text("🔕")
        await ana.context.clock.set_system_time(datetime.datetime.now() + datetime.timedelta(hours=9))
        await say(ben, "after the mute")
        await expect(row(ana, BEN).locator(".chat-status")).to_have_text("after the mute", timeout=10000)
        await expect(row(ana, BEN).locator(".chat-name")).not_to_contain_text("🔕")
        await expect(row(ana, BEN).locator(".chat-item")).to_have_class(re.compile(r"\bhas-unread\b"))
        await expect(ana).to_have_title(re.compile(r"^\(1\) napsack"))
        print("a mute for some hours ends by itself")

        assert not errors, errors
        await browser.close()
    print("LIST LIVE TEST PASSED")


asyncio.run(main())
