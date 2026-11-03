"""Passkeys on the web (F26, docs/design/passkeys.md):
- Sign-up recommends one right after the recovery key, made with the keys
  already in hand; signing in with it needs no password and opens every message.
- Security lists them (from any device), adds one with the password (not the
  same device twice), and removes them (two taps): a removed passkey is
  refused in the server's words, and its password manager is told to drop it.
- A passkey that gives its PRF answer only when used is asked once more, and
  the copy made from that answer opens.
- Closing the system's passkey sheet isn't an error.
- A passkey that can't give napsack its secret (no PRF) is never used: napsack
  says so plainly, registers nothing, and doesn't ask the server.

Chromium's virtual authenticator (DevTools' WebAuthn domain) stands in for a
device with Face ID that always says yes. Passkeys belong to a name, never an
address, so these pages open the app at http://localhost (PASSKEY_BASE).
Settings come from the environment; see common.py."""
import asyncio, uuid
from playwright.async_api import async_playwright, expect

from common import (PASSKEY_BASE, PASSWORD, PHONE, SIGN_IN_WAIT, befriend, fill_sign_up, launch,
                    no_placeholders, open_page, row, save_recovery_key, shot, sign_in, sign_up)

tag = uuid.uuid4().hex[:5]
ANA, BEN, CAL = f"ana_{tag}", f"ben_{tag}", f"cal_{tag}"
DESKTOP = {"viewport": {"width": 1200, "height": 800}}
errors = []

# What the app says (app.js) and the server says (passkeys.rs).
NO_PRF_ADD = "This device's passkeys can't unlock your messages, so napsack can't use them here. Your password still works."
NO_PRF_SIGN_IN = "This passkey can't unlock napsack here. Sign in with your password."
SAME_DEVICE = "This device already has a passkey for napsack."
REMOVED = "That passkey isn't set up for napsack any more. Sign in with your password."


async def device(browser, prf=True, **ctx):
    """A page at the app on a device whose authenticator always says yes;
    with `prf` false, its passkeys can't give napsack a secret. The
    authenticator is there before the app loads, as Face ID would be.
    Returns the page, its DevTools session, and the authenticator's id."""
    held = {}

    async def attach(page):
        cdp = await page.context.new_cdp_session(page)
        await cdp.send("WebAuthn.enable", {"enableUI": False})
        made = await cdp.send("WebAuthn.addVirtualAuthenticator", {"options": {
            "protocol": "ctap2", "ctap2Version": "ctap2_1", "transport": "internal",
            "hasResidentKey": True, "hasUserVerification": True, "isUserVerified": True,
            "hasPrf": prf, "automaticPresenceSimulation": True}})
        held.update(cdp=cdp, id=made["authenticatorId"])

    page = await open_page(browser, errors=errors, base=PASSKEY_BASE, prepare=attach, **ctx)
    return page, held["cdp"], held["id"]


def next_event(cdp, name):
    """Resolves with the authenticator's next `name` event: WebAuthn.credentialDeleted
    when it drops a passkey (signalUnknownCredential), WebAuthn.credentialAsserted when
    a passkey is used."""
    done = asyncio.get_running_loop().create_future()
    cdp.on(name, lambda e: done.done() or done.set_result(e))
    return done


# As some passkeys do (Safari's, for one): PRF turned on when made, but its
# answer given only when the passkey is used, so napsack asks it once more.
PRF_ONLY_WHEN_USED = """{
  const real = PublicKeyCredential.prototype.getClientExtensionResults;
  PublicKeyCredential.prototype.getClientExtensionResults = function () {
    const results = real.call(this);
    return this.response instanceof AuthenticatorAttestationResponse && results.prf
      ? { ...results, prf: { enabled: true } } : results;
  };
}"""


async def kept(cdp, authenticator):
    return (await cdp.send("WebAuthn.getCredentials", {"authenticatorId": authenticator}))["credentials"]


async def open_security(page, phone):
    await page.click("#tab-profile" if phone else "#my-profile")
    await expect(page.locator("#profile-security")).to_be_visible(timeout=10000)


async def sign_out(page, phone):
    if phone:
        await page.click("#tab-profile")
        await page.click("#profile-sign-out")
    else:
        await page.click("#sign-out")
    await expect(page.locator("#auth")).to_be_visible(timeout=10000)


async def main():
    async with async_playwright() as pw:
        browser = await launch(pw)

        # Ana's phone. The sign-in screen offers a passkey; creating an account doesn't.
        ana, ana_cdp, ana_key = await device(browser, **PHONE)
        await expect(ana.locator("#passkey-sign-in")).to_be_visible()
        await shot(ana, "passkey-sign-in-phone", full_page=False)
        await ana.click("#auth-toggle")
        await expect(ana.locator("#passkey-sign-in")).to_be_hidden()
        await fill_sign_up(ana, ANA, toggle=False, save_key=False)

        # Right after the recovery key: a passkey, recommended; added without the password again.
        await save_recovery_key(ana, keep_offer=True)
        offer = ana.locator("#passkey-offer")
        await expect(offer).to_be_visible()
        await expect(ana.locator("#passkey-offer-text")).to_contain_text("Face ID or your fingerprint")
        await shot(ana, "passkey-offer-phone", full_page=False)
        await ana.click("#passkey-offer-add")
        await expect(ana.locator("#passkey-offer-text")).to_contain_text("Passkey added", timeout=SIGN_IN_WAIT)
        await expect(ana.locator("#passkey-offer-error")).to_have_text("")
        await ana.click("#passkey-offer-later")                         # "Done"
        await expect(offer).to_be_hidden()
        assert len(await kept(ana_cdp, ana_key)) == 1
        print("sign-up: the offer follows the recovery key; a passkey added with the keys in hand")

        # Ben, a friend, writes to her (from another origin: same server).
        ben = await sign_up(browser, BEN, errors=errors)
        await befriend(ben, ana, ANA, BEN)
        await expect(row(ben, ANA)).to_be_visible(timeout=10000)
        await row(ben, ANA).click()
        await ben.fill("#composer-input", "for ana only")
        await ben.press("#composer-input", "Enter")
        await expect(row(ana, BEN)).to_contain_text("for ana only", timeout=10000)
        # Ben's page is at an address (127.0.0.1), where passkeys can't work: none offered.
        await open_security(ben, phone=False)
        await expect(ben.locator("#passkey-list")).to_have_text("No passkeys yet.", timeout=10000)
        await expect(ben.locator("#passkey-add")).to_be_hidden()
        await ben.click("#profile-dialog [data-close]")

        # She signs out, and back in with the passkey alone: the text opens.
        await sign_out(ana, phone=True)
        await ana.click("#passkey-sign-in")
        await expect(ana.locator("#app")).to_be_visible(timeout=SIGN_IN_WAIT)
        await expect(row(ana, BEN)).to_contain_text("for ana only", timeout=10000)
        await row(ana, BEN).click()
        await expect(ana.locator(".msg", has_text="for ana only")).to_be_visible(timeout=10000)
        await ana.click("#back-button")
        print("signed in with the passkey, no password: the text decrypts")

        # Her laptop, whose passkeys give their PRF answer only when used.
        # Security lists the phone's passkey; adding one there asks the password.
        laptop, lap_cdp, lap_key = await device(browser, init=PRF_ONLY_WHEN_USED, **DESKTOP)
        await expect(laptop.locator("#passkey-sign-in")).to_be_visible()
        await shot(laptop, "passkey-sign-in-desktop", full_page=False)
        await sign_in(laptop, ANA)
        await open_security(laptop, phone=False)
        listed = laptop.locator("#passkey-list .passkey")
        await expect(listed).to_have_count(1, timeout=10000)
        await expect(listed.first).to_contain_text("Passkey")
        await expect(listed.first).to_contain_text("last used")
        await laptop.click("#passkey-add")
        await expect(laptop.locator("#password-title")).to_have_text("Add a passkey")
        await laptop.fill("#password-form input[name=current_password]", "not her password")
        await laptop.click("#password-submit")
        await expect(laptop.locator("#password-error")).to_contain_text("current password isn't right", timeout=SIGN_IN_WAIT)
        assert await kept(lap_cdp, lap_key) == [], "nothing made before the password checked out"
        used = next_event(lap_cdp, "WebAuthn.credentialAsserted")
        await laptop.fill("#password-form input[name=current_password]", PASSWORD)
        await laptop.click("#password-submit")
        await expect(laptop.locator("#passkey-note")).to_have_text("Passkey added.", timeout=SIGN_IN_WAIT)
        await asyncio.wait_for(used, 10)                                  # asked once more, for its answer
        await expect(laptop.locator("#password-dialog")).to_be_hidden()
        await expect(listed).to_have_count(2)
        await expect(listed.nth(1)).to_contain_text("not used yet")
        await no_placeholders(laptop, "#profile-dialog")

        # The same device again: it already has one.
        await laptop.click("#passkey-add")
        await laptop.fill("#password-form input[name=current_password]", PASSWORD)
        await laptop.click("#password-submit")
        await expect(laptop.locator("#password-error")).to_have_text(SAME_DEVICE, timeout=SIGN_IN_WAIT)
        await laptop.click("#password-dialog [data-close]")
        assert len(await kept(lap_cdp, lap_key)) == 1
        await listed.first.scroll_into_view_if_needed()
        await shot(laptop, "passkeys-security-desktop", full_page=False)
        print("Security: lists every passkey; adding one asks the password; not twice on one device")

        # The copy made from that later answer opens: the laptop signs in with its passkey.
        await laptop.click("#profile-dialog [data-close]")
        await sign_out(laptop, phone=False)
        await laptop.click("#passkey-sign-in")
        await expect(laptop.locator("#app")).to_be_visible(timeout=SIGN_IN_WAIT)
        await expect(row(laptop, BEN)).to_contain_text("for ana only", timeout=10000)
        await open_security(laptop, phone=False)
        await expect(listed).to_have_count(2, timeout=10000)
        await expect(listed.nth(1)).to_contain_text("last used")
        print("a passkey that answers PRF only when used: asked again, and it signs in")

        # The phone sees both.
        await open_security(ana, phone=True)
        phone_listed = ana.locator("#passkey-list .passkey")
        await expect(phone_listed).to_have_count(2, timeout=10000)
        await no_placeholders(ana, "#profile-dialog")
        await phone_listed.first.scroll_into_view_if_needed()
        await shot(ana, "passkeys-security-phone", full_page=False)
        overflow = await ana.evaluate("document.querySelector('#profile-dialog').scrollWidth - document.querySelector('#profile-dialog').clientWidth")
        assert overflow <= 0, f"the profile scrolls sideways by {overflow}px"
        await ana.click("#tab-chats")

        # The laptop removes the phone's passkey (the older one), with two taps.
        remove = listed.first.locator("button")
        await remove.click()
        await expect(remove).to_have_text("Tap again to remove")
        await shot(laptop, "passkeys-remove-desktop", full_page=False)
        await remove.click()
        await expect(laptop.locator("#passkey-note")).to_have_text("Passkey removed.", timeout=10000)
        await expect(listed).to_have_count(1)
        await expect(listed.first).to_contain_text("last used")

        # The phone still has it, but the server refuses it, and says so.
        await sign_out(ana, phone=True)
        await ana.click("#passkey-sign-in")
        await expect(ana.locator("#auth-error")).to_have_text(REMOVED, timeout=SIGN_IN_WAIT)
        await expect(ana.locator("#app")).to_be_hidden()
        await expect(ana.locator("#passkey-sign-in")).to_be_enabled()
        print("removed: signing in with it is refused in the server's words")

        # Closing the system's sheet (here, Face ID not recognized) is no error.
        await ana_cdp.send("WebAuthn.setUserVerified", {"authenticatorId": ana_key, "isUserVerified": False})
        await ana.click("#passkey-sign-in")
        await expect(ana.locator("#passkey-sign-in")).to_have_text("Sign in with a passkey", timeout=10000)
        await expect(ana.locator("#passkey-sign-in")).to_be_enabled()
        await expect(ana.locator("#auth-error")).to_have_text("")
        print("a closed passkey sheet says nothing")

        # The laptop removes its own: its authenticator is told to drop it too.
        gone = next_event(lap_cdp, "WebAuthn.credentialDeleted")
        remove = listed.first.locator("button")
        await remove.click()
        await remove.click()
        await expect(laptop.locator("#passkey-list")).to_have_text("No passkeys yet.", timeout=10000)
        await asyncio.wait_for(gone, 10)
        assert await kept(lap_cdp, lap_key) == []
        print("removing a passkey tells the password manager to drop it")

        # Cal's computer has passkeys that can't give napsack a secret (no PRF).
        cal, cal_cdp, cal_key = await device(browser, prf=False, **DESKTOP)
        await fill_sign_up(cal, CAL, save_key=False)
        await save_recovery_key(cal, keep_offer=True)
        await expect(cal.locator("#passkey-offer")).to_be_visible()
        await shot(cal, "passkey-offer-desktop", full_page=False)
        orphan = next_event(cal_cdp, "WebAuthn.credentialDeleted")
        await cal.click("#passkey-offer-add")
        await expect(cal.locator("#passkey-offer-error")).to_have_text(NO_PRF_ADD, timeout=SIGN_IN_WAIT)
        await expect(cal.locator("#passkey-offer-add")).to_be_hidden()
        await asyncio.wait_for(orphan, 10)                                # the one just made is dropped
        await cal.click("#passkey-offer-later")                          # "OK"
        await expect(cal.locator("#passkey-offer")).to_be_hidden()
        await open_security(cal, phone=False)
        await expect(cal.locator("#passkey-list")).to_have_text("No passkeys yet.", timeout=10000)
        await cal.click("#profile-dialog [data-close]")

        # A passkey there can't sign in either, and the server isn't asked.
        await cal.evaluate("""() => navigator.credentials.create({ publicKey: {
          rp: { id: location.hostname, name: "napsack" }, user: { id: new Uint8Array([7]), name: "cal", displayName: "cal" },
          challenge: new Uint8Array(32), pubKeyCredParams: [{ type: "public-key", alg: -7 }],
          authenticatorSelection: { residentKey: "required", userVerification: "required" } } })""")
        asked = []
        cal.on("request", lambda r: r.method == "POST" and r.url.endswith("/api/auth/passkey") and asked.append(r.url))
        await sign_out(cal, phone=False)
        await cal.click("#passkey-sign-in")
        await expect(cal.locator("#auth-error")).to_have_text(NO_PRF_SIGN_IN, timeout=SIGN_IN_WAIT)
        assert asked == [], asked
        print("no PRF: said plainly, nothing registered, the server never asked")

        assert not errors, errors
        print("PASSKEYS TEST PASSED")
        await browser.close()


asyncio.run(main())
