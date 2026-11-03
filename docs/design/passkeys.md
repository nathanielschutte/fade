# Passkeys

Status: decided (Nate, 2026-11-03, [plan.md](../management/plan.md) F26); being built.

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
