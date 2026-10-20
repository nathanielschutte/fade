"""Signs up (or in) as the configured admin and a throwaway non-admin, then
checks the admin panel: access control, no content in the stats, layout on a phone.
Settings come from the environment; see common.py."""
import asyncio, json, sys, uuid
from playwright.async_api import async_playwright, expect

from common import ADMIN, BASE, INVITE, launch, save_recovery_key, shot

ADMIN_PW = "correct horse battery"
OTHER = f"bob_{uuid.uuid4().hex[:5]}"
errors = []


async def page_for(browser, label, width=1100, height=800):
    ctx = await browser.new_context(viewport={"width": width, "height": height})
    p = await ctx.new_page()
    p.on("pageerror", lambda e: errors.append(f"{label}: {e}"))
    p.on("console", lambda m: m.type == "error" and "status of 4" not in m.text and errors.append(f"{label}: {m.text}"))
    await p.goto(BASE)
    return p


async def sign_up_or_in(p, name, pw):
    await p.fill("input[name=username]", name)
    await p.fill("input[name=password]", pw)
    await p.click("#auth-submit")
    try:
        await expect(p.locator("#app")).to_be_visible(timeout=15000)
        return
    except AssertionError:
        pass
    await p.click("#auth-toggle")
    await p.fill("input[name=username]", name)
    await p.fill("input[name=password]", pw)
    await p.fill("input[name=invite_code]", INVITE)
    await p.click("#auth-submit")
    await expect(p.locator("#app")).to_be_visible(timeout=20000)
    await save_recovery_key(p)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        admin = await page_for(browser, "admin")
        other = await page_for(browser, "other")
        await sign_up_or_in(admin, ADMIN, ADMIN_PW)
        await sign_up_or_in(other, OTHER, "another password 1")

        # A friendship and a couple of texts so the numbers move.
        await other.click("#friends-button")
        await other.fill("#add-friend-form input[name=username]", ADMIN)
        await other.click("#add-friend-form button[type=submit]")
        await expect(other.locator("#add-friend-note")).to_contain_text("Request sent")
        await other.click("#friends-dialog [data-close]")
        await admin.click("#friends-button")
        await expect(admin.locator(".account-bar #admin-link")).to_be_visible()
        await admin.locator("#incoming-list button", has_text="Accept").click()
        await admin.click("#friends-dialog [data-close]")
        await other.locator(".chat-item", has_text=ADMIN).click()
        for text in ("hi nate", "admin panel test"):
            await other.fill("#composer-input", text)
            await other.press("#composer-input", "Enter")
        await expect(other.locator(".msg", has_text="admin panel test")).to_be_visible()

        # Non-admin: no link, API says 404, page says unavailable.
        await other.click("#friends-button")
        await expect(other.locator("#admin-link")).to_be_hidden()
        status = await other.evaluate("""async () => (await fetch('/api/admin/stats',
            { headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } })).status""")
        assert status == 404, status
        await other.goto(BASE + "/admin")
        await expect(other.locator("#message")).to_contain_text("isn't available")
        print("non-admin: hidden link, 404, unavailable page")

        # Admin panel.
        await admin.goto(BASE + "/admin")
        await expect(admin.locator("#admin")).to_be_visible(timeout=10000)
        stats = await admin.evaluate("""async () => (await fetch('/api/admin/stats',
            { headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } })).json()""")
        raw = json.dumps(stats)
        for banned in ("ciphertext", "public_key", "wrapped", "auth_hash", "admin panel test"):
            assert banned not in raw, banned
        assert stats["users"]["total"] >= 2 and stats["messages"]["texts"] >= 2
        assert len(stats["messages"]["daily"]) == 14
        today = stats["messages"]["daily"][-1]
        assert today["texts"] >= 2 and today["signups"] >= 1, today
        names = [u["username"] for u in stats["users"]["list"]]
        assert ADMIN in [x.lower() for x in names] and OTHER in names
        print("stats:", {k: stats["users"][k] for k in ("total", "active_24h", "online", "sockets")},
              "texts", stats["messages"]["texts"], "today", today)
        await expect(admin.locator("#t-users")).to_have_text(str(stats["users"]["total"]))
        await expect(admin.locator("#users tr")).to_have_count(len(names))

        # Tooltip on the last bar.
        await admin.locator(".chart-col").last.hover()
        await expect(admin.locator("#tip")).to_be_visible()
        await expect(admin.locator("#tip")).to_contain_text("messages")
        await shot(admin, "admin-desktop")

        # Logs tab: events are there and searchable, and nothing secret is logged.
        await admin.click("#tab-logs")
        await expect(admin.locator("#view-logs")).to_be_visible()
        await expect(admin.locator("#log-rows tr").first).to_be_visible()
        logs = await admin.evaluate("""async () => (await fetch('/api/admin/logs?limit=500&level=debug',
            { headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } })).json()""")
        raw = json.dumps(logs)
        messages = [e["message"] for e in logs["entries"]]
        for expected in ("account created", "friend request accepted", "text sent", "request"):
            assert expected in messages, (expected, sorted(set(messages)))
        for banned in (INVITE, "admin panel test", "hi nate", "auth_key", "wrapped_private_key", "ciphertext\"", "Bearer"):
            assert banned not in raw, f"logs contain {banned!r}"
        routes = {v for e in logs["entries"] for k, v in e["fields"] if k == "route"}
        assert "/api/chats/{friend_id}/messages" in routes, routes
        assert "/api/admin/logs" not in routes, "the viewer's own polling should not be logged"

        # The web app's own reports arrive, labeled; content-looking fields are redacted.
        await other.evaluate("""async (text) => fetch('/api/logs', { method: 'POST',
            headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + localStorage.getItem('fade.token') },
            body: JSON.stringify({ entries: [{ level: 'warn', message: 'e2e client probe', fields: { text, friend_id: 1 } }] }) })""",
            "secret words")
        await admin.select_option("#log-source", "client")
        await admin.fill("#log-q", "e2e client probe")
        await expect(admin.locator("#log-rows")).to_contain_text("[redacted]", timeout=10000)
        await expect(admin.locator("#log-rows")).not_to_contain_text("secret words")
        await expect(admin.locator("#log-rows .log-client").first).to_have_text("web app")
        client_logs = await admin.evaluate("""async () => (await fetch('/api/admin/logs?source=client&level=debug&limit=500',
            { headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } })).json()""")
        assert all(e["target"].startswith("client::") for e in client_logs["entries"])
        assert "signed up" in [e["message"] for e in client_logs["entries"]], "the app reports its own sign-up"
        await admin.fill("#log-q", "")
        await admin.select_option("#log-source", "")
        print("client logs: arrive labeled, redacted, filterable")

        await admin.fill("#log-q", OTHER)
        await expect(admin.locator("#log-rows")).to_contain_text("account created")
        await expect(admin.locator("#log-rows tr", has_text="account created")).to_have_count(1)
        await admin.fill("#log-q", f"user_id=999999")
        await expect(admin.locator("#log-rows")).to_contain_text("No matching entries")
        await admin.fill("#log-q", "")
        await admin.select_option("#log-level", "error")
        await expect(admin.locator("#log-rows")).to_contain_text("No matching entries")
        await admin.select_option("#log-level", "")
        await expect(admin.locator(".log-level-debug").first).to_be_visible()
        await shot(admin, "admin-logs", full_page=False)
        print("logs: events present, searchable, filterable, no secrets or content")

        phone = await page_for(browser, "phone", 390, 844)
        await phone.evaluate("(t) => localStorage.setItem('fade.token', t)",
                             await admin.evaluate("localStorage.getItem('fade.token')"))
        await phone.goto(BASE + "/admin")
        await expect(phone.locator("#admin")).to_be_visible(timeout=10000)
        overflow = await phone.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"page scrolls sideways by {overflow}px"
        await shot(phone, "admin-phone")
        await phone.goto(BASE + "/admin#logs")
        await expect(phone.locator("#log-rows tr").first).to_be_visible()
        overflow = await phone.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        assert overflow <= 0, f"logs page scrolls sideways by {overflow}px"
        await shot(phone, "admin-logs-phone", full_page=False)
        await browser.close()

    assert not errors, errors
    print("OTHER_USER", OTHER)
    print("ADMIN TEST PASSED")


asyncio.run(main())
