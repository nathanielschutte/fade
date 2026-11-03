# Sign in by scanning

Status: proposed (Nate, 2026-11-03, [plan.md](../management/plan.md) F25). Nothing built; for Nate to review.

On a new phone or computer, napsack shows a QR code. You scan it with a device you're already signed in on, confirm, and the new device is signed in, your messages readable, without typing your password there.

## What has to move

Signing in gives a device two things: a session (to talk to the server) and your private key (to open messages). Today the key comes from the server wrapped by your password, and only the password unwraps it. Here the key comes from your other device instead, encrypted so only the new device can open it. The server relays it and can't read it, exactly as with messages.

## The steps

1. **The new device** makes a fresh key pair just for this (P-256, never kept), asks the server for a link (`POST /api/link`, signed out, limited per address like sign-in), and shows a QR holding the link id and its public key, with a short code under it. The link lasts 2 minutes.
2. **The signed-in device** scans it. It shows the same short code (worked out from both keys, so a swapped QR shows a different one) and asks plainly: "Sign in on a new device? Only if it's yours and in front of you." Nothing moves until you tap Sign in.
3. It makes its own fresh key pair, derives a key with the new device's (ECDH, then HKDF), seals your private key with it (AES-GCM, associated data naming the link), and sends that to the server for the link (`POST /api/link/{id}/approve`, signed in).
4. **The server** makes a new session for your account (it counts toward the 10 devices) and holds the sealed key and the token for the new device, once.
5. **The new device** collects them (it waits on the link), opens your key with its own, checks the key matches your account's public key (so a server that made up a key is caught), keeps it in the Keychain or the browser's key store as a sign-in would, and forgets the one-time keys.

## Safety

- **The server never has the key:** the two devices agree on a key it can't learn (it only relays public keys, and the new device's comes straight off its screen, not through the server).
- **Someone showing you their QR** (to get your key onto their device) is the real risk. That's why the confirmation is explicit, says what it does, and shows the code. The new device also shows up in Account security as a signed-in device, and "Sign out other devices" ends it.
- Links are single-use, expire in 2 minutes, and are limited per address and per account.
- Nothing about it is logged beyond "device linked" with ids.

## What it needs

- **A new format**, so it lands as every new format does (CLAUDE.md, Encryption): `shared/crypto/crypto.js` first, then Swift; a new vector file (`tests/vectors/link1.json`) generated once, an independent Python check, and the vector checks in both apps.
- Server: three endpoints (`POST /api/link`, `POST /api/link/{id}/approve`, `GET /api/link/{id}`), a table for links (marked used or expired, never deleted), limits, and smoke checks.
- Web: "Sign in with your phone" on the sign-in screen showing the QR, and "Sign in a new device" (the scanner) in the profile. iOS: both too (the scanner is VisionKit's, as Scan their code).

## Questions for Nate

- Should a new device need the password once anyway, later (for example to change the password, which needs it today regardless)?
- Both ways (the phone signs in a computer, and a computer signs in a phone), or phone-to-computer first?
