# iOS plan

Everything we're doing to bring napsack to the iPhone as a native client, in order. It's the task list behind the [iOS app row](plan.md#tracker) in [plan.md](plan.md), whose rules and conventions apply here too (Who is a person's name; new ideas get written down before they're built). Why native Swift, the milestones' reasoning, and releasing are in [mobile.md](../design/mobile.md); setting up and building are in [ios-onboarding.md](../ios-onboarding.md).

Status: **Done** · **In progress** · **Up next** · **Planned** · **Needs decision** · **Waiting** (on something outside our hands). Work top to bottom.

## 1. The encryption, in Swift

The riskiest part first: the app has to produce exactly the bytes the web client does, for every format.

| Task | Who | Status | Notes |
|---|---|---|---|
| The project: Xcode app, Swift package, settings, docs | Nate | Done | 2026-10-29 (#7): `ios/`, [ios-onboarding.md](../ios-onboarding.md) |
| Format 1 in Swift: the password's keys, the identity, chat keys, texts and pics | Nate | Done | 2026-10-29 (#7) |
| Every other format: recovery keys, safety codes, format 2 texts (replies), reactions, edits, format 2 pics, format 3 groups, formats 4 to 7 (videos, photos) | Nate | Done | 2026-10-29: `NapsackCryptoChecks` is `vector-checks.js` in Swift, all 64 checks pass; a key made in Swift opens in the web client and back |
| The checks on the iPhone itself, and how long the key derivation takes there | Nate | Done | 2026-10-29: 64 of 64 on the iPhone 16 Pro; PBKDF2 (600,000 rounds) takes about 492 ms there, well inside the bar of near a second |

## 2. Signing in, and the chats

A skeleton that does the real thing against a server: sign in, see your chats, read and send texts.

| Task | Who | Status | Notes |
|---|---|---|---|
| Sign in: username and password to keys, the private key unwrapped and kept in the Keychain (this device only, readable while unlocked), the session token too | Nate | Done | 2026-10-29 (#11): `Session`, `Keychain`, the sign-in and home screens; tested against a stand-in and a real local server, and by Nate on the iPhone against production and his Mac |
| The API client: the `X-Napsack-Client` header on everything, signed out on 401, an update screen on 426 | Nate | Done | 2026-10-29: the update screen shows for a 426 or when `/api/config` needs a newer app at launch (checked against a real server needing 1.2.0); development builds can leave it to pick another server. The App Store link comes with the App Store |
| Sign up: invite code, a new identity, the recovery key shown once | Nate | Done | 2026-10-29 (#12): the sign-in screen's other mode, asking for an invite code only when the server does; the recovery key registered and shown until "I've saved it". Tested against a stand-in and a real local server, and by Nate on the iPhone (his Mac, staging). Invite links (`invite_token`) come later |
| The chat list: friends and groups, newest first, previews decrypted | Nate | Done | 2026-10-29 (#13): friends and groups together, favorites on top, hidden chats left out, pull to refresh; every preview in the web app's words, decrypted on the phone. Seen by Nate on the iPhone against staging. Not yet: the hidden chats' section, muting and favoriting from the list, typing and "active now", profile pictures |
| A chat: texts of every format, newest 50 then paging back, replies shown | Nate | Done | 2026-10-29: tapping a chat opens it; older pages load as you scroll up, keeping your place; texts with their newest edit and the message they reply to, decrypted reactions, pics and videos in words, group events, "Update napsack to read this" for an unknown format; the group notice; opening it marks it read. Tested with the vectors' keys, a stand-in server (paging), and a real local server (55 texts paged, a group's history, read). Not yet: opening pics and videos (milestone 3), all of an edit's versions |
| Friends' keys pinned; a warning and the safety code when one changes | Nate | Done | 2026-10-29: each friend's and group member's key is pinned on first sight, kept in the Keychain per account (and kept on sign-out, as the web's are). When the server hands out a different key: the chat list says "Safety code changed", the chat shows the web's warning (an admin reset, or not), and messages are still read with the pinned key; comparing safety codes (the lock button) or accepting unchecked (two taps) trusts the new key, and the old one still opens old messages. Tested with the vectors' keys and a stand-in server swapping a key; seen on the Simulator. Sending, which the warning blocks, is next |
| Sending texts (format 2), replies, and resending safely (`client_id`) | Nate | Done | 2026-10-29: a composer in every chat, direct (format 2) and group (format 3, sealed for each member's pinned key, sealed again when the members changed: 409); a long press replies. Each text shows at once, is tried three times while the connection is the problem, always with the same `client_id` and bytes, and otherwise waits as "Not sent" with Try again and Remove (only in memory, never kept). Blocked by a changed key, a turned-off account, or Team Napsack, in the web's words. Tested against a stand-in server (Alice opens each one) and a real local server (Ana's side opens both; a resent `client_id` isn't stored twice); seen on the Simulator. Not yet: sending again by itself once back online (with live updates) |
| Live updates over the WebSocket, and catching up after a reconnect | Nate | Done | 2026-10-29: while the app is on screen it keeps a socket (closed in the background): new and changed messages appear in the open chat (and are marked read), and the chat list refetches on any change. It pings every 25 seconds and starts over without an answer in 10, reconnects after a drop (1 second, doubling to 30), shows "Reconnecting…" after 4 seconds down, and on every `ready` catches the list and the open chat up from the API and sends any text that failed for the connection's sake. A session ended elsewhere signs out. Tested with a stand-in (arrivals, catching up across a gap, resending) and a real local server (a text arriving over the socket); seen on the Simulator. Not yet: typing, "active now", read receipts on texts, the announcement |
| Reactions and edits | – | Up next | |

## 3. Pics and videos

| Task | Who | Status | Notes |
|---|---|---|---|
| The camera with AVFoundation: photos, holding to record video, zoom, the front camera mirrored | – | Planned | Same size limits as the web app ([F20](plan.md#f20-better-video-quality) for video quality) |
| Sending and opening pics and videos (formats 6 and 7), view-once, captions and where they sit | – | Planned | |

## 4. Notifications

| Task | Who | Status | Notes |
|---|---|---|---|
| APNs: the server's `push.rs` learns to deliver to iPhones beside Web Push; the app registers | – | Waiting | Needs the Apple Developer Program. A server change, so it ships first. Notifications say who, never what |

## 5. Into people's hands

| Task | Who | Status | Notes |
|---|---|---|---|
| The Apple Developer Program | Nate | Waiting | Applied; needed for TestFlight, the App Store, and notifications |
| Which server address the app uses, for good (a stable `api.` name, or a lookup) | Nate | Needs decision | Installed apps keep it for months ([mobile.md](../design/mobile.md), Decisions still open) |
| The oldest iOS supported (17 today, in `Config/Base.xcconfig`) | Nate | Needs decision | |
| Export compliance: the encryption declaration at the first upload | Nate | Needs decision | A legal declaration; Nate's to make |
| Development-only pieces out of release builds: the development screens, and the vectors copied into the app (today the whole `tests/vectors/` folder, its Python scripts included) | – | Planned | Before the first TestFlight build |
| TestFlight: internal first, then friends by public link (needs a reviewer account on production) | – | Planned | [mobile.md](../design/mobile.md), TestFlight. Release docs get written with it |
| The App Store | – | Planned | |
| Retire `mobile/` (the Expo prototype) | – | Up next | Every vector passes in `ios/` now, the condition for removing it |
| Turn on the iOS CI (`.github/workflows/ios.yml`) | Nate | Done | 2026-10-29 (#16): the crypto package's tests and the app's on a Simulator, on GitHub's macOS runners (Xcode 26.6 there), for changes to `ios/`, the vectors, or the shared crypto |
