# Android plan

Everything we're doing to bring napsack to Android as a native client, in order. It's the task list behind the Android app's entry in [plan.md](plan.md) ([F29](plan.md#f29-android-app)), whose rules and conventions apply here too (Who is a person's name; new ideas get written down before they're built). The stack, the layout, and the order are in [android.md](../design/android.md); setting up and building are in [android-onboarding.md](../android-onboarding.md). The iPhone app took this path first ([plan-ios.md](plan-ios.md)): each row names the iOS work it mirrors, which is where to look for how it was done and what was decided.

Status: **Done** · **In progress** · **Up next** · **Planned** · **Needs decision** · **Waiting** (on something outside our hands). Work top to bottom.

## 1. The shell

The project, one development screen, format 1 against the vectors, and the test loop.

| Task | Who | Status | Notes |
|---|---|---|---|
| The project: Gradle (Kotlin DSL, a version catalog, the wrapper), `:crypto` and `:app`, settings in the build files, docs | Nate | In progress | 2026-11-05: built, waiting on its pull request. AGP 9.5.0, Kotlin 2.4.21, Gradle 9.8.2, Compose BOM 2026.09.00, JDK 21; compile and target API 37, minimum 29. [android-onboarding.md](../android-onboarding.md). Mirrors iOS section 1, "The project" (#7) |
| Format 1 in Kotlin: the password's keys, the identity, chat keys, texts and pics | Nate | In progress | 2026-11-05: `crypto/` over the Java crypto APIs; 13 of `vector-checks.js`'s checks, under its names and in its order, all passing on the JVM. Mirrors iOS section 1, "Format 1 in Swift" (#7) |
| The development screen: a server's `/api/config` with `X-Napsack-Client: android/<version>+<build>`, the minimum-version check, the key derivation timed on the device | Nate | In progress | 2026-11-05: debug builds start on `http://10.0.2.2:8080` (the emulator's name for this computer), release on `https://api.napsack.io`; plain http only to this computer, only in debug, with the local network permission Android 17 needs for it (debug only, asked on the first Check). Nothing backed up. PBKDF2 takes about 2.6 s on the emulator (the JVM: about 0.12 s; the iPhone 16 Pro: 492 ms). Mirrors the iOS shell's `ServerScreen` (#7) |
| `make android`: the JVM tests, a release build's checks, the emulator tests live against a fresh server; `android.yml` by hand only; `ci.yml` skips `android/`-only changes | Nate | In progress | 2026-11-05: `scripts/test-android.sh`. Mirrors `make ios` and ios.yml (Nate, 2026-11-03: billed minutes) |

## 2. The encryption, in Kotlin

Every format producing exactly the web client's bytes, before anything leans on it.

| Task | Who | Status | Notes |
|---|---|---|---|
| Every other format: recovery keys, safety codes, format 2 texts (replies), reactions, edits, format 2 pics, format 3 groups, formats 4 to 7 (videos, photos), passkeys | – | Up next | Mirrors iOS section 1, "Every other format" (`NapsackCryptoChecks`). `VectorTest.sameChecksAsJavaScript` then compares with all of `vector-checks.js` |
| The checks on the emulator and a phone (Android's crypto provider isn't the desktop JDK's), and how long the key derivation takes there | – | Planned | The emulator took about 2.6 s for 600,000 rounds (2026-11-05), against a bar of near a second: measure a phone, and if it's slow too, try PBKDF2 over Android's native `HmacSHA256` instead of its `SecretKeyFactory`, checked by the same vectors. Mirrors iOS section 1, "The checks on the iPhone itself" (and the Admins' `VectorScreen`). Needs `VectorChecks` where `androidTest` can use it, and the vectors as test assets (never in a release build) |
| A key made on Android opens on the web and the iPhone, and back | – | Planned | Mirrors iOS section 1's cross-check. Watch: the JDK writes PKCS#8 for EC keys without the public key, which WebCrypto exports with it; check every browser imports Android's (or write it with the public key) |

## 3. Signing in, and the basics

| Task | Who | Status | Notes |
|---|---|---|---|
| Sign in: keys from the password, the private key kept encrypted by a Keystore key (this device only, usable while unlocked), the session token too | – | Planned | Mirrors iOS section 2, "Sign in" (#11). [android.md](../design/android.md#keys-on-the-phone) |
| The API client: `X-Napsack-Client` on everything, signed out on 401, an update screen on 426 or when `/api/config` needs a newer app | – | Planned | Mirrors iOS section 2, "The API client" |
| Sign up: invite code, a new identity, the recovery key shown once | – | Planned | Mirrors iOS section 2, "Sign up" (#12) |
| Signing out leaves nothing: the account, the chats in memory, the cache, the notification token | – | Planned | Mirrors iOS section 3, "Signing out leaves nothing" |
| Developer tools for Admins only; choosing a server moves there | – | Planned | Mirrors iOS section 3, "Developer tools for Admins only" (#22) |
| Client logs to the log viewer (`POST /api/logs`, "android app") | – | Planned | Mirrors iOS section 3, "Client logs" (`Reporter`) |

## 4. The chat list and chats

| Task | Who | Status | Notes |
|---|---|---|---|
| The chat list: friends and groups, newest first, previews decrypted | – | Planned | Mirrors iOS section 2, "The chat list" (#13), and section 7 |
| A chat: texts of every format, paging back, replies, the newest edit, reactions | – | Planned | Mirrors iOS section 2, "A chat", and section 8 |
| Friends' keys pinned; a warning and the safety code when one changes | – | Planned | Mirrors iOS section 2, "Friends' keys pinned" |
| Sending texts (format 2, format 3 in groups), replies, resending safely (`client_id`), one outbox | – | Planned | Mirrors iOS section 2, "Sending texts", and section 3, "One outbox" |
| Nothing sent waits on the network: texts, pics, edits, reactions shown at once; not sent after a deadline (15 seconds a text), kept, Try again | – | Planned | Mirrors the iPhone ([X57](plan.md#x57-nothing-sent-waits-on-the-network)) |
| Live updates over the WebSocket (OkHttp), catching up after a reconnect | – | Planned | Mirrors iOS section 2, "Live updates" |
| Reactions and edits; typing, "Seen" | – | Planned | Mirrors iOS section 2, "Reactions and edits", and section 8 |
| Keeping chats on the phone, encrypted, for an instant list and offline | – | Planned | Mirrors iOS section 3, "Keeping chats on the phone" (`ResponseCache`) |
| Texts of only emoji (one to four) large, without a bubble | – | Planned | Mirrors iOS section 8 ([X53](plan.md#x53-texts-of-only-emoji-large-and-without-a-bubble)) |

## 5. Pics and videos

| Task | Who | Status | Notes |
|---|---|---|---|
| The camera with CameraX: photos, holding to record video, zoom, flip, the front camera first | – | Planned | Mirrors iOS section 10, "The camera with AVFoundation", "Zoom", "The front camera first". Wants a real phone |
| Review in place, captions anywhere, drawing | – | Planned | Mirrors iOS section 10, "Review in place", "Drawing and stickers" ([ios-drawing.md](../implementation/ios-drawing.md)); what's on screen is what's sent, and the caption's one look ([pic-framing.md](../implementation/pic-framing.md), X52, X54) |
| Opening a pic: filling the screen when that cuts off little, zooming out to the whole of it | – | Planned | Mirrors the iPhone ([X56](plan.md#x56-pics-open-filling-the-screen); pic-framing.md, Opening it) |
| Send to… several friends and groups at once | – | Planned | Mirrors iOS section 10, "Sending a pic or video to several" |
| Opening pics and videos once (formats 2, 4, 6, 7 and groups'), back to back, then gone; zoom and pan | – | Planned | Mirrors iOS section 10, "Opening pics and videos once", "Zoom and pan" |
| A video sent to you plays out loud, other sound lowered meanwhile; a video without sound because the microphone's off offers it | – | Planned | Mirrors the iPhone ([D25](plan.md#d25-some-videos-arrive-with-no-sound)) |
| Video encoded as the other apps send it (H.264/AAC MP4, Media3 Transformer) | – | Planned | Mirrors iOS section 10, "Video at 720p" ([video-quality.md](../design/video-quality.md)) |

## 6. Friends, profiles, groups, and your account

| Task | Who | Status | Notes |
|---|---|---|---|
| Friends: requests, add by username, the QR code and link, scanning, unfriend, the friend map | – | Planned | Mirrors iOS section 5 |
| Profiles: pictures, your profile, a friend's profile | – | Planned | Mirrors iOS section 6 |
| Groups: create, info, members, the privacy notice | – | Planned | Mirrors iOS section 9 |
| Your account: settings, the recovery key, change password, forgot password, change username, devices | – | Planned | Mirrors iOS section 4 |
| Report and block | – | Planned | Mirrors iOS section 12, "Report and block" ([F28](plan.md#f28-report-and-block), [report-and-block.md](../design/report-and-block.md)) |
| Deleting your account from inside the app (Google Play requires it) | – | Planned | Mirrors iOS section 12, "Deleting an account" ([account-deletion.md](../design/account-deletion.md)) |

## 7. Notifications, links, passkeys

| Task | Who | Status | Notes |
|---|---|---|---|
| Notifications through Firebase Cloud Messaging: the server learns to send them (who, never what), the app registers | – | Waiting | On a Firebase project and its key in settings (Nate's, [android.md](../design/android.md#notifications)). Mirrors iOS section 11, "APNs" |
| Opening a notification goes to its chat; the badge | – | Planned | Mirrors iOS section 11 |
| Opening a napsack link (`/i/<token>`) opens the app: `/.well-known/assetlinks.json` from the server | – | Planned | Needs the signing key's fingerprint. Mirrors iOS section 5, "Opening a napsack link" |
| Passkeys with Credential Manager and the PRF extension | – | Planned | Mirrors iOS section 4, "Passkeys" ([passkeys.md](../design/passkeys.md)) |

## 8. Into people's hands

| Task | Who | Status | Notes |
|---|---|---|---|
| The package name `com.getattr.napsack`, confirmed before the first upload (permanent once on Google Play) | Nate | Needs decision | [android.md](../design/android.md#decisions-for-nate). Built with it |
| The Google Play Console ($25, once) | Nate | Waiting | Not needed until there's something to hand out. Mirrors iOS section 12, "The Apple Developer Program" |
| Signing: an upload key, Play App Signing, version codes that go up with every upload | – | Planned | Mirrors iOS section 12, "Signing with the Program team" |
| Development-only pieces out of release builds | – | Planned | Started: plain http only in debug, checked by `make android`. Mirrors iOS section 12, "Development-only pieces out of release builds" |
| Internal testing (up to 100 people, no review) | – | Planned | Mirrors iOS section 12, "TestFlight, internal" |
| The store listing, the data safety form, the content rating, screenshots | – | Planned | Mirrors iOS section 12, "A privacy policy and a support page" |
| Turn on the Android CI on changes to `android/` (the JVM tests on Linux are cheap) | – | Planned | Nate's call (billed minutes); `android.yml` runs by hand until then |
