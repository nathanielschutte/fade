"""Signing out leaves nothing of the account behind in the browser, for
whoever signs in next (app.js, signOutLocally): not on screen, not in memory,
not on the device. The pinned keys go too (Nate, 2026-11-06): no local or
session storage, no IndexedDB databases (the fresh page keeps the server's
public settings again, which are the same for everyone), nothing in Cache
Storage, no cookies (common.py, nothing_kept). Another tab of the same
browser starts over with it. Signing in clears whatever another account left
(an older napsack kept pins at sign-out; a tab may never have signed out)
before anything is used. The bug this guards: after signing out, the next
account's chat list first showed the previous account's chats. Deleting the
account forgets the same way (test_delete_account.py). Settings come from the
environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, KEPT, api, befriend, launch, nothing_kept, row, shot, sign_in, sign_out, sign_up

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
errors = []

# What an older napsack (or a tab that never signed out) left behind: another
# account's pins in the keystore, and its kept chat list in the cache.
LEAVE = """async ([id, key]) => {
  const put = (db, store, k, v) => new Promise((resolve, reject) => {
    const open = indexedDB.open(db, 1);
    open.onupgradeneeded = () => open.result.createObjectStore(store);
    open.onsuccess = () => {
      const tx = open.result.transaction(store, 'readwrite');
      tx.objectStore(store).put(v, k);
      tx.oncomplete = () => { open.result.close(); resolve(); };
      tx.onerror = () => reject(tx.error);
    };
    open.onerror = () => reject(open.error);
  });
  await put('napsack', 'keys', 'pins:' + id, { [id + 1]: key });
  await put('napsack', 'keys', 'pastPins:' + id, { [id + 1]: [key] });
  await put('napsack-cache', 'responses', id + ':friends', { value: [{ id: id + 1, username: 'someone_else' }], at: Date.now() });
}"""


async def only_theirs(page, user_id):
    """What's kept belongs to `user_id` alone: its key and pins, its kept answers."""
    kept = await page.evaluate(KEPT)
    assert set(kept["keys"]) <= {"identity", f"pins:{user_id}", f"pastPins:{user_id}"}, kept
    assert all(k in ("me", "config") or k.startswith(f"{user_id}:") for k in kept["cache"]), kept
    who = await page.evaluate("""() => new Promise((resolve) => {
      const open = indexedDB.open('napsack', 1);
      open.onsuccess = () => {
        const r = open.result.transaction('keys').objectStore('keys').get('identity');
        r.onsuccess = () => { open.result.close(); resolve(r.result?.userId); };
      };
    })""")
    assert who == user_id, (who, user_id)
    return kept


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)
        # Ben has an account; Ana and Cal are friends, and Cal has written to her.
        ben = await sign_up(browser, BEN, errors=errors)
        ben_id = (await api(ben, "GET", "/me"))["id"]
        await ben.context.close()
        ana = await sign_up(browser, ANA, errors=errors)
        ana_id = (await api(ana, "GET", "/me"))["id"]
        cal = await sign_up(browser, CAL, errors=errors)
        await befriend(cal, ana, ANA, CAL)
        await row(cal, ANA).click()
        await cal.fill("#composer-input", "only for ana")
        await cal.press("#composer-input", "Enter")
        await expect(row(ana, CAL)).to_be_visible(timeout=10000)
        await expect(row(ana, CAL)).to_contain_text("only for ana", timeout=10000)
        # There's something to forget: the token, her key, her pins (Cal's key), her kept chats.
        await ana.wait_for_function(f"""async () => (await ({KEPT})()).keys.includes('pins:{ana_id}')""", timeout=10000)
        kept = await ana.evaluate(KEPT)
        assert kept["local"] and kept["cache"] and "identity" in kept["keys"], kept

        # Signing out asks first, saying what it does; a tap elsewhere takes it back.
        out, note = ana.locator("#sign-out"), ana.locator("#sign-out-note")
        await out.click()
        await expect(out).to_have_text("Tap again to sign out")
        await expect(note).to_be_visible()
        await expect(note).to_contain_text("leaves nothing of your account in this browser")
        await shot(ana, "sign-out-confirm", full_page=False)
        await ana.click("#chat-search")
        await expect(out).to_have_text("Sign out")
        await expect(note).to_be_hidden()
        await expect(ana.locator("#app")).to_be_visible()
        # The profile's Sign out asks the same way, with Delete account below it.
        await ana.click("#my-profile")
        p_out = ana.locator("#profile-sign-out")
        await expect(p_out).to_be_visible(timeout=10000)
        await p_out.click()
        await expect(p_out).to_have_text("Tap again to sign out")
        await expect(ana.locator("#profile-sign-out-note")).to_be_visible()
        # Waited for, not read once: the profile is still filling in (Blocked loads on its own).
        await ana.wait_for_function("""() => document.querySelector('#delete-account').getBoundingClientRect().top
          > document.querySelector('#profile-sign-out').getBoundingClientRect().top""", timeout=10000)
        await ana.locator("#profile-sign-out-note").scroll_into_view_if_needed()
        await shot(ana, "sign-out-confirm-profile", full_page=False)
        await ana.click("#profile-dialog [data-close]")
        await ana.click("#my-profile")
        await expect(p_out).to_have_text("Sign out")  # opening it again starts over
        await expect(ana.locator("#profile-sign-out-note")).to_be_hidden()
        await ana.click("#profile-dialog [data-close]")
        kept = await ana.evaluate(KEPT)
        assert kept["local"] and "identity" in kept["keys"], kept  # nothing went on the first tap
        print("sign out asks first, on the account bar and the profile")

        # Ana has a second tab open. She signs out in the first: nothing of
        # hers is left in the browser, pins included, and the other tab starts over too.
        other = await ana.context.new_page()
        other.on("pageerror", lambda e: errors.append(f"other tab: {e}"))
        await other.goto(BASE)
        await expect(row(other, CAL)).to_be_visible(timeout=10000)
        await sign_out(ana)
        await nothing_kept(ana)
        await expect(other.locator("#auth")).to_be_visible(timeout=10000)
        await expect(other.locator("#app")).to_be_hidden()
        assert await row(other, CAL).count() == 0
        print("signed out: nothing kept, pins included; her other tab signed out too")

        # Ben signs in on the same tab while his chat list is slow to come:
        # Ana's chats must never show, not even for a moment, nor her name.
        held = asyncio.Event()
        async def slow_friends(route):
            await held.wait()
            await route.continue_()
        await ana.route("**/api/friends?*", slow_friends)
        await sign_in(ana, BEN)
        await expect(ana.locator("#app")).to_be_visible()
        await expect(ana.locator("#my-name")).to_have_text(BEN)
        await asyncio.sleep(1)  # (the old bug drew the old list at once)
        assert await row(ana, CAL).count() == 0, "the previous account's chat showed"
        assert await ana.locator("#chat-list .chat-row").count() == 0
        held.set()
        await expect(ana.locator("#chat-empty")).to_be_visible(timeout=10000)
        assert await row(ana, CAL).count() == 0
        await ana.unroute("**/api/friends?*")
        await only_theirs(ana, ben_id)
        # The other tab, signed out all along, follows Ben in. Clearing out what
        # it found signed out never takes the key Ben's sign-in just kept: the
        # two take turns (app.js, withKeys), so both tabs stay signed in.
        await expect(other.locator("#my-name")).to_have_text(BEN, timeout=10000)
        await ana.reload()
        await expect(ana.locator("#my-name")).to_have_text(BEN, timeout=10000)
        await expect(other.locator("#app")).to_be_visible()
        await only_theirs(ana, ben_id)
        await other.close()
        print("the next account never sees the last one's chats, name, or pins; a second tab follows it in")

        # Signed in, what another account left (pins an older napsack kept at
        # sign-out) goes as the app opens, before anything of it is used.
        await ana.evaluate(LEAVE, [ana_id, "a key Ana once pinned"])
        await ana.reload()
        await expect(ana.locator("#app")).to_be_visible(timeout=10000)
        await expect(ana.locator("#chat-empty")).to_be_visible(timeout=10000)
        await only_theirs(ana, ben_id)
        assert await ana.get_by_text("someone_else").count() == 0
        print("another account's leftovers go when the app opens signed in")

        # Signed out, they go as the page opens; and signing in clears them
        # before anything is used, even when they come after the page opened.
        await sign_out(ana)
        await nothing_kept(ana)
        await ana.evaluate(LEAVE, [ana_id, "a key Ana once pinned"])
        await ana.reload()
        await expect(ana.locator("#auth")).to_be_visible(timeout=10000)
        await nothing_kept(ana)
        await ana.evaluate(LEAVE, [ana_id, "a key Ana once pinned"])
        await sign_in(ana, BEN)
        await expect(ana.locator("#chat-empty")).to_be_visible(timeout=10000)
        await only_theirs(ana, ben_id)
        assert await ana.get_by_text("someone_else").count() == 0
        print("leftovers from before go signed out, and again as someone signs in")

        # A session the server ends (signed out elsewhere): the same, and it says why.
        await sign_out(ana)
        await sign_in(ana, ANA)
        await expect(row(ana, CAL)).to_be_visible(timeout=10000)
        await ana.evaluate("""() => fetch('/api/auth/logout', { method: 'POST',
          headers: { Authorization: 'Bearer ' + localStorage.getItem('fade.token') } })""")
        await ana.reload()  # its next request finds the session over
        await expect(ana.locator("#auth")).to_be_visible(timeout=15000)
        await expect(ana.locator("#auth-error")).to_have_text("Your session ended. Sign in again.")
        await nothing_kept(ana)
        print("a session ended elsewhere: nothing kept, and the sign-in screen says why")

        assert not errors, errors
        print("SIGN OUT TEST PASSED")
        await browser.close()


asyncio.run(main())
