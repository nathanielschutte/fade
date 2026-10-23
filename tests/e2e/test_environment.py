"""Non-production copies say so (env.js): "napsack (staging)" in the title, a
tag by the wordmark, a band across the top, and the build in the corner.
Production shows none of it. Locally the server is production-like, so the
staging look is tried by answering /api/config with an environment; against
staging (NAPSACK_REMOTE=1) it's the real thing. Settings come from the
environment; see common.py."""
import asyncio, json
import requests
from playwright.async_api import async_playwright, expect

import uuid

from common import BASE, INVITE, REMOTE, launch, save_recovery_key, shot

PHONE = {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True}
errors = []


async def page_for(browser, env=None, **ctx):
    p = await (await browser.new_context(**ctx)).new_page()
    p.on("pageerror", lambda e: errors.append(str(e)))
    if env:
        async def answer(route):
            res = await route.fetch()
            config = await res.json()
            config["environment"] = env
            await route.fulfill(response=res, body=json.dumps(config))
        await p.route("**/api/config", answer)
    return p


async def check_marked(p, env, config):
    await expect(p.locator("html")).to_have_attribute("data-env", env, timeout=10000)
    await expect(p.locator(".env-band")).to_have_count(1)
    build = p.locator(".env-build")
    await expect(build).to_contain_text(f"{env} · v{config['server_version']} · {config['build']} · up ")
    assert await build.evaluate("e => getComputedStyle(e).pointerEvents") == "none", "never in the way of a tap"
    assert await p.locator('meta[name="theme-color"]').get_attribute("content") == "#e8a33d"
    overflow = await p.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert overflow <= 0, f"scrolls sideways by {overflow}px"
    assert await p.evaluate(COVERS) == [], await p.evaluate(COVERS)


# The build line sits in a corner; it must not cover any words on the page
# (taps already pass through it). Checks every visible piece of text.
COVERS = """() => {
  const b = document.querySelector('.env-build').getBoundingClientRect();
  const hit = [];
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    if (!n.textContent.trim() || n.parentElement.closest('.env-build')) continue;
    const range = document.createRange();
    range.selectNodeContents(n);
    for (const r of range.getClientRects()) {
      if (r.width && !(r.right <= b.left || r.left >= b.right || r.bottom <= b.top || r.top >= b.bottom)) hit.push(n.textContent.trim().slice(0, 30));
    }
  }
  return hit;
}"""


async def main():
    config = requests.get(f"{BASE}/api/config", timeout=30).json()
    async with async_playwright() as pw:
        browser = await launch(pw)

        if not REMOTE:
            # Production (no environment): none of it.
            assert config["environment"] is None, config
            p = await page_for(browser, **PHONE)
            await p.goto(BASE)
            await expect(p.locator(".wordmark").first).to_be_visible(timeout=15000)
            await asyncio.sleep(0.5)
            assert await p.evaluate("document.documentElement.dataset.env") is None
            assert await p.title() == "napsack"
            assert await p.locator(".env-band, .env-build, .env-tag").count() == 0
            assert await p.locator('meta[name="theme-color"]').get_attribute("content") == "#1b2822"

        env = config["environment"] if REMOTE else "staging"
        assert env, "staging reports its environment"

        # The app, on a phone: the sign-in screen.
        p = await page_for(browser, None if REMOTE else env, **PHONE)
        await p.goto(BASE)
        await check_marked(p, env, config)
        await expect(p.locator(".wordmark .env-tag").first).to_have_text(env)
        assert await p.title() == f"napsack ({env})"
        await shot(p, "environment-phone", full_page=False)
        # Signed in: the chat list, then a chat, with nothing under the build line.
        name = f"env_{uuid.uuid4().hex[:5]}"
        await p.click("#auth-toggle")
        await p.fill("#auth-form input[name=username]", name)
        await p.fill("#auth-form input[name=password]", "correct horse battery")
        await p.fill("#auth-form input[name=invite_code]", INVITE)
        await p.click("#auth-submit")
        await expect(p.locator("#app")).to_be_visible(timeout=20000)
        await save_recovery_key(p)
        assert await p.title() == f"napsack ({env})"
        await shot(p, "environment-list-phone", full_page=False)
        assert await p.evaluate(COVERS) == [], await p.evaluate(COVERS)

        # The System page, on a computer, before signing in: marked all the same.
        d = await page_for(browser, None if REMOTE else env, viewport={"width": 1200, "height": 800})
        await d.goto(f"{BASE}/admin")
        await check_marked(d, env, config)
        await expect(d.locator(".wordmark .env-tag")).to_have_text(env)
        assert await d.title() == f"napsack system ({env})"
        await shot(d, "environment-system", full_page=False)

        assert not errors, errors
        await browser.close()
    print("ENVIRONMENT TEST PASSED")


asyncio.run(main())
