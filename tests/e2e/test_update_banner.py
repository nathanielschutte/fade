"""An open tab offers a reload once the server is running a newer build.
Settings come from the environment; see common.py."""
import asyncio, json, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, launch, shot


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        ctx = await browser.new_context()
        page = await ctx.new_page()

        # Pretend a deploy happens after the page loads: /api/config reports a new build.
        deployed = {"yet": False}
        async def config(route):
            resp = await route.fetch()
            body = await resp.json()
            body["build"] = "build-b" if deployed["yet"] else "build-a"
            await route.fulfill(response=resp, body=json.dumps(body))
        await page.route("**/api/config", config)

        # Proxy the live socket so the test can drop it, as a server restart would.
        sockets = []
        def proxy(ws):
            ws.connect_to_server()
            sockets.append(ws)
        await page.route_web_socket("**/api/ws", proxy)

        await page.goto(BASE)
        await page.click("#auth-toggle")
        await page.fill("input[name=username]", f"ivy_{uuid.uuid4().hex[:5]}")
        await page.fill("input[name=password]", "correct horse battery")
        await page.fill("input[name=invite_code]", INVITE)
        await page.click("#auth-submit")
        await expect(page.locator("#app")).to_be_visible(timeout=20000)
        await page.wait_for_timeout(1000)  # the first socket connect also checks
        await expect(page.locator("#update-banner")).to_be_hidden()

        # A deploy restarts the server, which drops every socket.
        deployed["yet"] = True
        assert sockets, "the app never opened its socket"
        await sockets[-1].close()
        await expect(page.locator("#update-banner")).to_be_visible(timeout=40000)
        await shot(page, "update-banner")
        await browser.close()
    print("UPDATE BANNER TEST PASSED")


asyncio.run(main())
