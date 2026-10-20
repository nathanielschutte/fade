"""Drives the real web client in Chrome: two users exchanging end-to-end
encrypted texts and snaps, plus key persistence, safety codes, and key pinning.
Settings come from the environment; see common.py."""
import asyncio, base64, re, sqlite3, sys, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, DB, INVITE, launch, shot
PASSWORD = "correct horse battery"
tag = uuid.uuid4().hex[:5]
ALEX, SAM = f"alex_{tag}", f"sam_{tag}"
SECRET = f"meet at the usual place {tag} 🌿"

errors = []
snap_uploads = []


async def new_page(browser, label):
    ctx = await browser.new_context(viewport={"width": 1100, "height": 760})
    # Headless Chrome has no camera here, so stand in a 1920x1080 animated canvas stream.
    await ctx.add_init_script("""
      navigator.mediaDevices.getUserMedia = async () => {
        const c = document.createElement('canvas'); c.width = 1920; c.height = 1080;
        const g = c.getContext('2d'); let t = 0;
        setInterval(() => {
          const grad = g.createLinearGradient(0, 0, c.width, c.height);
          grad.addColorStop(0, `hsl(${t % 360} 50% 40%)`); grad.addColorStop(1, '#234');
          g.fillStyle = grad; g.fillRect(0, 0, c.width, c.height);
          for (let i = 0; i < 400; i++) { g.fillStyle = `hsl(${(i * 37 + t) % 360} 60% 60%)`;
            g.fillRect((i * 97) % 1920, (i * 53 + t) % 1080, 40, 40); }
          t += 3;
        }, 33);
        return c.captureStream(30);
      };
    """)
    page = await ctx.new_page()
    page.on("pageerror", lambda e: errors.append(f"{label}: {e}"))
    page.on("console", lambda m: m.type == "error" and errors.append(f"{label} console: {m.text}"))
    page.on("response", lambda r: r.status >= 400 and print(f"  [{label}] HTTP {r.status} {r.request.method} {r.url}"))
    page.on("request", lambda r: r.method == "POST" and "/snaps" in r.url
            and snap_uploads.append(len(r.post_data_buffer or b"")))
    await page.goto(BASE)
    return page


async def register(page, name):
    await page.click("#auth-toggle")
    await page.fill("input[name=username]", name)
    await page.fill("input[name=password]", PASSWORD)
    await page.fill("input[name=invite_code]", INVITE)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)


async def login(page, name):
    await page.fill("input[name=username]", name)
    await page.fill("input[name=password]", PASSWORD)
    await page.click("#auth-submit")
    await expect(page.locator("#app")).to_be_visible(timeout=20000)


async def open_chat(page, name):
    await page.locator(".chat-item", has_text=name).click()
    await expect(page.locator("#chat-title")).to_have_text(name)


async def wait_js(page, expr, timeout=10000):
    """wait_for_function needs eval, which the app's CSP (rightly) forbids."""
    for _ in range(timeout // 100):
        if await page.evaluate(f"() => Boolean({expr})"):
            return
        await asyncio.sleep(0.1)
    raise AssertionError(f"timed out waiting for {expr}")



async def main():
    async with async_playwright() as pw:
        browser = await launch(pw, args=[
            "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"])
        a = await new_page(browser, "alex")
        b = await new_page(browser, "sam")
        await shot(a, "1-signin")

        await register(a, ALEX)
        await register(b, SAM)
        print("registered both")

        # Friend request, accepted in the UI.
        await a.click("#friends-button")
        await a.fill("#add-friend-form input[name=username]", SAM)
        await a.click("#add-friend-form button[type=submit]")
        await expect(a.locator("#add-friend-note")).to_contain_text("Request sent")
        await a.click("#friends-dialog [data-close]")
        await b.click("#friends-button")
        await b.locator("#incoming-list button", has_text="Accept").click()
        await b.click("#friends-dialog [data-close]")

        # Encrypted texts, both directions, delivered live over the socket.
        await open_chat(a, SAM)
        await open_chat(b, ALEX)
        await a.fill("#composer-input", SECRET)
        await a.press("#composer-input", "Enter")
        await expect(b.locator(".msg", has_text=SECRET)).to_be_visible(timeout=10000)
        await b.fill("#composer-input", "got it")
        await b.press("#composer-input", "Enter")
        await expect(a.locator(".msg", has_text="got it")).to_be_visible(timeout=10000)
        await expect(a.locator(".msg-meta", has_text="Seen")).to_be_visible(timeout=10000)
        await expect(a.locator(".chat-item .chat-status")).to_have_text("got it", timeout=5000)
        await expect(b.locator(".chat-item .chat-status")).to_have_text("You: got it", timeout=5000)
        print("texts delivered and decrypted both ways, including chat list previews")
        await shot(a, "2-chat")

        if DB:
            rows = sqlite3.connect(DB).execute("SELECT ciphertext FROM messages WHERE kind='text'").fetchall()
            assert len(rows) >= 2, rows
            for (ct,) in rows:
                raw = base64.b64decode(ct)
                assert b"usual place" not in raw and b"got it" not in raw and "usual" not in ct
            users = sqlite3.connect(DB).execute("SELECT auth_hash, wrapped_private_key FROM users").fetchall()
            assert all(PASSWORD not in h and PASSWORD not in w for h, w in users)
            print("database holds only ciphertext, no password")

        # Safety codes match on both sides.
        codes = []
        for p in (a, b):
            await p.click("#safety-button")
            await expect(p.locator("#safety-code")).to_have_text(re.compile(r"^\d{5}( \d{5}){2}\n\d{5}( \d{5}){2}$"), timeout=5000)
            codes.append(await p.locator("#safety-code").text_content())
            if p is a:
                await shot(a, "3-safety")
            await p.click("#safety-dialog [data-close]")
        assert codes[0] == codes[1], codes
        print("safety codes match:", codes[0])

        # Snap 1: fake camera frame through the shutter.
        await a.click("#camera-button")
        await wait_js(a, "document.querySelector('#camera-video').videoWidth > 100")
        await a.click("#shutter")
        await expect(a.locator("#send-snap")).to_be_visible()
        await a.click("#send-snap")
        await expect(a.locator("#camera-dialog")).not_to_be_visible(timeout=10000)

        # Snap 2: a 3000x2250 noise image, the worst case for JPEG, through the file picker.
        await a.click("#camera-button")
        await a.evaluate("""async () => {
          const c = document.createElement('canvas'); c.width = 3000; c.height = 2250;
          const ctx = c.getContext('2d'); const img = ctx.createImageData(c.width, c.height);
          for (let i = 0; i < img.data.length; i++) img.data[i] = (i % 4 === 3) ? 255 : Math.random() * 256;
          ctx.putImageData(img, 0, 0);
          const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
          const dt = new DataTransfer();
          dt.items.add(new File([blob], 'noise.png', { type: 'image/png' }));
          const input = document.querySelector('#file-input');
          input.files = dt.files;
          input.dispatchEvent(new Event('change'));
        }""")
        await expect(a.locator("#send-snap")).to_be_visible(timeout=30000)
        await a.click("#send-snap")
        await expect(a.locator("#camera-dialog")).not_to_be_visible(timeout=10000)
        print("snap upload sizes (encrypted bytes):", snap_uploads)

        # The UI says "pic", never "snap" (the internal name).
        await expect(b.locator("button.snap-chip").first).to_contain_text("Tap to view pic", timeout=10000)
        await expect(a.locator(".chat-item .chat-status")).to_contain_text("Sent a pic")
        for p in (a, b):
            visible = await p.evaluate("""() => [document.body.innerText,
                ...[...document.querySelectorAll('[aria-label],[alt],[title],[placeholder]')].flatMap(e =>
                    ['aria-label', 'alt', 'title', 'placeholder'].map(k => e.getAttribute(k) || ''))].join(' ')""")
            assert "snap" not in visible.lower(), [w for w in visible.split() if "snap" in w.lower()]
        assert len(snap_uploads) == 2 and all(n <= 200 * 1024 + 28 for n in snap_uploads), snap_uploads

        # Sam opens both: decrypts and shows the image, then it's gone.
        for i in range(2):
            chip = b.locator("button.snap-chip").first
            await expect(chip).to_be_visible(timeout=10000)
            await chip.click()
            await wait_js(b, "document.querySelector('#viewer-image').complete && document.querySelector('#viewer-image').naturalWidth > 0")
            dims = await b.evaluate("[document.querySelector('#viewer-image').naturalWidth, document.querySelector('#viewer-image').naturalHeight]")
            print(f"snap {i + 1} decrypted and shown at {dims[0]}x{dims[1]}")
            assert max(dims) <= 1280
            if i == 0:
                await shot(b, "4-viewer")
            await b.click("#viewer")
        await expect(b.locator("button.snap-chip")).to_have_count(0)

        # Reload: key comes back from IndexedDB without the password.
        await b.reload()
        await expect(b.locator("#app")).to_be_visible(timeout=10000)
        await open_chat(b, ALEX)
        await expect(b.locator(".msg", has_text=SECRET)).to_be_visible(timeout=10000)
        print("reload keeps the key")

        # New device: password alone recovers the key and history.
        c = await new_page(browser, "sam-2")
        await login(c, SAM.upper())
        await open_chat(c, ALEX)
        await expect(c.locator(".msg", has_text=SECRET)).to_be_visible(timeout=10000)
        print("fresh profile + password decrypts history")

        # Signing out clears the key; a wrong password can't sign in.
        await c.click("#friends-button")
        await c.click("#sign-out")
        await expect(c.locator("#auth")).to_be_visible()
        assert await c.evaluate("""() => new Promise((res) => {
            const r = indexedDB.open('napsack', 1);
            r.onsuccess = () => { const g = r.result.transaction('keys').objectStore('keys').get('identity');
                                  g.onsuccess = () => res(g.result === undefined); };
        })""")
        await c.fill("input[name=username]", SAM)
        await c.fill("input[name=password]", "wrong password!")
        await c.click("#auth-submit")
        await expect(c.locator("#auth-error")).to_contain_text("Wrong username or password", timeout=20000)
        print("sign-out clears the key; wrong password rejected")

        await shot(a, "5-list")

        # Key change: pretend Alex first saw a different key for Sam. Chat must block.
        await a.evaluate("""async () => {
          const h = { Authorization: 'Bearer ' + localStorage.getItem('fade.token') };
          const me = await (await fetch('/api/me', { headers: h })).json();
          const [sam] = await (await fetch('/api/friends', { headers: h })).json();
          const db = await new Promise((res) => { const r = indexedDB.open('napsack', 1); r.onsuccess = () => res(r.result); });
          await new Promise((res) => { const tx = db.transaction('keys', 'readwrite');
            tx.objectStore('keys').put({ [sam.id]: 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEdifferentkey==' }, 'pins:' + me.id);
            tx.oncomplete = res; });
        }""")
        await a.reload()
        await expect(a.locator(".chat-item .chat-status")).to_have_text("Safety code changed", timeout=10000)
        await open_chat(a, SAM)
        await expect(a.locator("#key-warning")).to_be_visible()
        await expect(a.locator("#composer-input")).to_be_disabled()
        await expect(a.locator("#camera-button")).to_be_disabled()
        await expect(a.locator("#composer .send")).to_be_disabled()
        await shot(a, "6-key-changed")
        print("changed key blocks the chat")
        await browser.close()

    # Expected: the deliberate wrong-password attempt (400) and the browser's favicon probe (404).
    real_errors = [e for e in errors if "status of 400" not in e and "status of 404" not in e]
    assert not real_errors, real_errors
    print("BROWSER TEST PASSED")


asyncio.run(main())
