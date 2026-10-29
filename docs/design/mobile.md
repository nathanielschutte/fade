# The iOS app (and Android later)

The plan for napsack's native apps: what they're built with, how they keep the encryption identical to the web client's, and how they're developed, versioned, and released. Release rules that apply to every client are in [releasing.md](../operations/releasing.md).

## Stack: native Swift, then Kotlin

**Decision (Nate, 2026-10-29):** the iOS app is native **Swift** (SwiftUI), built in Xcode. A later Android app will be native **Kotlin**, its own port. This replaces the earlier plan (2026-10-21) to build one React Native app with Expo; that prototype only ever ran the crypto checks on a phone, so little is lost.

Why native:

- **The camera and video.** Pics, short videos, zoom, holding to record, and the microphone are the heart of napsack. AVFoundation gives full control of all of it, without the limits a web view or a cross-platform layer puts in the way.
- **A real phone layout.** The installed web app has kept running into Safari's Home Screen quirks (the bottom bar's position, permissions asked again on every launch). A native app has none of them.
- **The platform, directly.** The Keychain for keys, APNs for notifications, background behavior, and the share sheet, each used as Apple documents it.
- **It closes a gap.** A web app's code comes from the server on every load, so a compromised server could ship code that leaks keys ([how-napsack-works.md](../how-napsack-works.md#limits)). An app's code is signed and reviewed before it's installed.

The cost, and how it's handled:

- **The encryption is written again, in each language.** Today `shared/crypto/crypto.js` is the reference implementation (the web client uses it). Swift implements the same formats with CryptoKit, and Kotlin will with the Java and Android crypto APIs. The pinned test vectors in `tests/vectors/` are the contract: each port must open every vector byte for byte, as the independent Python checks already do. A port that disagrees with a vector is wrong, never the vector.
- **iOS work needs a Mac with Xcode.** The web and server work doesn't.

## How it fits the repo

```
server/            Rust server; also serves the web client
shared/crypto/     crypto.js: the reference implementation (web), and vector-checks.js
tests/vectors/     the pinned vectors every implementation must reproduce exactly
ios/               the Swift app: Napsack.xcodeproj, and NapsackCrypto (the formats, a Swift package)
android/           the Kotlin app, later
mobile/            the retired Expo prototype; removed once ios/ passes every vector
```

- **Crypto in Swift.** Everything the formats use is built into iOS:

  | What | Where in iOS |
  |---|---|
  | PBKDF2-SHA256, 600,000 rounds | CommonCrypto (`CCKeyDerivationPBKDF`) |
  | HKDF-SHA256 | CryptoKit (`HKDF<SHA256>`) |
  | P-256 key agreement | CryptoKit (`P256.KeyAgreement`), keys as PKCS#8 and SPKI DER |
  | AES-256-GCM with associated data | CryptoKit (`AES.GCM`) |

  The formats to cover: texts (1, 2), pics (1, 2), videos and photos (4 to 7), group messages (3, 5, 7), edits, reactions, recovery keys, and safety codes ([how-napsack-works.md](../how-napsack-works.md)).
- **The vectors run in the app's tests.** `NapsackCrypto`'s tests (Swift Testing) read `tests/vectors/*.json` and makes every check `shared/crypto/vector-checks.js` makes. It runs on every build in CI, and on a real iPhone too, since that's where the 600,000-round PBKDF2 has to stay near a second.
- **Keys on the phone.** The unwrapped private key goes in the Keychain, readable only while the phone is unlocked (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) and never synced to iCloud or other devices. Sign-in derives keys from the password exactly as on the web, so history works on the phone from day one.
- **Version handshake.** Every request carries `X-Napsack-Client: ios/<version>+<build>`. At launch the app reads `GET /api/config`. If the server's `min_client_versions.ios` is newer than the app, it shows an update screen that links to the App Store. A message whose `format` it doesn't know shows "Update napsack to read this"; `/api/config` lists every format in use (`message_formats` for direct chats, `group_message_formats` for groups).

## Getting set up

Step by step, for someone new to Xcode: [ios-onboarding.md](../ios-onboarding.md).

- **A Mac with Xcode** (the current version, from the App Store).
- **No paid account to start.** Without one, the app runs in the iOS Simulator, and on your own iPhone through a free Apple ID: in Xcode, add your Apple ID under Settings › Accounts, and choose its "Personal Team" for signing. The catch: an app signed that way stops opening after 7 days (build it again from Xcode), and it can't use push notifications.
- **The Apple Developer Program** ($99/year) is needed for push notifications, TestFlight, and the App Store.
- On the phone: Settings › Privacy & Security › Developer Mode, on (iOS asks once for apps installed from Xcode).

The app points at a server you choose: your own (`cargo run`, reached from the phone over your network or a tunnel), staging, or production.

## Decisions still open

- **Which address the app talks to.** An installed app keeps whatever server address it was built with, and old versions stay installed for months. Since the domain will change again, the app should use an address that never changes (for example a dedicated `api.` name, or a small "where is the server" lookup), or every move needs the old domain kept forever. Decide before the first TestFlight build.
- **Export compliance.** App Store Connect asks whether the app uses encryption. It does (end-to-end, with standard algorithms), which usually qualifies for an exemption but has to be declared. Answer it at the first upload, then set `ITSAppUsesNonExemptEncryption` in the app's `Info.plist` so it isn't asked on every build. This is a legal declaration, so it's yours to make; Apple's export compliance help in App Store Connect walks through it.
- **A reviewer account for external TestFlight** (see TestFlight): one production account for Apple's reviewer, or wait on external testing.
- **The oldest iOS supported.** Newer versions mean fewer workarounds; a recent iOS (17 or later) covers nearly every iPhone in use.

## Versions, builds, and releases

| | Where | Who changes it |
|---|---|---|
| App version (`1.2.0`) | the Xcode target's Marketing Version | the owner, per release: SemVer like the server |
| Build number (`37`) | the target's Current Project Version | bumped on every upload |

Shipping:
1. **A release.** Bump the version, merge it to `main` through a pull request, and tag `ios-v1.2.0`. At first the build is archived and uploaded from Xcode (Product › Archive, then Distribute App); later a workflow on a macOS runner does the same from the tag, with an App Store Connect API key.
2. Test it on TestFlight, then submit for review in App Store Connect.

Release order always follows [releasing.md](../operations/releasing.md): server first, then the app. Raise `min_client_versions.ios` only after the newer app is out and installed.

## TestFlight

TestFlight is how early users get the app before the App Store: they install Apple's TestFlight app, tap a link, and get every new build automatically. Each build lasts 90 days. It needs the paid Developer Program.

One-time setup:
1. **The app in App Store Connect,** with the bundle id `com.getattr.napsack` (permanent). App names are unique across the whole App Store: if "napsack" is taken, the store name needs a suffix ("napsack chat"), while the name under the icon stays "napsack".
2. **An App Store Connect API key** (Users and Access › Integrations › App Store Connect API, with the **App Manager** role), once uploads move to CI. Download the `.p8` (Apple offers it once) and keep it out of the repo.
3. **Export compliance** (see Decisions still open).

Getting it to people:
- **Internal testing** (you, and anyone you add to the App Store Connect team, up to 100): no review, available minutes after processing. Start here.
- **External testing** (friends, up to 10,000, by email or a **public link**): the first build of each version goes through Beta App Review, usually about a day. It asks for a short description, a feedback email, and **sign-in details for the reviewer**, since napsack needs an account. That means one real account for Apple on production (the owner's call; CLAUDE.md says no test accounts in production without asking). Later builds of the same version usually skip review.
- Feedback: testers can screenshot and send notes from inside TestFlight; they show in App Store Connect.

## First milestones

1. **The crypto, in Swift, passing every vector.** The riskiest part goes first: a Swift package with the formats above, and tests that run every pinned vector, plus a timing check that 600,000-round PBKDF2 stays near a second on a real iPhone. Nothing ships until it's all green. Started (2026-10-29): `ios/NapsackCrypto` passes format 1's vectors, and the app's development screen times the key derivation on the phone.
2. **Skeleton.** Sign in, chat list, chat screen, sending and reading texts, against a chosen server.
3. **The camera.** Pics and short videos with AVFoundation: zoom, holding to record, the same compression and size limits as the web app, and the formats 6 and 7 envelopes with the caption's place.
4. **Notifications.** APNs: the server's `push.rs` gains APNs delivery alongside Web Push (needs the paid program). The server can't read messages, so notifications say who sent something, never what.
5. **TestFlight** for friends, then the App Store.

## Android, later

A native Kotlin app (Jetpack Compose), in `android/`. Its crypto is its own port, held to the same vectors in its own test suite: PBKDF2 and AES-GCM from `javax.crypto`, P-256 key agreement, HKDF, and keys in the Android Keystore. It follows the same version handshake (`X-Napsack-Client: android/<version>`) and release order. Not started; it waits until the iOS app is in people's hands.
