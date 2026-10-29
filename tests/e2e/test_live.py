"""Live features in the browser: "active now" and typing (F12), replies and
reactions in direct chats and groups (F11), and notifications (F10): turning
them on, a push arriving encrypted while napsack is closed, the service
worker showing it, and a notification link opening the chat.

Headless Chromium can't reach a real push service, so the page's PushManager
is swapped for one that hands out a subscription at a local stand-in push
service (tests/push_receiver.py), with real keys. Settings come from the
environment; see common.py."""
import asyncio, json, os, sys, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, save_recovery_key, shot

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from push_receiver import Receiver  # noqa: E402

tag = uuid.uuid4().hex[:5]
ANA, BEN = f"ana_{tag}", f"ben_{tag}"

# Stands in for the browser's push service. getSubscription remembers across
# reloads, like a real one.
FAKE_PUSH = """(sub) => {
  const KEY = 'test.fakePush';
  const make = () => ({ endpoint: sub.endpoint, toJSON: () => sub, unsubscribe: async () => { localStorage.removeItem(KEY); return true; } });
  PushManager.prototype.subscribe = async () => { localStorage.setItem(KEY, '1'); return make(); };
  PushManager.prototype.getSubscription = async () => (localStorage.getItem(KEY) ? make() : null);
}"""


async def sign_up(browser, name, push=None, **ctx):
    context = await browser.new_context(**ctx)
    if push:
        await context.grant_permissions(["notifications"], origin=BASE)
        await context.add_init_script(f"({FAKE_PUSH})({json.dumps(push)})")
    page = await context.new_page()
    await page.goto(BASE)
    await page.click("#auth-toggle")
    await page.fill("#auth-form input[name=username]", name)
    await page.fill("#auth-form input[name=password]", "correct horse battery")
    await page.fill("#auth-form input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(page)
    return page


async def api(page, path, method="GET", body=None):
    return await page.evaluate("""async ([path, method, body]) => {
      const r = await fetch('/api' + path, { method, headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token'),
        'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
      return r.json();
    }""", [path, method, body])


async def befriend(asker, asked, name_of_asked, name_of_asker):
    await asker.click("#friends-button")
    await asker.fill("#add-friend-form input[name=username]", name_of_asked)
    await asker.click("#add-friend-form button[type=submit]")
    await expect(asker.locator("#add-friend-note")).to_contain_text("Request sent")
    await asker.click("#friends-dialog [data-close]")
    await asked.click("#friends-button")
    await asked.locator("#incoming-list li", has_text=name_of_asker).locator("button", has_text="Accept").click()
    await asked.click("#friends-dialog [data-close]")


async def main():
    rx = Receiver()
    phone = rx.browser(f"ana-{tag}")
    async with async_playwright() as pw:
        browser = await launch(pw, full=True)
        ana = await sign_up(browser, ANA, push=phone.subscription())
        ben = await sign_up(browser, BEN)
        await befriend(ana, ben, BEN, ANA)
        ben_id = (await api(ben, "/me"))["id"]
        ana_id = (await api(ana, "/me"))["id"]

        # Active now: a dot in the list and a line in the chat header.
        row = ana.locator(".chat-item", has_text=BEN)
        await expect(row.locator(".avatar-wrap.online")).to_be_visible(timeout=10000)
        await row.click()
        await expect(ana.locator("#chat-sub")).to_have_text("Active now")

        # Typing shows up for the friend, then goes away.
        await ben.locator(".chat-item", has_text=ANA).click()
        await ben.locator("#composer-input").press_sequentially("hel")
        await expect(ana.locator("#typing-line")).to_have_text(f"{BEN} is typing…", timeout=5000)
        await expect(ana.locator(".chat-item", has_text=BEN).locator(".chat-status")).to_have_text("typing…")
        # Sending ends it at once, well before the hint's 4-second timer.
        await ben.fill("#composer-input", "first message")
        await ben.press("#composer-input", "Enter")
        await expect(ana.locator(".msg", has_text="first message")).to_be_visible(timeout=10000)
        await expect(ana.locator("#typing-line")).to_be_hidden(timeout=1000)
        await expect(ana.locator(".chat-item", has_text=BEN).locator(".chat-status")).not_to_have_text("typing…", timeout=1000)
        print("active now and typing")

        # Reply: tap the message, Reply, send. Both see the quote.
        await ana.locator(".msg", has_text="first message").click()
        await expect(ana.locator(".msg-actions")).to_be_visible()
        await shot(ana, "message-actions", full_page=False)
        await ana.locator(".msg-actions .reply-button").click()
        await expect(ana.locator("#reply-text")).to_have_text(f"Replying to {BEN}: first message")
        await ana.fill("#composer-input", "a reply")
        await ana.press("#composer-input", "Enter")
        await expect(ana.locator("#reply-bar")).to_be_hidden()
        await expect(ana.locator(".msg", has_text="a reply").locator(".quote")).to_have_text(f"{BEN}: first message", timeout=10000)
        await expect(ben.locator(".msg", has_text="a reply").locator(".quote")).to_have_text("You: first message")

        # React: Ben reacts to the reply; Ana sees it live; tapping it again takes it back.
        await ben.locator(".msg", has_text="a reply").click()
        await ben.locator(".msg-actions button[aria-label='React \U0001F602']").click()
        await expect(ana.locator(".reaction", has_text="\U0001F602")).to_be_visible(timeout=10000)
        await expect(ben.locator(".reaction.is-mine", has_text="\U0001F602")).to_be_visible()
        await shot(ana, "reaction", full_page=False)
        await ben.locator(".reaction", has_text="\U0001F602").click()
        await expect(ana.locator(".reaction")).to_have_count(0, timeout=10000)
        print("direct chat: replies and encrypted reactions, live")

        # The same in a group (end-to-end encrypted; the reply travels inside it).
        group = await api(ana, "/groups", "POST", {"name": f"live {tag}", "member_ids": [ben_id]})
        await expect(ben.locator(".chat-item", has_text=f"live {tag}")).to_be_visible(timeout=10000)
        await ben.locator(".chat-item", has_text=f"live {tag}").click()
        await ben.fill("#composer-input", "group hello")
        await ben.press("#composer-input", "Enter")
        await ana.locator(".chat-item", has_text=f"live {tag}").click()
        await ana.locator(".msg", has_text="group hello").click()
        await ana.locator(".msg-actions button[aria-label='React ❤️']").click()
        await expect(ben.locator(".reaction", has_text="❤")).to_be_visible(timeout=10000)
        await ana.locator(".msg", has_text="group hello").click()
        await ana.locator(".msg-actions .reply-button").click()
        await ana.fill("#composer-input", "group reply")
        await ana.press("#composer-input", "Enter")
        await expect(ben.locator(".msg", has_text="group reply").locator(".quote")).to_have_text("You: group hello", timeout=10000)
        # Typing in the group says so in the group, not in the direct chat, and it clears.
        # (Typing hints go out at most every 2 seconds; she just sent one with "group reply".)
        await ana.wait_for_timeout(2100)
        await ana.locator("#composer-input").press_sequentially("still ty")
        await expect(ben.locator("#typing-line")).to_have_text(f"{ANA} is typing…", timeout=5000)
        dm_status = ben.locator(".chat-item:not(.is-group)", has_text=ANA).locator(".chat-status")
        await expect(dm_status).not_to_have_text("typing…")
        await expect(ben.locator("#typing-line")).to_be_hidden(timeout=8000)
        await ana.fill("#composer-input", "")
        assert group["id"]
        print("group: replies and reactions")

        # Hiding activity is mutual.
        await ben.click("#my-profile")
        await expect(ben.locator("#share-activity")).to_be_checked()   # loaded with the profile
        await ben.uncheck("#share-activity")
        await ben.click("#profile-dialog [data-close]")
        await ana.locator(".chat-item", has_text=BEN).click()
        await expect(ana.locator("#chat-sub")).to_be_hidden(timeout=10000)
        await expect(ana.locator(".avatar-wrap.online")).to_have_count(0)
        print("hiding activity hides it")

        # Notifications: turn on, then with napsack closed a push arrives, encrypted, saying who.
        await ana.click("#my-profile")
        await expect(ana.locator("#push-status")).to_have_text("Off for this device.")
        await ana.click("#push-toggle")
        await expect(ana.locator("#push-status")).to_contain_text("On for this device", timeout=10000)
        await shot(ana, "notifications-on", full_page=False)
        await ana.click("#profile-dialog [data-close]")
        await ana.close()
        await asyncio.sleep(0.5)
        await ben.locator(".chat-item:not(.is-group)", has_text=ANA).click()
        await ben.fill("#composer-input", "are you there?")
        await ben.press("#composer-input", "Enter")
        _, headers, body = rx.wait_for(phone.endpoint.rsplit("/", 1)[-1])[0]
        note = phone.decrypt(body)
        assert note == {"title": BEN, "body": "New message", "tag": f"dm-{ben_id}", "url": f"/#chat={ben_id}"}, note
        print("push arrived while closed:", note)

        # The service worker shows a push; a notification's link opens the chat.
        ana = await ana.context.new_page()
        await ana.goto(BASE)
        await expect(ana.locator("#app")).to_be_visible(timeout=20000)
        await ana.evaluate("navigator.serviceWorker.ready")
        cdp = await ana.context.new_cdp_session(ana)
        regs = []
        cdp.on("ServiceWorker.workerRegistrationUpdated", lambda e: regs.extend(e["registrations"]))
        await cdp.send("ServiceWorker.enable")
        for _ in range(50):
            if any(not r["isDeleted"] for r in regs):
                break
            await asyncio.sleep(0.1)
        reg = next(r for r in regs if not r["isDeleted"])
        await cdp.send("ServiceWorker.deliverPushMessage", {"origin": BASE, "registrationId": reg["registrationId"], "data": json.dumps(note)})
        shown = []
        for _ in range(50):
            shown = await ana.evaluate("""async () => (await (await navigator.serviceWorker.ready).getNotifications())
              .map((n) => ({ title: n.title, body: n.body, tag: n.tag, url: n.data && n.data.url }))""")
            if shown:
                break
            await asyncio.sleep(0.1)
        assert shown == [{"title": BEN, "body": "New message", "tag": f"dm-{ben_id}", "url": f"/#chat={ben_id}"}], shown
        await ana.goto(f"{BASE}/#chat={ben_id}")
        await expect(ana.locator("#chat-title")).to_have_text(BEN, timeout=20000)
        await expect(ana.locator(".msg", has_text="are you there?")).to_be_visible()
        assert await ana.evaluate("location.hash") == ""
        # Opening napsack clears what's waiting on the lock screen (bug report, 2026-10-28).
        assert await ana.evaluate("async () => (await (await navigator.serviceWorker.ready).getNotifications()).length") == 1
        await ana.reload()
        await expect(ana.locator("#app")).to_be_visible(timeout=20000)
        left = None
        for _ in range(50):
            left = await ana.evaluate("async () => (await (await navigator.serviceWorker.ready).getNotifications()).length")
            if left == 0:
                break
            await asyncio.sleep(0.1)
        assert left == 0, f"{left} notifications left after opening napsack"
        print("service worker shows it; the link opens the chat; opening napsack clears it")

        # Installable: a manifest with icons.
        manifest = await ana.evaluate("fetch('/manifest.webmanifest').then((r) => r.json())")
        assert manifest["display"] == "standalone" and {i["sizes"] for i in manifest["icons"]} == {"192x192", "512x512"}
        for path in ("/icon-192.png", "/icon-512.png", "/apple-touch-icon.png", "/sw.js"):
            assert await ana.evaluate(f"fetch('{path}').then((r) => r.status)") == 200, path
        assert ana_id

        await browser.close()
    rx.server.shutdown()
    print("LIVE TEST PASSED")


asyncio.run(main())
