# iOS onboarding

Building the napsack iPhone app: what's in `ios/`, setting up a Mac and an iPhone the first time, the daily loop, and how the pieces work. It assumes you know napsack ([onboarding.md](onboarding.md)) but not Xcode or iOS, so it explains the Xcode words as they come up. The plan for the app (why native Swift, milestones, TestFlight, releases) is in [mobile.md](design/mobile.md).

Where things stand (2026-10-29): every encryption format is in Swift and passes the pinned vectors, on the Mac and on the phone. The app is still a development screen: it talks to a server and runs the encryption's checks on the phone. What's next is in [plan-ios.md](management/plan-ios.md).

## The pieces

```
ios/
├── Napsack.xcodeproj      the Xcode project: open this
├── Napsack/               the app's code (SwiftUI)
│   ├── NapsackApp.swift       where the app starts
│   ├── SignInScreen.swift     signing in
│   ├── ChatListScreen.swift   your chats, once signed in
│   ├── Chats.swift            the chat list's data, and what each row says
│   ├── ChatScreen.swift       an open chat
│   ├── Conversation.swift     a chat's history, page by page, as bubbles
│   ├── Live.swift             the live connection: new messages as they're sent
│   ├── Pins.swift             friends' keys as first seen, to catch one that changes
│   ├── SafetyCodeScreen.swift the code to compare, and the changed-key warning
│   ├── Session.swift          who's signed in, kept in the Keychain
│   ├── DeveloperScreen.swift  Admins only: a server's settings, the checks, which server to use
│   ├── VectorScreen.swift     the encryption's checks, run on the phone
│   ├── Server.swift           talking to a napsack server
│   └── Assets.xcassets        the icon and accent color
├── NapsackTests/          the app's unit tests
├── NapsackCrypto/         the encryption, and its checks, as a Swift package
└── Config/                build settings, as text files
```

The Xcode words, in the order you'll meet them:

- **Project** (`Napsack.xcodeproj`): what Xcode opens. It lists the targets and where their files are. You rarely edit it by hand.
- **Target**: one thing that gets built. There are two: **Napsack** (the app) and **NapsackTests** (its tests, which run inside the app).
- **Scheme**: what the Run (⌘R) and Test (⌘U) buttons do. Use the **Napsack** scheme. Xcode also shows a **NapsackCrypto** scheme for the package.
- **Destination**: where it runs, picked next to the scheme at the top of the window: a Simulator ("iPhone 17") or your own iPhone.
- **Swift package** (`NapsackCrypto/`): a library with its own `Package.swift`. The app uses it like any library (`import NapsackCrypto`). Keeping the encryption in a package means its tests run on the Mac in seconds (`swift test`), without a simulator.
- **Synchronized folders**: `Napsack/` and `NapsackTests/` are linked to their targets as folders. A file you add there, in Xcode or any editor, is part of the build. You don't add files to the project.
- **Build settings and `.xcconfig` files**: everything about how the app is built (its name, iOS version, bundle id, signing) is in `Config/*.xcconfig`, plain text that reads well in a diff. `Base.xcconfig` holds what's shared, `Debug` and `Release` the two **build configurations** (Run uses Debug, an App Store build Release), and `App` and `Tests` each target's own settings. `Local.xcconfig` holds your machine's settings and isn't in git.
- **Info.plist**: what the app tells iOS about itself (its name under the icon, permissions it asks for). Most of it is generated from `App.xcconfig` (the `INFOPLIST_KEY_...` lines); `Config/App-Info.plist` adds the rest.
- **Bundle id**: the app's permanent identity with Apple, `com.getattr.napsack`.
- **Signing and teams**: iOS runs only apps signed by a developer Apple knows. Your Apple ID is a **team**. A free Apple ID is a "Personal Team"; the paid Developer Program gives a team that can use TestFlight and the App Store.
- **SwiftUI**: how the screens are written. A screen is a `struct` that's a `View`, describing what to show in `body`. When something marked `@State` changes, SwiftUI redraws what depends on it. The **canvas** (⌥⌘↩, the `#Preview` at the bottom of a file) shows a screen live while you edit it.

## First time on a Mac

1. **Xcode**, from the Mac App Store (this was set up with Xcode 27.1). Open it once so it installs its components, and add the iOS platform if it asks. Then point the command line at it and keep the separate Command Line Tools current (System Settings › General › Software Update):
   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. **Your Apple ID in Xcode:** Xcode › Settings › Accounts, then **+** › Apple ID. Your "Personal Team" appears. Select it, click **Manage Certificates…**, then **+** › **Apple Development**. That certificate is what signs the builds you put on your phone.
3. **Your team in `Local.xcconfig`:**
   ```sh
   cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
   # your team id (10 characters), from the certificate step 2 made:
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```
   The id is the `OU=` part. Put it in `DEVELOPMENT_TEAM`. Keep the `.dev` bundle id line while you use a free Apple ID. A bundle id belongs to the first team that registers it, so the free team builds `com.getattr.napsack.dev` and leaves the real one for the Developer Program team. Don't choose a team in Xcode's Signing & Capabilities tab: Xcode writes it into the project file, which is shared. If that happens, put it in `Local.xcconfig` and undo the change to `project.pbxproj`.
4. **Open** `ios/Napsack.xcodeproj` (double-click it, or `open ios/Napsack.xcodeproj`). Xcode loads the `NapsackCrypto` package on its own.
5. **Try the Simulator:** choose the Napsack scheme and an iPhone simulator at the top, then ⌘R. The development screen opens. **Check** asks the server (staging, to start) about itself.

### Your iPhone (a 16 Pro, here)

1. Connect it with a USB-C cable and unlock it. Tap **Trust** when it asks about this computer.
2. Turn on **Developer Mode**: Settings › Privacy & Security › Developer Mode (it appears once Xcode has seen the phone). The phone restarts and asks you to confirm.
3. In Xcode, choose your iPhone as the destination and press ⌘R. The first time, Xcode prepares the phone, which takes a few minutes.
4. If the phone says **Untrusted Developer**: Settings › General › VPN & Device Management, choose your Apple ID, then **Trust**.
5. After that it also works without the cable, on the same Wi-Fi (Window › Devices and Simulators shows it as connected over the network).

A free team's builds stop opening after **7 days**; run it from Xcode again. Push notifications and TestFlight wait for the paid Developer Program ([mobile.md](design/mobile.md)).

## The daily loop

- **Run** ⌘R, **stop** ⌘., **test** ⌘U. Test results show in the Test navigator (⌘6). A test's line in the editor gets a diamond you can click to run just that test.
- **The canvas** (⌥⌘↩) shows the screen you're editing; fine for layout. Run it on the phone to see it for real.
- **The encryption's tests**, on the Mac in a couple of seconds, from the repository root:
  ```sh
  swift test --package-path ios/NapsackCrypto
  ```
- **Everything the way CI will**, on a simulator (no signing needed):
  ```sh
  xcodebuild test -project ios/Napsack.xcodeproj -scheme Napsack -destination 'platform=iOS Simulator,name=iPhone 17'
  ```
  `xcrun simctl list devices available` lists the simulators there are.
- **Logs:** the app's `print` output and crashes show in Xcode's console (⇧⌘C) while it runs from Xcode.
- **The live tests** sign up, in, and out against a real server, so they run only when told where, and only against your own (they make an account). With the server running (`cd server && FADE_INVITE_CODE=letmein cargo run`):
  ```sh
  TEST_RUNNER_NAPSACK_TEST_SERVER=http://127.0.0.1:8080 xcodebuild test -project ios/Napsack.xcodeproj -scheme Napsack \
    -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:NapsackTests/LiveSignInTests
  ```
  `xcodebuild` hands the tests any variable that starts with `TEST_RUNNER_`, without the prefix. Otherwise they show as skipped. One live test reads the log viewer back, which needs an Admin: run the server with `FADE_ADMINS=nate` and add `TEST_RUNNER_NAPSACK_TEST_ADMIN=nate`.

### Pointing the app at your own server

The app starts on staging (`NAPSACK_SERVER_URL`, `Config/Base.xcconfig`); yours starts wherever your `Local.xcconfig` says (below). Only Admins can point it anywhere else: sign in as an Admin, then account menu › **Developer** › Server, type the address, and sign out; the next sign-in goes there. Sign-in then shows which server it's using, with **Use napsack's server** to go back. (Admins are `FADE_ADMINS` on a local server, so run it with `FADE_ADMINS=nate` or your own username.)

- **Simulator:** run the server (`cd server && FADE_ADMINS=nate cargo run`), then use `http://127.0.0.1:8080`. The simulator shares the Mac's network.
- **iPhone:** the server has to listen beyond the Mac itself, and the phone has to be on the same network. Find the Mac's name with `scutil --get LocalHostName`, then:
  ```sh
  cd server && FADE_BIND=0.0.0.0:8080 FADE_ADMINS=nate cargo run
  ```
  In the app, use `http://<that name>.local:8080`. iOS asks once to allow napsack on the local network; if you said no, turn it on in Settings › Privacy & Security › Local Network. Plain `http` is allowed only for the local network (`NSAllowsLocalNetworking` in `App-Info.plist`); anything else has to be `https`.
- **An account to sign in with:** make one on that server in a browser (`http://127.0.0.1:8080`, the invite code is `FADE_INVITE_CODE`; `cargo run` sets none, so no code is asked), then sign in with it in the app. Staging works the same way. On production, your real account works too, but a phone counts as one of your 4 signed-in devices, and the oldest is signed out to make room.
- To start fresh installs somewhere else, set `NAPSACK_SERVER_URL` in your `Local.xcconfig`, never in `Base.xcconfig` (that one's shared). The `$()` in `https:/$()/` keeps an xcconfig from reading `//` as a comment.

## How it works

- **`NapsackApp.swift`** is where the app starts (`@main`). It makes the `Session` and shows the sign-in screen or the home screen, depending on whether someone's signed in.
- **`Session.swift`** is who's signed in. Signing in works as the web app's does: the password is turned into keys on the phone (600,000 rounds of PBKDF2, about half a second on an iPhone 16 Pro), only the auth key goes to the server (`POST /api/auth/login`), and the private key comes back wrapped, which only the password unwraps. What's kept is one `Account` (the server, the session token, who you are, and the private key), saved as one Keychain item. At launch the app goes straight in with it, then asks the server (`GET /api/me`); if the session was ended (signed out elsewhere, turned off), it signs out and says so. No connection keeps you in. Signing out ends the session on the server and removes the item.
- **`Keychain.swift`** keeps secrets in the iPhone's Keychain, readable only while the phone is unlocked and only on this phone: never synced to your other devices, never moved by a backup (`WhenUnlockedThisDeviceOnly`). The password is never kept anywhere.
- **Signing up** (`Session.signUp`) also works as the web app's does: keys from the password, a new key pair made on the phone (the private key goes to the server only wrapped), then a recovery key, registered with the server and shown once (`RecoveryKeyScreen.swift`) until you say it's saved. The invite code is asked for only when the server's `/api/config` says it needs one.
- **`UpdateScreen.swift`** is all that shows when the server needs a newer app: when `/api/config` says so at launch, or any request is answered 426. Development builds have a way back to pick another server.
- **`Chats.swift`** is the chat list's data (`GET /api/friends` and `GET /api/groups`, loaded together) and what each row says about its newest message, in the web app's words (`app.js`, `chatStatus` and `groupStatus`): a text decrypted with the friend's pair key (its newest edit if it has one), a group text opened with your own wrap of its key, "New pic", "Sent a video", "Ana added you", or "Encrypted message" for what can't be opened. The rules live in `Reader`, plain functions that `ChatListTests` checks one by one with the vectors' keys; the rows are worked out off the main thread.
- **`Conversation.swift`** is an open chat: its history from `GET /api/chats/{friend}/messages` or `/api/groups/{id}/messages`, the newest 50 first, then 50 older at a time as you scroll up (`?before=`), each message made a `Bubble` by `Reader` (the same decryption as the list's previews, plus replies, edits, and reactions). **`ChatScreen.swift`** draws it: yours on the right, day headers, a reply's quote, the time under the last of each run, the group's encryption notice, and "This is the beginning…" where the history stops. Opening a chat marks it read. You write at the bottom. A long press on a message reacts to it, replies, copies it, or (your own text, for 15 minutes) edits it. A sent text waits in the conversation's outbox until the server has it: it's sealed once and sent with a `client_id`, so trying again after a dropped connection never stores it twice, and one that still can't go says "Not sent" with Try again.
- **`Live.swift`** is the live connection while the app is on screen: a WebSocket to `/api/ws` that signs in with its first frame. The server says what changed (a new message, a friend added); the open chat takes its own messages and the chat list fetches again. The API is the truth: after any drop the app reconnects, and on the server's `ready` it fetches what's shown again, so nothing missed while disconnected is lost. When the app goes off screen, the connection closes.
- **`Reporter.swift`** sends what goes wrong on the phone to the server's log viewer (`/admin#logs`, source "ios app"), batched like the web app's `report()`. Only ids, counts, statuses, and error wording go: never message content, keys, or tokens. Call `Reporter.shared.report(.warn, "what happened", ["friend_id": "7"])`.
- **`Pins.swift`** keeps each friend's and group member's public key as the phone first saw it (in the Keychain, per account). If the server later hands out a different key, which only an admin reset should cause, the app keeps reading with the pinned key, the chat list says "Safety code changed", and the chat shows a warning (**`SafetyCodeScreen.swift`**) until you compare safety codes or accept the new key. A key the server swapped in would let it read the chat, so the app never trusts one silently. Accepted keys stay as past keys, which still open the messages they sealed. The web app does the same (`app.js`, `checkPins`).
- **`SignInScreen.swift`** (signing in, or creating an account) and **`ChatListScreen.swift`** (friends and groups together, newest first, favorites on top, pull to refresh; your account, Sign out, and for Admins Developer, in the menu at the top right) are the main screens so far; **`DeveloperScreen.swift`** (Admins only, as the account's `role` says) checks a server's settings, opens the encryption's checks, and picks the server the next sign-in uses.
- **`Server.swift`** talks to a napsack server. Every request says which app is asking (`X-Napsack-Client: ios/0.1.0+1`), so a server can turn away an app older than it supports (426, whose message the app shows). Errors are the server's own words (`{"error": "..."}`), or the web app's ("Can't reach the server. Check your connection."). Requests go through a `Transport`, the network in the app and a stand-in in tests (`SessionTests`). `ServerConfig` is `GET /api/config` ([api.md](spec/api.md)). `ClientVersion` compares versions the way the server does (`server/src/version.rs`).
- **`VectorScreen.swift`** runs every encryption check on the phone, against the vectors Xcode copies into the app from `tests/vectors/` (the project's blue `vectors` folder), and shows how long the 600,000-round key derivation a sign-in runs takes there. It has to stay near a second.
- **`NapsackCrypto`** is the encryption. It implements the formats in `shared/crypto/crypto.js` (the reference) with Apple's CryptoKit and CommonCrypto, byte for byte ([how-napsack-works.md](how-napsack-works.md)). A file per area, like `crypto.js`'s sections: `E2E.swift` (the password, the identity, format 1), `Recovery`, `Texts` (format 2 texts, reactions, edits), `Pics`, `Groups` (format 3), `Media` (formats 4 to 7), `SafetyCode`, and `JSJSON`, which writes and reads the envelopes' JSON exactly as JavaScript does (their bytes are sealed, so they must match). Its second module, **`NapsackCryptoChecks`**, is `shared/crypto/vector-checks.js` in Swift: the same 64 checks, in the same order, under the same names. `swift test` runs them on the Mac (`VectorTests.swift`, which also fails if the list drifts from JavaScript's), and the app runs them on the phone.

### When a new format comes

A new message format lands in `crypto.js` first, with a new vector file and new checks in `vector-checks.js` (CLAUDE.md, Code standards). Then, in Swift:
1. Add the functions to `NapsackCrypto`, in the file for its area, following what's there.
2. Add the vector file to `Vectors.swift` (a `Decodable` struct, and its name in `Vectors.files`) and the checks to `VectorChecks.swift`, in the same order and with the same names as `vector-checks.js`.
3. Copy the new names into `VectorTests.javaScript`. Until then `sameChecksAsJavaScript` fails, which is how a missing check gets noticed.
4. `swift test --package-path ios/NapsackCrypto` until it's green, then ⌘U on the phone.

A check that disagrees with a vector means the Swift is wrong. The vectors are never changed.

`swift test` reads the vectors straight from the repository. The app gets its own copy each time it builds, so its tests (`VectorsOnDeviceTests`) run every check wherever they run, the phone included.

## Working on it

- **A branch and a pull request**, like everything else (`<name>/ios-...`; [onboarding.md](onboarding.md), Working together), with the plan row kept current.
- **Check it on your Mac:** `swift test` for the package, then ⌘U, or the `xcodebuild test` line above, and run it on the phone for anything you can see.
- **Server CI skips** a pull request that only changes `ios/` and the docs: its first job sees that and the server and Terraform checks skip, which counts as passing. There's nothing to put on staging or tag. When the app needs something new from the server, that's a server change with its own pull request and release, and it ships first ([releasing.md](operations/releasing.md), rule 1).
- **The app's CI** (`.github/workflows/ios.yml`) runs the same two steps on GitHub's Macs (free for this public repository) for every change to `ios/`, the vectors, or the shared crypto: the crypto package's tests, then the app's tests on a Simulator (the live ones skip there). Keep its commands matching the ones above. Its Simulator build is signed to run locally (no team): unsigned, the app gets no Keychain.
- **Versions:** the app's version is `MARKETING_VERSION` and its build number `CURRENT_PROJECT_VERSION` (`Config/Base.xcconfig`). Releasing it (TestFlight, the App Store, `ios-v*` tags) comes later, with the paid Developer Program ([mobile.md](design/mobile.md)).

## When it doesn't work

- **"Signing for Napsack requires a development team":** `Config/Local.xcconfig` is missing or has no `DEVELOPMENT_TEAM` (First time, step 3).
- **"No such module 'NapsackCrypto'":** File › Packages › Reset Package Caches, then build again.
- **The phone isn't offered as a destination:** unlock it, check the cable, accept **Trust**, and check Developer Mode is on.
- **"Could not launch Napsack":** the phone was locked; unlock it and run again. Or a free build is over 7 days old; run it again.
- **The app can't reach your Mac's server:** the server is on `FADE_BIND=0.0.0.0:8080`, both are on the same Wi-Fi, and Local Network is allowed for napsack (Settings › Privacy & Security). In Safari on the phone, `http://<name>.local:8080/api/config` should show the server's settings.
- **Xcode changed `project.pbxproj` and you didn't mean it to:** usually a team picked in Signing & Capabilities. Move the team to `Local.xcconfig` and `git checkout ios/Napsack.xcodeproj/project.pbxproj`.
