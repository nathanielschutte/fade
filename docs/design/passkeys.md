# Passkeys

Status: decided (Nate, 2026-11-03, [plan.md](../management/plan.md) F26). Built for the server and the web ([Built](#built), below); the iOS app is being built.

Sign in with Face ID, Touch ID, or Windows Hello instead of a password. A passkey normally only proves who you are; napsack also needs your private key on the device, so the passkey must unlock that too. WebAuthn's **PRF extension** does it: the passkey gives the browser or app a secret only it can produce, the same every time, and napsack wraps a copy of your private key with it.

## How it fits beside the password

Today your private key is stored on the server wrapped twice: by your password and by your recovery key. A passkey adds a third wrap. Any one of the three opens it; the password and recovery key keep working, so losing a phone with the passkey costs nothing.

## Setting one up (signed in)

1. Profile › Security › Add a passkey: the password once (to unlock the key, as for a recovery key).
2. The browser or iPhone makes a passkey for napsack (relying party: the site, `napsack.io`; the iOS app may use it through the site association, `webcredentials`, done in F23), with PRF.
3. The device evaluates PRF on a fixed napsack label, derives a wrap key (HKDF), wraps the private key (AES-GCM, as the recovery key's wrap), and sends the server the passkey's public key and the wrapped copy.

## Signing in

1. "Sign in with a passkey": the browser or app asks for one (Face ID), with PRF.
2. The server checks the passkey's signature over its challenge (ES256, as WebAuthn defines), and answers with a session and the passkey-wrapped key.
3. The device unwraps it with the PRF secret. No password typed, and the server never sees the secret.

## Safety

- The server stores only the passkey's public key and a wrapped copy it can't open (it never gets the PRF secret).
- A passkey synced through iCloud Keychain or a password manager goes wherever that account goes; that's the platform's protection, as for saved passwords.
- Removing a passkey (Security) marks its row ended (Rule 1); changing the password leaves passkeys working (the key itself is unchanged).

## What it needs

- **A new format** (the PRF wrap): crypto.js first, then Swift; vectors (`tests/vectors/passkey1.json`) with an independent Python check.
- Server: WebAuthn registration and assertion checks (ES256 over `authenticatorData` and `clientDataJSON`, origin and relying party checked), a table of passkeys, challenges that expire, limits, smoke checks. Likely by hand, as Web Push was, rather than a large dependency; to decide when it's built.
- Web: `navigator.credentials.create/get` with `prf`. iOS: `ASAuthorizationPlatformPublicKeyCredentialProvider` with PRF (iOS 18).
- Where PRF isn't supported (some browsers and older devices), passkeys aren't offered: the password works everywhere.

## Decided (Nate, 2026-11-03)

- Staging's site is its own relying party (`staging.napsack.io`), so passkeys made there only work there: fine.
- Sign-up starts with a password, as now. Right after it (as the recovery key is shown), napsack recommends adding a passkey; Security offers it any time.

## Built

**The server** (`webauthn.rs`, `passkeys.rs`, migration `0027_passkeys.sql`). WebAuthn is checked by hand, as Web Push is: a small CBOR reader, ES256 only, no attestation (any authenticator will do, so nothing about it is trusted), the person verified every time, and the site's own name as the relying party (`passkey_rp_id` in `/api/config`; `localhost`, on any port, in development). Challenges live in memory, are used once, last 5 minutes, and at most 10,000 wait at once. Adding one needs the password; there are at most 10 per account; removing one marks its row ended (Rule 1); an admin's reset code ends them all (`end_reason = 'key_reset'`); deleting the account wipes them. Endpoints: [api.md](../spec/api.md). Tested: `webauthn::tests` and the smoke test's `check_passkeys`, with a stand-in authenticator.

**The format** (`crypto.js`): `passkeyPrfInput` (SHA-256 of `napsack/v1/passkey/prf`), `deriveFromPasskey` (HKDF, info `napsack/v1/passkey/wrap`), `wrapForPasskey` and `unwrapWithPasskey` (AES-GCM, associated string `napsack/v1/passkey`). Pinned vectors in `tests/vectors/passkey1.json`, with an independent Python check (`check_passkey1.py`).

**The web** (`app.js`, its passkeys section):
- The sign-in screen has **Sign in with a passkey** wherever passkeys can work: the browser has WebAuthn and doesn't say PRF is missing (`getClientCapabilities`), and the page is at `passkey_rp_id` (a passkey belongs to a name, so never at an address like 127.0.0.1). It asks for any of the site's passkeys (no list), with the person verified and PRF evaluated on napsack's input. Without a PRF answer it doesn't ask the server: "This passkey can't unlock napsack here. Sign in with your password." Closing the system's sheet isn't an error, so nothing is said.
- Right after sign-up, once the recovery key is saved, the same moment brings the offer (**Add a passkey** / **Not now**), on a device that makes passkeys itself (`isUserVerifyingPlatformAuthenticatorAvailable`). It uses the sign-up's keys, still in memory, so the password isn't asked again; they're dropped when the offer closes.
- Your profile's **Passkeys** lists every passkey on the account, from any device: where it's kept ("iCloud Keychain", or "Passkey" when the authenticator isn't a well-known one), when it was added, and when it was last used. **Add a passkey** asks the password first. **Remove** takes two taps, then tells the password manager to drop it (`signalUnknownCredential`, where the browser has it).
- Making one: ES256, a discoverable credential, user verification required, no attestation, and the account's passkeys excluded, so a device can't make a second ("This device already has a passkey for napsack."). The secret comes from PRF when the passkey is made or, when it only says PRF is on, from one use of the new passkey. With neither, napsack says this device's passkeys can't unlock it, registers nothing, and tells the password manager to drop the passkey it just made.
- Nothing new is kept in the browser, and the PRF secret is zeroed once used. Tested: `tests/e2e/test_passkeys.py`, with Chromium's virtual authenticator.

**The iOS app**: being built ([plan-ios.md](../management/plan-ios.md)).

**Later**, not built: passkeys offered in the username field as it's filled in (WebAuthn's conditional mediation); telling the password manager the full list of passkeys that still work (`signalAllAcceptedCredentials`), so ones removed elsewhere go too; recommending a passkey after an admin's reset code as well as after sign-up.
