"""Signing out leaves nothing of the account behind in the browser, for
whoever signs in next (app.js, signOutLocally): not on screen, not in memory,
not on the device. Only the pinned keys stay (friends' public keys, which open
nothing). The bug this guards: after signing out, the next account's chat list
first showed the previous account's chats. Settings come from the environment;
see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import befriend, launch, row, sign_in, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
errors = []

# What napsack keeps in this browser: storage, the cache's entries, and the keystore's keys.
KEPT = """async () => {
  const keys = (db, store) => new Promise((resolve) => {
    const open = indexedDB.open(db, 1);
    open.onsuccess = () => {
      const r = open.result.transaction(store).objectStore(store).getAllKeys();
      r.onsuccess = () => { open.result.close(); resolve(r.result.map(String)); };
    };
    open.onerror = () => resolve(null);
  });
  return {
    local: Object.keys(localStorage), session: Object.keys(sessionStorage),
    cache: await keys('napsack-cache', 'responses'), keys: await keys('napsack', 'keys'),
  };
}"""


def nothing_of_theirs(kept):
    assert kept["local"] == [] and kept["session"] == [], kept
    # (The fresh page keeps the server's public settings again at once; they're the same for everyone.)
    assert set(kept["cache"]) <= {"config"}, kept
    assert all(k.startswith(("pins:", "pastPins:")) for k in kept["keys"]), kept


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        # Ben has an account; Ana and Cal are friends, and Cal has written to her.
        ben = await sign_up(browser, BEN, errors=errors)
        await ben.context.close()
        ana = await sign_up(browser, ANA, errors=errors)
        cal = await sign_up(browser, CAL, errors=errors)
        await befriend(cal, ana, ANA, CAL)
        await row(cal, ANA).click()
        await cal.fill("#composer-input", "only for ana")
        await cal.press("#composer-input", "Enter")
        await expect(row(ana, CAL)).to_be_visible(timeout=10000)
        await expect(row(ana, CAL)).to_contain_text("only for ana", timeout=10000)
        kept = await ana.evaluate(KEPT)
        assert kept["local"] and kept["cache"] and "identity" in kept["keys"], kept  # there was something to forget

        # Ana signs out: nothing of hers is left on the device.
        await ana.click("#sign-out")
        await expect(ana.locator("#auth")).to_be_visible(timeout=10000)
        nothing_of_theirs(await ana.evaluate(KEPT))

        # Ben signs in on the same tab while his chat list is slow to come:
        # Ana's chats must never show, not even for a moment.
        held = asyncio.Event()
        async def slow_friends(route):
            await held.wait()
            await route.continue_()
        await ana.route("**/api/friends?*", slow_friends)
        await sign_in(ana, BEN)
        await expect(ana.locator("#app")).to_be_visible()
        await asyncio.sleep(1)  # (the old bug drew the old list at once)
        assert await row(ana, CAL).count() == 0, "the previous account's chat showed"
        assert await ana.locator("#chat-list .chat-row").count() == 0
        held.set()
        await expect(ana.locator("#chat-empty")).to_be_visible(timeout=10000)
        assert await row(ana, CAL).count() == 0
        await ana.unroute("**/api/friends?*")
        print("signed out: nothing kept; the next account never sees the last one's chats")

        # A session the server ends (signed out elsewhere): the same, and it says why.
        await ana.click("#sign-out")
        await expect(ana.locator("#auth")).to_be_visible(timeout=10000)
        await sign_in(ana, ANA)
        await expect(row(ana, CAL)).to_be_visible(timeout=10000)
        await ana.evaluate("""() => fetch('/api/auth/logout', { method: 'POST',
          headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } })""")
        await ana.reload()  # its next request finds the session over
        await expect(ana.locator("#auth")).to_be_visible(timeout=15000)
        await expect(ana.locator("#auth-error")).to_have_text("Your session ended. Sign in again.")
        nothing_of_theirs(await ana.evaluate(KEPT))
        print("a session ended elsewhere: nothing kept, and the sign-in screen says why")

        assert not errors, errors
        print("SIGN OUT TEST PASSED")
        await browser.close()


asyncio.run(main())
