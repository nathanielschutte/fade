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
| Sending texts (format 2), replies, and resending safely (`client_id`) | Nate | Done | 2026-10-29: a composer in every chat, direct (format 2) and group (format 3, sealed for each member's pinned key, sealed again when the members changed: 409); a long press replies. Each text shows at once, is tried three times while the connection is the problem, always with the same `client_id` and bytes, and otherwise waits as "Not sent" with Try again and Remove (only in memory, never kept). Blocked by a changed key, a turned-off account, or Team Napsack, in the web's words. Tested against a stand-in server (Alice opens each one) and a real local server (Ana's side opens both; a resent `client_id` isn't stored twice); seen on the Simulator. Since live updates, texts that failed offline go again by themselves on reconnect. A text that wasn't sent now outlives its chat (section 3) |
| Live updates over the WebSocket, and catching up after a reconnect | Nate | Done | 2026-10-29: while the app is on screen it keeps a socket (closed in the background): new and changed messages appear in the open chat (and are marked read), and the chat list refetches on any change. It pings every 25 seconds and starts over without an answer in 10, reconnects after a drop (1 second, doubling to 30), shows "Reconnecting…" after 4 seconds down, and on every `ready` catches the list and the open chat up from the API and sends any text that failed for the connection's sake. A session ended elsewhere signs out. Tested with a stand-in (arrivals, catching up across a gap, resending) and a real local server (a text arriving over the socket); seen on the Simulator. Not yet: typing, "active now", read receipts on texts, the announcement |
| Reactions and edits | Nate | Done | 2026-10-29: holding a message lifts it over the dimmed chat with one row of reactions above it at about the size of the text (scrolling sideways when they don't fit; the same again takes it back, with a haptic) and the actions below:, replies, copies, or edits your own text for 15 minutes (encrypted group texts only, as on the web). Direct reactions are encrypted to the pinned key; group reactions are the emoji, which the server can see (as on the web). An edit is sealed with the edit's associated data, in a group for the text's own member list, and tried again with the same `client_id`; a failed edit goes back in the box. Tested against a stand-in (Alice opens each one) and a real local server (edits and reactions, taken back, seen from Ana's side); seen on the Simulator. Not yet: tapping a reaction to add the same, all of an edit's versions, typing |

## 3. Safety and housekeeping

What the web app does quietly that the app must do too, before more features lean on it.

| Task | Who | Status | Notes |
|---|---|---|---|
| Developer tools for Admins only; choosing a server moves there | Nate | Done | 2026-10-29 (#22): `role` from `/api/me`; sign-in has no server field unless an Admin pointed the phone elsewhere ([roles.md](../implementation/roles.md)) |
| Client logs: what goes wrong on the phone reaches the log viewer (`POST /api/logs`, "ios app") | Nate | Done | 2026-10-29: `Reporter`, as the web's `report()`: batched (50 a request), errors within half a second, everything when the app leaves the screen; ids, statuses, and error wording only. Reports sign-in failures, sends, loading, key changes, the socket, and messages that couldn't be opened (how many). A live test reads it back from the log viewer as an Admin |
| Signing out leaves nothing: the account, every chat in memory, and later the cache, the notification token, and delivered notifications | Nate | Done | 2026-10-29: the Keychain account goes; the signed-in screens (chats, socket, open chats) are tied to the session and go with it; requests use an ephemeral connection with no cache or cookies, so the system never writes them down; reports stop going as the account. Pins stay. `signingOutLeavesNothingOfTheAccount`. When the cache and notifications come, they join it |
| One outbox for the whole app: a "Not sent" text survives leaving its chat | Nate | Done | 2026-10-29: every chat opened in a session is kept (only in memory, gone with the session), so its unsent texts keep trying after you leave, all of them go again on reconnect, and reopening a chat is instant (it catches up instead of reloading) |
| The System pages (Metrics, Logs, Users, ...) for PowerUsers and Admins | Nate | Needs decision | Native screens, or the web's `/admin` in the app (it would need signing in there too). Until then, a browser |
| Keeping chats on the phone, encrypted, so the list and each chat's newest page show at once and offline | – | Planned | The web's `cache.js`. Native: a file with complete file protection (readable only while unlocked), wiped at sign-out |

## 4. Your account

| Task | Who | Status | Notes |
|---|---|---|---|
| Settings: your account, its safety, and signing out, as one screen | Nate | Done | 2026-10-29: the person button on the chat list opens Settings (a `Form`): username, server, security, Developer for Admins, Sign out, in the web's Security panel's words |
| The recovery key: a reminder if you have none, and setting one later | Nate | Done | 2026-10-29: the chat list says so, in the web's words, until there's one (Set up asks for the password); Settings makes or replaces one; shown once either way |
| Change password (unlock first) | Nate | Done | 2026-10-29: Settings; the key is unlocked and locked again on the phone; other devices are signed out. AutoFill's new-password suggestion works on the fields |
| Forgot password: the recovery key or an admin's reset code | – | Planned | `/auth/recover/start`, `/auth/recover/finish`, `/auth/reset` |
| Change your username (once a week) | Nate | Done | 2026-10-29: Settings; the key is locked again under the new name (the salt); the server's own words when it's too soon or taken |
| Account security: when the recovery key was set, devices signed in, sign out every other device | Nate | Done | 2026-10-29: Settings. `LiveAccountTests` proves each against a real server by signing in again afterwards |
| Lock napsack with Face ID | Nate | Needs decision | Native, and not on the web: an optional lock when the app opens. Nate's call whether we want it |

## 5. Friends

| Task | Who | Status | Notes |
|---|---|---|---|
| Friend requests: incoming, outgoing, accept, decline, cancel; a badge for new ones | Nate | Done | 2026-10-30: the Friends screen (the person-pair button on the chat list, with a badge for requests waiting on you, kept current live) |
| Add by username | Nate | Done | 2026-10-30: in the web's words, an old username included ("(was @…)") |
| Your QR code and link: show, share, reset | Nate | Done | 2026-10-30: the QR drawn on the phone (CoreImage), the share sheet (`ShareLink`), Copy, and Reset with a confirmation. The link uses the server's address; once apps talk to `api.napsack.io`, links must use the site's ([api-host.md](../design/api-host.md)) |
| Scan a friend's QR with the camera | – | Planned | Native: VisionKit's `DataScannerViewController` |
| One-time invite links: make, list who joined, revoke | Nate | Done | 2026-10-30: made with its QR and share sheet, listed with who joined, turned off |
| Opening a napsack link (`/i/<token>`) opens the app | – | Waiting | Universal Links need Associated Domains, a Developer Program capability. Until then, links open in Safari |
| Unfriend | Nate | Done | 2026-10-30: from their profile, confirmed; history stays (Rule 1) |
| The friend map | – | Planned | `GET /graph`. Native: a SwiftUI `Canvas`, pinch and drag |

## 6. Profiles

| Task | Who | Status | Notes |
|---|---|---|---|
| Profile pictures in the list, the chat header, and profiles; tap to see it big | Nate | In progress | 2026-10-30: friends' and groups' pictures in the list, the chat header, and profiles, fetched once each and kept in memory for the session only. Not yet: tapping to see one big |
| Your profile: display name, picture, birthday | Nate | Done | 2026-10-30: at the top of Settings. A picture from `PhotosPicker` (no access to the whole library), squared to 512 and under 128 KB on the phone (the server cleans it again); the name; the birthday, the year optional. Says they aren't end-to-end encrypted |
| A friend's profile: nickname, streak, friends in common, past usernames, safety code | Nate | Done | 2026-10-30: tap the chat's title (with their picture): name, @username and past usernames, a nickname only you see, friends since, birthday, streak, texts and pics together, friends in common, safety code, and Unfriend (confirmed; the chat stays) |

## 7. The chat list, native

| Task | Who | Status | Notes |
|---|---|---|---|
| Swipe actions: hide, mute, favorite; leave a group | Nate | Done | 2026-10-30: swipe right to favorite, left to hide (or leave a group, confirmed) and mute (8 hours, a week, or until turned back on); the same in a long-press menu; Undo for hiding and muting, in the web's words |
| Hidden chats: their own section, and undo | Nate | Done | 2026-10-30: "Hidden chats (n)" at the end of the list, Unhide by swiping |
| Search chat names and recent messages | Nate | In progress | 2026-10-30: `.searchable`, by name and newest message. The web also searches each chat's newest 200 messages; that waits for the encrypted cache (section 3) |
| Streaks 🔥 and birthdays 🎂 beside names | – | Planned | From `/api/friends` |
| The Admins' announcement, dismissible | – | Planned | `GET /announcement`, the `announcement` event |
| Pull down to refresh; a new friend or message animates in | Nate | Done | Pull to refresh since #13; live since #19 |

## 8. Chats, native

| Task | Who | Status | Notes |
|---|---|---|---|
| Typing… and "Active now" (with the setting to share it) | Nate | Done | 2026-10-30: "Ana is typing…" above the composer (gone 4 seconds after the last word, or when the message comes; sent at most every 2 seconds), "Active now" or "Active 5m ago" under the friend's name, and "Share when I'm active" in Settings (mutual) |
| "Seen" on your texts, "Seen by" in groups | Nate | In progress | 2026-10-30: "Seen" under your newest direct text once read, live. "Seen by" in groups isn't yet |
| Every version of an edited text | – | Planned | `GET .../edits` |
| Tapping a reaction under a message adds yours | Nate | Done | 2026-10-30: reactions under a message are counted and tappable; yours is marked, and tapping it takes it back |
| Holding a message: one row of reactions at text size, actions below | Nate | Done | 2026-10-29 (#21), after Nate tried the system menu on his phone |
| Swipe a message to reply | Nate | Done | 2026-10-30: swipe right past a threshold (a haptic tap), sideways only so scrolling stays scrolling |
| Haptics where they help: sending, reacting, a new message in the open chat | Nate | In progress | 2026-10-30: holding a message, swiping to reply, sending, and reacting. Not yet: a new message in the open chat |
| Accessibility pass: Dynamic Type, VoiceOver labels, Reduce Motion | – | Planned | Before TestFlight |

## 9. Groups

| Task | Who | Status | Notes |
|---|---|---|---|
| Create a group: a name and friends | Nate | Done | 2026-10-30: the compose button on the chat list: a name (up to 40) and friends, the privacy note, then straight into the new group |
| Group info: rename, picture, members (add, remove, leave), the privacy notice | Nate | Done | 2026-10-30: tap the group's title: the notice in the web's words, its picture (`PhotosPicker`, made small here, cleaned by the server), rename (any member), members (the owner removes by swiping; who can, said plainly), add friends, Leave (confirmed) |

## 10. Pics and videos

| Task | Who | Status | Notes |
|---|---|---|---|
| The camera with AVFoundation: photos, holding to record video, zoom, flip (while recording too), mute, the front camera mirrored | – | Planned | Same size limits as the web app ([F20](plan.md#f20-better-video-quality) for video quality). Native: a full-screen camera, pinch to zoom |
| Opening pics and videos once (formats 2, 4, 6, 7 and groups'), back to back, then gone | – | Planned | `GET /snaps/{id}`, `POST /snaps/{id}/opened`; nothing saved to the phone, and screenshots can't be stopped (say so where the web does) |
| Sending a pic or video to several friends and groups at once, with a caption placed anywhere | – | Planned | `/chats/{id}/snaps`, `/groups/{id}/pics` with `X-Napsack-Keys` |
| Drawing and stickers on a pic | – | Planned | Native: PencilKit |
| Picking a photo from the library | – | Planned | Native: `PhotosPicker`, no full library access needed |
| Double-tap a chat in the list to open the camera for it | – | Planned | As on the web |

## 11. Notifications

| Task | Who | Status | Notes |
|---|---|---|---|
| APNs: the server's `push.rs` learns to deliver to iPhones beside Web Push; the app registers | – | Waiting | Needs the Apple Developer Program. A server change, so it ships first. Notifications say who, never what |
| Opening a notification goes to that chat and marks it read; notifications clear when the app opens | – | Waiting | Same as the web ([X36](plan.md#x36-opening-a-notification-goes-there-and-reads-it)) |
| The app's badge: unread chats | – | Waiting | |

## 12. Into people's hands

| Task | Who | Status | Notes |
|---|---|---|---|
| The Apple Developer Program | Nate | Waiting | Applied; needed for TestFlight, the App Store, and notifications |
| Release builds talk to `https://api.napsack.io` | – | Waiting | Decided (Nate, 2026-10-29): a name only for the apps, so the site can move freely ([api-host.md](../design/api-host.md)). Waits on the DNS and Caddy change, which replaces the instance (Nate's to apply; plan.md [I10](plan.md#i10-apinapsackio-a-stable-address-for-the-apps)) |
| The oldest iOS supported (17 today, in `Config/Base.xcconfig`) | Nate | Needs decision | |
| Export compliance: the encryption declaration at the first upload | Nate | Needs decision | A legal declaration; Nate's to make |
| Development-only pieces out of release builds: the development screens, and the vectors copied into the app (today the whole `tests/vectors/` folder, its Python scripts included) | – | Planned | Before the first TestFlight build |
| TestFlight: internal first, then friends by public link (needs a reviewer account on production) | – | Planned | [mobile.md](../design/mobile.md), TestFlight. Release docs get written with it |
| The App Store | – | Planned | |
| Retire `mobile/` (the Expo prototype) | – | Up next | Every vector passes in `ios/` now, the condition for removing it |
| Turn on the iOS CI (`.github/workflows/ios.yml`) | Nate | Done | 2026-10-29 (#16): the crypto package's tests and the app's on a Simulator, on GitHub's macOS runners (Xcode 26.6 there), for changes to `ios/`, the vectors, or the shared crypto |
