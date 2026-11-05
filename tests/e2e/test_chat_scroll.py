"""A chat's scrolling stays natural (Nate, 2026-11-02): few rules, all about
the newest message. Opening a chat shows it at the bottom, and sending brings
you back to it. While you're at the bottom, the composer growing to four
lines, the friend starting to type, a new message, and the phone keyboard (a
shorter window here) all keep it fully in view: below the chat's top edge and
above the typing line and the composer. Once you've scrolled up, nothing moves
what you're reading: new messages and the typing line arrive below it, and
older pages load above it without a shift. Checked with real element boxes,
on a phone (390px) and a computer. Settings come from the environment; see
common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import launch, shot, PHONE, befriend, row, sign_up, type_a_while

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
COUNT = 70  # more than a first page (50), so reaching the top loads more
errors = []

# Ben sends `count` real, decryptable texts the way the app does (his own key,
# from his browser), some of them several lines long. "seed 007" and so on, so
# no text is the start of another.
SEND_MANY = """async ([friendName, count]) => {
  const e2e = await import('/crypto.js');
  const keystore = await import('/keystore.js');
  const auth = { Authorization: 'Bearer ' + localStorage.getItem('fade.token') };
  const me = await (await fetch('/api/me', { headers: auth })).json();
  const friend = (await (await fetch('/api/friends', { headers: auth })).json()).find(f => f.username === friendName);
  const identity = await keystore.loadLocal('identity');
  const key = await e2e.pairKey(identity.privateKey, friend.public_key, me.id, friend.id);
  for (let i = 1; i <= count; i++) {
    const n = String(i).padStart(3, '0');
    const text = i % 7 ? `seed ${n}` : `seed ${n}\\nwith a second line\\nand a third`;
    const ciphertext = await e2e.encryptText(key, text, me.id, friend.id);
    const r = await fetch(`/api/chats/${friend.id}/messages`, {
      method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ciphertext, format: e2e.FORMAT }) });
    if (!r.ok) throw new Error('send failed ' + r.status);
  }
}"""

# The newest message (the last bubble) says `want` and is entirely in view:
# below the chat's top edge, above its bottom edge, the typing line, and the composer.
NEWEST_IN_VIEW = """(want) => {
  const list = document.querySelector('#messages');
  const bubbles = list.querySelectorAll('.msg');
  const last = bubbles[bubbles.length - 1];
  if (!last || !last.textContent.includes(want)) return false;
  const r = last.getBoundingClientRect();
  const box = list.getBoundingClientRect();
  let floor = Math.min(box.bottom, document.querySelector('#composer').getBoundingClientRect().top);
  const typing = document.querySelector('#typing-line');
  if (!typing.hidden) floor = Math.min(floor, typing.getBoundingClientRect().top);
  return r.height > 0 && r.top >= box.top - 0.5 && r.bottom <= floor + 0.5;
}"""

# The message in the middle of what's in view, and where it is on screen.
LOOKING_AT = """() => {
  const list = document.querySelector('#messages');
  const box = list.getBoundingClientRect();
  const middle = (box.top + box.bottom) / 2;
  for (const m of list.querySelectorAll('.msg')) {
    const r = m.getBoundingClientRect();
    if (r.bottom > middle) return { text: m.textContent, y: r.top };
  }
  return null;
}"""

# Where the bubble saying exactly `text` is on screen now.
WHERE = """(text) => {
  const m = [...document.querySelectorAll('#messages .msg')].find((e) => e.textContent === text);
  return m ? m.getBoundingClientRect().top : null;
}"""


async def drawn(page):
    """Two animation frames: whatever the last change set off is on screen."""
    await page.evaluate("() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")


async def newest(page, text):
    """Waits until the newest message says `text` and is fully in view."""
    await page.wait_for_function(NEWEST_IN_VIEW, arg=text, timeout=10000)


async def stays(page, seen, why):
    """The message `seen` (from LOOKING_AT) hasn't moved on screen."""
    await drawn(page)
    y = await page.evaluate(WHERE, seen["text"])
    assert y is not None and abs(y - seen["y"]) < 1, f"{why}: {seen['text']!r} moved from {seen['y']} to {y}"


async def start_typing(ben, reader):
    """Ben types until the reader sees the typing line."""
    await type_a_while(ben)
    await expect(reader.locator("#typing-line")).to_be_visible(timeout=5000)


async def ben_says(ben, text):
    await ben.fill("#composer-input", text)
    await ben.press("#composer-input", "Enter")


async def send(reader, text):
    await reader.fill("#composer-input", text)
    await reader.click("#composer .send")


async def check(reader, ben, reader_name, label):
    """The rules, in the reader's long chat with Ben (Ben's page has it open)."""
    last = f"seed {COUNT:03d}"
    await row(reader, BEN).locator(".chat-item").click()
    await expect(reader.locator("#chat-title")).to_have_text(BEN)
    await newest(reader, last)
    await shot(reader, f"scroll-{label}-opened", full_page=False)
    print(f"{label}: opening a long chat shows the newest message")

    # The composer grows to four lines; the chat above it gets shorter.
    await reader.fill("#composer-input", "one\ntwo\nthree\nfour")
    await expect(reader.locator("#composer-input")).to_have_value("one\ntwo\nthree\nfour")
    await newest(reader, last)
    await shot(reader, f"scroll-{label}-four-lines", full_page=False)
    await reader.fill("#composer-input", "")
    await newest(reader, last)
    print(f"{label}: the composer growing to four lines keeps it in view")

    # Ben starts typing: the typing line shows under the chat.
    await start_typing(ben, reader)
    await newest(reader, last)
    await shot(reader, f"scroll-{label}-typing", full_page=False)
    print(f"{label}: the typing line keeps it in view")

    # A new message while at the bottom.
    await ben_says(ben, "live one")
    await newest(reader, "live one")
    print(f"{label}: a new message at the bottom comes into view")

    # The phone keyboard, standing in: the window gets shorter, then back.
    size = reader.viewport_size
    await reader.set_viewport_size({"width": size["width"], "height": size["height"] - 320})
    await newest(reader, "live one")
    await shot(reader, f"scroll-{label}-keyboard", full_page=False)
    await reader.set_viewport_size(size)
    await newest(reader, "live one")
    print(f"{label}: a shorter window (the keyboard) keeps it in view")

    # The same, with the scroll event first (D22): the chat shrinks and a scroll
    # event comes in the same moment, before the ResizeObserver sees the new size.
    await reader.evaluate("""() => {
      const l = document.querySelector('#messages');
      l.style.maxHeight = (l.clientHeight - 200) + 'px';
      l.dispatchEvent(new Event('scroll'));
    }""")
    await newest(reader, "live one")
    await reader.evaluate("() => { document.querySelector('#messages').style.maxHeight = ''; }")
    await newest(reader, "live one")
    print(f"{label}: a scroll event racing the shrink keeps it in view")

    # Scrolled up, to the middle: nothing moves what's being read.
    await reader.evaluate("() => { const l = document.querySelector('#messages'); l.scrollTop = (l.scrollHeight - l.clientHeight) / 2; }")
    await drawn(reader)
    seen = await reader.evaluate(LOOKING_AT)
    assert seen, "nothing in view after scrolling up"
    await ben_says(ben, "live two")
    await expect(reader.locator(".msg", has_text="live two")).to_be_attached(timeout=10000)
    await stays(reader, seen, "a new message while scrolled up")
    assert not await reader.evaluate(NEWEST_IN_VIEW, "live two"), "a new message pulled the view down"
    await start_typing(ben, reader)
    await stays(reader, seen, "the typing line while scrolled up")
    await ben.fill("#composer-input", "")
    await shot(reader, f"scroll-{label}-scrolled-up", full_page=False)
    print(f"{label}: scrolled up, a new message and the typing line move nothing")

    # At the top, the older page loads above what's in view, without a shift.
    top = await reader.evaluate("""() => {
      const l = document.querySelector('#messages');
      l.scrollTop = 0;
      const m = l.querySelector('.msg');
      return { text: m.textContent, y: m.getBoundingClientRect().top };
    }""")
    assert top["text"] != "seed 001", "the whole chat loaded at once"
    await expect(reader.locator(".msg", has_text="seed 001")).to_be_attached(timeout=10000)
    await expect(reader.locator(".history-edge")).to_contain_text("beginning of your chat")
    await stays(reader, top, "older messages loading above")
    print(f"{label}: older messages load above without a shift")

    # Sending brings you back to the bottom.
    await send(reader, f"back down {label}")
    await newest(reader, f"back down {label}")
    await expect(reader.locator("#messages .msg.pending")).to_have_count(0, timeout=10000)
    await newest(reader, f"back down {label}")
    print(f"{label}: sending brings you to the newest message")


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ben = await sign_up(browser, BEN, errors=errors, viewport={"width": 1100, "height": 760})
        ana = await sign_up(browser, ANA, errors=errors, label="phone", **PHONE)
        cal = await sign_up(browser, CAL, errors=errors, label="desktop", viewport={"width": 1100, "height": 760})
        await befriend(ben, ana, ANA, BEN)
        await befriend(ben, cal, CAL, BEN)
        await expect(row(ben, ANA)).to_be_visible(timeout=10000)
        await expect(row(ben, CAL)).to_be_visible(timeout=10000)
        await ben.evaluate(SEND_MANY, [ANA, COUNT])
        await ben.evaluate(SEND_MANY, [CAL, COUNT])

        await row(ben, ANA).locator(".chat-item").click()
        await check(ana, ben, ANA, "phone")
        await row(ben, CAL).locator(".chat-item").click()
        await check(cal, ben, CAL, "desktop")

        assert not errors, errors
        await browser.close()
    print("CHAT SCROLL TEST PASSED")


asyncio.run(main())
