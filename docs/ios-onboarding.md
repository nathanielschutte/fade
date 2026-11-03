# iOS onboarding

Building the napsack iPhone app: what's in `ios/`, setting up a Mac and an iPhone the first time, the daily loop, and how the pieces work. It assumes you know napsack ([onboarding.md](onboarding.md)) but not Xcode or iOS, so it explains the Xcode words as they come up. The plan for the app (why native Swift, milestones, TestFlight, releases) is in [mobile.md](design/mobile.md).

Where things stand (2026-11-03): the app has chats, friends, groups, pics and videos, notifications, and settings, and it's on TestFlight for the owner's own team. Next is TestFlight for friends outside it, which goes through Apple's review first ([the checklist](#external-testing-the-checklist)). What else is next is in [plan-ios.md](management/plan-ios.md).

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
│   ├── DeveloperScreen.swift  Admins only: the server's settings and the encryption's checks
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
  The easy way: **`make ios`** (`scripts/test-ios.sh`) runs the crypto package's tests, then the app's on a Simulator against a fresh server on a throwaway database, live tests included, and prints how long each part took; `make ios-quick` skips the server (as CI does), `make ios-staging` runs the live tests against staging (a real deployment, behind Caddy; it makes test accounts there, never on production), and `ONLY=NapsackTests/SendingTests make ios` runs one suite. By hand: `xcodebuild` hands the tests any variable that starts with `TEST_RUNNER_`, without the prefix. Otherwise they show as skipped. One live test reads the log viewer back, which needs an Admin: run the server with `FADE_ADMINS=nate` and add `TEST_RUNNER_NAPSACK_TEST_ADMIN=nate`.

### Pointing the app at your own server

The app talks to one server, set by the build: `NAPSACK_SERVER_URL`. `Config/Base.xcconfig` has staging (what published code builds against until release builds move to `api.napsack.io`, [api-host.md](implementation/api-host.md)); your `Local.xcconfig` overrides it for your builds. Nothing in the app changes it (Nate, 2026-10-30): to use another server, change the setting and build again. Outside production the app says which server it's on (on sign-in and in Settings); in production it says nothing. (Admins are `FADE_ADMINS` on a local server; run it with `FADE_ADMINS=nate` to see Developer in Settings.)

- **Simulator:** run the server (`cd server && FADE_ADMINS=nate cargo run`), then set `NAPSACK_SERVER_URL = http:/$()/127.0.0.1:8080` in your `Local.xcconfig`. The simulator shares the Mac's network.
- **iPhone:** the server has to listen beyond the Mac itself, and the phone has to be on the same network. Find the Mac's name with `scutil --get LocalHostName`, then:
  ```sh
  cd server && FADE_BIND=0.0.0.0:8080 FADE_ADMINS=nate cargo run
  ```
  Set `NAPSACK_SERVER_URL = http:/$()/<that name>.local:8080` in your `Local.xcconfig`. iOS asks once to allow napsack on the local network; if you said no, turn it on in Settings › Privacy & Security › Local Network. Plain `http` is allowed only for the local network (`NSAllowsLocalNetworking` in `App-Info.plist`); anything else has to be `https`.
- **An account to sign in with:** make one on that server in a browser (`http://127.0.0.1:8080`, the invite code is `FADE_INVITE_CODE`; `cargo run` sets none, so no code is asked), then sign in with it in the app. Staging works the same way. On production, your real account works too, but a phone counts as one of your 10 signed-in devices, and the one used least recently is signed out to make room.
- Set it in your `Local.xcconfig`, never in `Base.xcconfig` (that one's shared). The `$()` in `https:/$()/` keeps an xcconfig from reading `//` as a comment.

## How it works

- **`NapsackApp.swift`** is where the app starts (`@main`). It makes the `Session` and shows the sign-in screen or the home screen, depending on whether someone's signed in.
- **`Session.swift`** is who's signed in. Signing in works as the web app's does: the password is turned into keys on the phone (600,000 rounds of PBKDF2, about half a second on an iPhone 16 Pro), only the auth key goes to the server (`POST /api/auth/login`), and the private key comes back wrapped, which only the password unwraps. What's kept is one `Account` (the server, the session token, who you are, and the private key), saved as one Keychain item. At launch the app goes straight in with it, then asks the server (`GET /api/me`); if the session was ended (signed out elsewhere, turned off), it signs out and says so. No connection keeps you in. Signing out ends the session on the server and removes the item.
- **`Keychain.swift`** keeps secrets in the iPhone's Keychain, readable only while the phone is unlocked and only on this phone: never synced to your other devices, never moved by a backup (`WhenUnlockedThisDeviceOnly`). The password is never kept anywhere.
- **Signing up** (`Session.signUp`) also works as the web app's does: keys from the password, a new key pair made on the phone (the private key goes to the server only wrapped), then a recovery key, registered with the server and shown once (`RecoveryKeyScreen.swift`) until you say it's saved. The invite code is asked for only when the server's `/api/config` says it needs one.
- **`UpdateScreen.swift`** is all that shows when the server needs a newer app: when `/api/config` says so at launch, or any request is answered 426. Development builds have a way back to pick another server.
- **`Chats.swift`** is the chat list's data (`GET /api/friends` and `GET /api/groups`, loaded together) and what each row says about its newest message, in the web app's words (`app.js`, `chatStatus` and `groupStatus`): a text decrypted with the friend's pair key (its newest edit if it has one), a group text opened with your own wrap of its key, "New pic", "Sent a video", "Ana added you", or "Encrypted message" for what can't be opened. The rules live in `Reader`, plain functions that `ChatListTests` checks one by one with the vectors' keys; the rows are worked out off the main thread.
- **`Conversation.swift`** is an open chat: its history from `GET /api/chats/{friend}/messages` or `/api/groups/{id}/messages`, the newest 50 first, then 50 older at a time as you scroll up (`?before=`), each message made a `Bubble` by `Reader` (the same decryption as the list's previews, plus replies, edits, and reactions). **`ChatScreen.swift`** draws it: yours on the right, day headers, a reply's quote, the time under the last of each run, the group's encryption notice, and "This is the beginning…" where the history stops. Opening a chat marks it read. You write at the bottom. A long press on a message reacts to it, replies, copies it, or (your own text, for 15 minutes) edits it. A sent text waits in the conversation's outbox until the server has it: it's sealed once and sent with a `client_id`, so trying again after a dropped connection never stores it twice, and one that still can't go says "Not sent" with Try again.
- **`Live.swift`** is the live connection while the app is on screen: a WebSocket to `/api/ws` that signs in with its first frame. The server says what changed (a new message, a friend added); the open chat takes its own messages and the chat list fetches again. The API is the truth: after any drop the app reconnects, and on the server's `ready` it fetches what's shown again, so nothing missed while disconnected is lost. When the app goes off screen, the connection closes.
- **`Notifications.swift`** is notifications on the phone. Once you're signed in it asks once to show them; if allowed, iOS gives the app a device token, which goes to the server for this session (`POST /api/push/apns`) on every launch, and the server sends through Apple (`server/src/apns.rs`). Xcode builds get tokens from Apple's sandbox, Release builds (TestFlight, the App Store) from production: the `aps-environment` entitlement, `NAPSACK_APS_ENVIRONMENT` in the xcconfigs. Tapping one opens its chat; opening the app clears the delivered ones; the icon's badge is the Chats tab's count. Notifications come only when the server has an APNs key for that environment: staging has the Sandbox key, production the Production one, a local server none (so on your Mac's server, the token is accepted and nothing arrives). A free Apple ID's team can't have the capability: its `Local.xcconfig` empties `CODE_SIGN_ENTITLEMENTS`.
- **Passwords:** the same Associated Domains entitlement says `webcredentials:` for the site, and the site's association file names the app, so Passwords offers to save the sign-in and fills in the password saved on the web (sign-in's fields say `.username`, `.password`, `.newPassword`). A strength hint shows under new passwords (`PasswordStrength`, the web's rules), and the recovery key has Save or share.
- **`Links.swift`** is add-a-friend links (`/i/<token>`): opened anywhere on the phone (the site's `apple-app-site-association` names the app, and the Associated Domains entitlement names the site: staging's for Xcode builds, `napsack.io` in Release, `NAPSACK_LINK_HOST`) or scanned with **Scan their code** on Friends (VisionKit's `DataScannerViewController`, a real camera only). Signed in, the app asks "Add a friend?" and opens their chat; signed out, the sign-up form says who invited you and the new account starts out friends with them, no invite code needed. Apple fetches the association file when the app is installed, so a link opens the app only on a phone that installed it after the site served the file.
- **`AppLock.swift`** locks napsack with Face ID when it's turned on in Settings (this phone only): at launch and after a minute away, with a cover over the app (also in the app switcher). The Simulator can pretend: Features › Face ID › Enrolled, then Matching Face.
- **`Reporter.swift`** sends what goes wrong on the phone to the server's log viewer (`/admin#logs`, source "ios app"), batched like the web app's `report()`. Only ids, counts, statuses, and error wording go: never message content, keys, or tokens. Call `Reporter.shared.report(.warn, "what happened", ["friend_id": "7"])`.
- **`Pins.swift`** keeps each friend's and group member's public key as the phone first saw it (in the Keychain, per account). If the server later hands out a different key, which only an admin reset should cause, the app keeps reading with the pinned key, the chat list says "Safety code changed", and the chat shows a warning (**`SafetyCodeScreen.swift`**) until you compare safety codes or accept the new key. A key the server swapped in would let it read the chat, so the app never trusts one silently. Accepted keys stay as past keys, which still open the messages they sealed. The web app does the same (`app.js`, `checkPins`).
- **`SignInScreen.swift`** (signing in, or creating an account) and **`ChatListScreen.swift`** (friends and groups together, newest first, favorites on top, pull to refresh; your account, Sign out, and for Admins Developer, in the menu at the top right) are the main screens so far; **`DeveloperScreen.swift`** (Admins only, as the account's `role` says) shows what the build's server says about itself and opens the encryption's checks.
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

## Screen sizes and shapes

napsack runs on every iPhone that runs iOS 18 or later, and its testers already have a spread of them (a 12 Pro Max, a 14, a 15 Pro, a 16 Pro). Never write for particular models, and never design only for the phone on your desk. The app asks the phone what it has (its space, its safe area, its cameras, Face ID or Touch ID) and fits itself to that. Get the smallest and the largest right and everything in between follows.

### The range

Sizes are in **points**, the unit SwiftUI lays out in (a point is 2 or 3 pixels, depending on the screen). These come from Xcode's Simulator profiles (`/Library/Developer/CoreSimulator/Profiles/DeviceTypes`, November 2026). Look again when new iPhones come out.

| Points (wide × tall) | iPhones | Top of the screen | Unlocks with |
|---|---|---|---|
| 320 wide | the small ones with **Display Zoom** on (Settings › Display & Brightness), which makes everything bigger: about 320 × 568 on an SE, 320 × 693 on a mini | | |
| 375 × 667 | SE (2nd and 3rd generation): the shortest | a plain status bar, and a home button below the screen | Touch ID (the home button) |
| 360 × 780 | 12 mini, 13 mini: the narrowest without Display Zoom | notch | Face ID |
| 375 × 812 | XS, 11 Pro | notch | Face ID |
| 390 × 844 | 12, 12 Pro, 13, 13 Pro, 14, 16e, 17e | notch | Face ID |
| 393 × 852 | 14 Pro, 15, 15 Pro, 16 | Dynamic Island | Face ID |
| 402 × 874 | 16 Pro, 17, 17 Pro, 18 Pro | Dynamic Island | Face ID |
| 414 × 896 | XR, XS Max, 11, 11 Pro Max | notch | Face ID |
| 420 × 912 | Air | Dynamic Island | Face ID |
| 428 × 926 | 12 Pro Max, 13 Pro Max, 14 Plus | notch | Face ID |
| 430 × 932 | 14 Pro Max, 15 Plus, 15 Pro Max, 16 Plus | Dynamic Island | Face ID |
| 440 × 956 | 16 Pro Max, 17 Pro Max, 18 Pro Max: the largest | Dynamic Island | Face ID |
| 466 × 678, and 669 × 951 open | **Duo**, the foldable (2026): a short, wide outer screen folded, and a nearly square inner one open | Dynamic Island | Touch ID (the side button) |

The **safe area** is the part of the screen nothing covers. On top it's 20 points (the SE's status bar) to about 62 (the Dynamic Island). At the bottom it's 0 on the SE, which has a home button, and 34 on the others, for the home indicator, the bar you swipe up on. The corners are rounded differently on each model; the Duo's outer screen even has two tight corners and two round ones.

### What else differs

- **Face ID or Touch ID.** The SE and the Duo have Touch ID; the others Face ID. `LAContext().biometryType` says which (`AppLock.method` turns it into "Face ID" or "Touch ID" for the screen), so text on screen never says "Face ID" by itself. `NSFaceIDUsageDescription` is the question iOS asks on Face ID phones only; Touch ID doesn't ask.
- **Cameras.** The back of an iPhone has one camera (XR, SE, 16e, 17e, Air), two (a wide and an ultra wide (0.5×) on most; a wide and a 2× telephoto on the XS), or three on the Pros (adding a telephoto of 2×, 2.5×, 3×, 4×, or 5×). The front camera is the TrueDepth camera on Face ID phones. The camera finds the lenses itself (`CameraSession.Lenses`, from the device's own zoom factors, Camera.swift), so the lens buttons are whatever this phone has. The Simulator has no camera at all.
- **Buttons.** Every iPhone has volume buttons. **Camera Control**, a button on the side that clicks and slides, is on the 16, 16 Pro, 17, 17 Pro, 18 Pro, and Air (not the 16e or 17e). An app's camera gets the volume buttons and Camera Control's click as the shutter through `AVCaptureEventInteraction`, and Camera Control's slider (zoom, for one) through `AVCaptureSession`'s controls (iOS 18; check `supportsControls`, which is false on phones without it). The **Action button** (15 Pro and later, in place of the ring switch) does whatever the person picked; an app takes part only through App Intents or a Control Center control, never by reading the button.
- **Screen speed.** Pro models from the 13 Pro on, and the 17 and Air, draw up to 120 times a second (ProMotion); the others 60. Animate with SwiftUI's animations or `TimelineView`, never with a timer that assumes 60.
- **The Duo** changes size while napsack is open: folding or unfolding switches screens, and the inner screen can show two apps side by side. A layout that works from 320 to 669 points wide covers it, as long as nothing on screen is rebuilt (and its state lost) because the size changed. It also takes the Apple Pencil, which the drawing tool should treat like a finger. napsack is an iPhone-only, portrait-only app (`TARGETED_DEVICE_FAMILY = 1`, `UISupportedInterfaceOrientations`); how the inner screen shows such an app is to be checked on the Duo Simulator (it needs the iOS 27.1 runtime).
- **iPads** run iPhone-only apps too, in a phone-sized window, and Apple's reviewers sometimes use one (guideline 2.4.1). It has to work there, even though it won't look its best.

### The rules

1. **Stay inside the safe area.** Only backgrounds and full-screen pictures go past it (`.ignoresSafeArea()` on that layer alone, as the camera's preview does); buttons and text stay inside. Bars pinned to an edge use `.safeAreaInset(edge:)`, which also keeps them above the keyboard. Never add a number for the status bar, the notch, the Dynamic Island, or the home indicator: it's different on every phone.
2. **No screen sizes in code.** No `UIScreen.main.bounds` (it's the whole screen, not napsack's window, and wrong on the Duo or beside another app), no `if width > 400`, no model names. Let the container decide: stacks, `Spacer`, `.frame(maxWidth: .infinity)`, `containerRelativeFrame`, and `ViewThatFits` to pick a layout that fits. `GeometryReader` only where a real size is needed (the camera's caption, a pic filling the screen).
3. **Fixed sizes only for small things**, like an icon, an avatar, or a button's tap area (at least 44 × 44 points). When it sits next to text, let it grow with the text (`@ScaledMetric var size = 32.0`). A fixed width on anything holding text (a menu, a row of buttons, a field) breaks at large text or on a 320-point screen.
4. **Dynamic Type.** People choose their text size (Settings › Display & Brightness › Text Size, and much larger under Accessibility), and napsack follows it. Use text styles (`.body`, `.headline`, `.caption`), never `.font(.system(size:))` for words. Text wraps instead of cutting off a name or a button's label; at the accessibility sizes a row may need to stack (`ViewThatFits`, or `dynamicTypeSize.isAccessibilitySize`).
5. **The keyboard.** On a 375 × 667 phone it leaves under 400 points. What you're typing and the button that sends it stay in sight.
6. **Ask the phone, not the model.** Cameras: `AVCaptureDevice.DiscoverySession` and the device's zoom factors. Unlocking: `LAContext().biometryType`. Camera Control: `supportsControls`. Space: the layout.
7. **Check both ends** before calling something done: the SE (shortest), a mini (narrowest), and a Pro Max (largest), once with large text, and the Duo's two screens for anything with a lot on it. A real phone for what the Simulator can't do (the camera, Face ID's feel, notifications).

### How to check

- **Simulators.** `xcrun simctl list devicetypes` lists every model; make one with `xcrun simctl create "SE" "iPhone SE (3rd generation)"`. The iOS 27 runtime here runs the 11 and later, the SE (2nd and 3rd generation), and the minis; the Duo needs iOS 27.1. The XS and XR stop at iOS 18, so seeing them needs an iOS 18 runtime (Xcode › Settings › Components), which is only worth it to check iOS 18 itself. The Simulator's Settings app has Display Zoom and Text Size too.
- **While it runs from Xcode:** the Environment Overrides button in the bar above the console changes the text size, light or dark, and more, live.
- **The canvas:** a `#Preview` shows one phone; pick the phone at its bottom, and its Variants button shows every text size at once.
- **In a test**, a screen drawn at any size into a picture you can look at (and Claude can read), without a Simulator for each phone. Inside a test in `NapsackTests` (the app's code, signed in against the test server as the live tests are):
  ```swift
  @MainActor func picture(of view: some View, width: CGFloat, height: CGFloat, to path: String) async throws {
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: width, height: height)
      window.rootViewController = UIHostingController(rootView: view)
      window.makeKeyAndVisible()
      try await Task.sleep(for: .seconds(2))  // until it has loaded and drawn
      let png = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try png.write(to: URL(fileURLWithPath: path))
      window.isHidden = true
  }
  ```
  Call it with `ChatListScreen(account: account).environment(session)` (and `.environment(\.dynamicTypeSize, .accessibility3)` for large text) at 375 × 667, 360 × 780, 440 × 956, and the Duo's 466 × 678 and 669 × 951. The window keeps the safe area of the Simulator it runs on, so check edges and the keyboard on a Simulator of that model. Pictures like these are for looking, not for committing.

## TestFlight

TestFlight is how builds reach phones before the App Store: yours and up to 100 people on the App Store Connect team (**internal** testers, no review), then friends by email or a public link (**external**, up to 10,000; the first build of each version goes through Apple's Beta App Review, usually within a day or two). A build expires after 90 days. The plan for the App Store itself is in [plan-ios.md](management/plan-ios.md), section 12.

### Once (the owner, with the Developer Program)

1. **The bundle id.** It's the app's permanent identity: once the app is in App Store Connect it can't change. The code uses `NAPSACK_BUNDLE_ID` in `Config/Base.xcconfig`. Register it at [developer.apple.com](https://developer.apple.com/account) → Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App:
   - **Description:** napsack. **Bundle ID:** Explicit, exactly what `Base.xcconfig` says.
   - **Capabilities:** **Push Notifications** and **Associated Domains** (add-a-friend links on the site opening the app). Both are in the app's entitlements (`Config/Napsack.entitlements`); cloud signing turns them on for the App ID if they aren't yet.
   - **App Services:** none. **Capability Requests:** none (special permissions Apple grants one by one; napsack needs none).
2. **The app in App Store Connect.** [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Apps → **+** → New App:
   - **Platforms:** iOS. **Name:** napsack (the App Store name: unique across the store; it can change later). **Primary language:** English (U.S.).
   - **Bundle ID:** the one from step 1. **SKU:** your own label for it, never shown to anyone, e.g. `napsack-ios`. **User access:** Full Access.
3. **This Mac's settings**, `Config/Local.xcconfig`: `DEVELOPMENT_TEAM` = the Program team's id (developer.apple.com → Membership; it may differ from the free account's), and **delete the `NAPSACK_BUNDLE_ID` line** (the `.dev` id was for the free account). Development builds then use the real id too.
4. **An App Store Connect API key**, so the upload can sign and send without Xcode's windows: App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → **+**, name `napsack upload`, access **Admin**. (Only an Admin key may use cloud signing, where Apple keeps the distribution certificate and signs the upload; with App Manager the upload fails with "Cloud signing permission error" and "No profiles for ...".) Download the `.p8` (only once!) to `~/.appstoreconnect/private_keys/`, and make `ios/Config/AppStoreConnect.env` (git-ignored; never commit it):
   ```
   ASC_KEY_ID=ABC123DEFG
   ASC_ISSUER_ID=12345678-aaaa-bbbb-cccc-1234567890ab
   ASC_KEY_FILE=~/.appstoreconnect/private_keys/AuthKey_ABC123DEFG.p8
   ```
   (The Key ID is in the keys list; the Issuer ID is above it.)

### Each build

1. `make ios` passes, and `ios/` is committed (the build number is the commit count, so it goes up with every commit; App Store Connect refuses a number it has seen).
2. `scripts/ios-testflight.sh`: it checks the settings (the real bundle id, the team, the server: release builds always use `https://api.napsack.io`), runs the crypto checks, builds the Release archive signed for the App Store, checks no test data is in it, and uploads it. `make ios-archive` does everything but the upload.
3. In App Store Connect → the app → TestFlight, the build appears after processing (minutes). It doesn't ask about **export compliance** (encryption): the owner's answer (plan-ios.md, section 12) is in every build, `ITSAppUsesNonExemptEncryption` in `Config/App.xcconfig`.
4. **Internal testing:** make a group, add yourself (and anyone on the team); TestFlight on the phone offers the build.
5. **External testing:** once the checklist below is done, add the build to the external group and submit it for Beta App Review.

### External testing: the checklist

External testers are anyone outside the App Store Connect team, invited by email or a public link. Before the first of them can install a build, Apple's **Beta App Review** looks at it: the first build of each version (`MARKETING_VERSION`), and sometimes later ones. It reviews against the whole of the [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), since a TestFlight app "should be intended for public distribution and should comply with the App Review Guidelines" (2.2). So what the App Store will ask, the first external build mostly asks too; only the store's own page (screenshots, description, privacy labels, age rating) waits for the App Store. Where things stood on 2026-11-03:

**Done**

- [x] **Release builds talk to production** through `https://api.napsack.io` (`Config/Release.xcconfig`): a Release build's Info.plist says `NapsackServerURL = https://api.napsack.io`, with production notifications (`NapsackAPNsEnvironment = production`) and links on `napsack.io`, and `/api/config` answers there.
- [x] **Export compliance:** `ITSAppUsesNonExemptEncryption = NO` is in the Release Info.plist (`Config/App.xcconfig`; Nate, 2026-11-02: all the app's encryption is Apple's own, CryptoKit, CommonCrypto, and HTTPS), so uploads don't ask.
- [x] **Permissions say why** (5.1.1(ii)), in the Release Info.plist: the camera ("napsack uses the camera for the pics and videos you send."), the microphone ("napsack records sound with the videos you send."), photos ("napsack sends photos you choose."), and Face ID ("napsack uses Face ID to unlock, when you turn the lock on in Settings."). Each is asked only when it's first used; photos come through iOS's own picker, which needs no permission, so that one never shows. Notifications are asked once after signing in, in iOS's own words.
- [x] **Deleting your account in the app** (5.1.1(v)): Settings › Delete account (server 0.49.0). It still needs a try on a phone.
- [x] **The privacy policy and the support page are live** (5.1.1(i), 1.2's "published contact information"): `https://napsack.io/privacy` (what's kept, who sees it, how long, and how to delete your account) and `https://napsack.io/support` (the contact address).
- [x] **Testers can sign up.** Sign-up is invite-only, but a friend's add-a-friend link signs anyone up with no invite code, as that person's friend (`invites.rs`: one link per person, never used up, never expiring). The site's `apple-app-site-association` names the app for `/i/*`, so once napsack is installed from TestFlight, the link opens it; opened before, it signs up on the website, and the account then signs in in the app.
- [x] **Sign in with Apple isn't needed:** guideline 4.8 asks for it only from apps that offer another company's sign-in, and napsack has its own accounts only.

**Still needed in the app** (code, with the area that owns it)

- [ ] **Report and block** (1.2, plan-ios.md section 12, Planned): apps with what other people write must let you report it and block whoever sent it, and answer reports in good time. Only friends can message you and unfriending stops them, which helps, but an unfriended person can ask again, so it isn't a block. This is the likeliest reason for a rejection. A server change first (a block that stops requests and messages, and reports that reach the Admins), then the web and the app.
- [ ] **The privacy policy and support inside the app** (5.1.1(i): "within the app in an easily accessible manner"): two links in Settings, to `/privacy` and `/support` on the server's `site_url`. Owner: iOS Settings.
- [ ] **Works on an iPad** (2.1, 2.4.1): reviewers sometimes install iPhone apps on an iPad, where they run in a phone-sized window. Run it once on an iPad Simulator: signing in, a chat, the camera saying there's none.
- [ ] **No crashes, nothing unfinished** (2.1): `make ios` passes, and a TestFlight build has been through signing up, a text, a pic, notifications, and deleting an account on a real phone. Hide anything that's half built.
- [ ] *(Small)* The local network question (`NSLocalNetworkUsageDescription`, "napsack connects to a development server on your network") and `NSAllowsLocalNetworking` are in Release builds too. Release never reaches the local network, so iOS never asks, but they could move to Debug only. Owner: iOS build settings (`Config/App.xcconfig`, `App-Info.plist`).

**Nate, in App Store Connect** (the app → TestFlight)

1. **Test Information** (once; edit it when it changes):
   - **Beta App Description** (required): "napsack is a private messenger for close friends: texts, and pics and videos that can be viewed once, all end-to-end encrypted. You join through a friend's link."
   - **Feedback Email:** the address on `/support` (testers' feedback from the TestFlight app also comes to App Store Connect, with screenshots).
   - **Privacy Policy URL:** `https://napsack.io/privacy`. **Marketing URL:** none.
2. **Beta App Review Information** (once):
   - **Contact:** your name, email, and phone, the phone in international form (`+1 ...`). Apple uses it if the review has a question.
   - **Sign-in required:** on, with the reviewer account (below). It must keep working: never turn it off or change its password while a build is in review.
   - **Review Notes** (up to 4,000 bytes): "Sign in with the account above. Its friend, nate, will answer. Try a text, a reply (swipe a message), a reaction (hold a message), and a pic or video from the camera: the friend can open it once. Settings has deleting your account. napsack is for friends: anyone can join through a friend's link (Friends › Share), and only friends can message each other." Add how to report and block once it's built.
3. **Groups:** the internal group exists. Make an external group, add the build, and submit it for review. For a public link, set its **Tester Limit** to fit the account cap (below); for email invitations, invite no more than that.
4. **Each build:** What to Test, in a sentence or two. Only one build per version is in review at a time, and up to six a day can be submitted.
5. **The version:** the first external build is the first one Apple reviews, so it's a good time to decide what `MARKETING_VERSION` it carries (`0.1.0` now; the owner's, [mobile.md](design/mobile.md)).

**The reviewer account** (Nate, 2026-11-02: a dedicated account, a User's permissions only; the one account on production made for testing). The owner makes it, so its password never passes through anyone else:

1. In a private browser window, open your own add-a-friend link (Friends → Copy link), so the new account starts out your friend and needs no invite code.
2. Sign up as `appreview` with a long password from your password manager. Save its recovery key there too.
3. New accounts are Users: no PowerUser or Admin role (`/fade/admins` stays as it is).
4. Put the username and password in the Beta App Review Information's sign-in fields, and nowhere else (never the repository, the plan, or a chat).

Answer its messages while a build is in review. Between reviews it can stay; turning it off (System → Users) also works, but turn it back on before the next submission.

**The account cap.** Production takes at most 100 accounts (`FADE_MAX_ACCOUNTS`, `guard.rs`), counting every account that isn't turned off or deleted (Team Napsack doesn't count, and neither does a deleted account). Past it, sign-up says "napsack isn't taking new accounts right now." TestFlight allows 10,000 testers, and every tester new to napsack takes a place (a friend who already uses the website signs in and takes none), the reviewer account included. Before inviting anyone, look at how many accounts there are (System → Users) and either keep the invitations and the public link's Tester Limit under the room left, or raise the cap first ([security.md](security.md), the settings: a line in `infra/main.tf`, `terraform apply`, a restart).

## When it doesn't work

- **"Signing for Napsack requires a development team":** `Config/Local.xcconfig` is missing or has no `DEVELOPMENT_TEAM` (First time, step 3).
- **"No such module 'NapsackCrypto'":** File › Packages › Reset Package Caches, then build again.
- **The phone isn't offered as a destination:** unlock it, check the cable, accept **Trust**, and check Developer Mode is on.
- **"Could not launch Napsack":** the phone was locked; unlock it and run again. Or a free build is over 7 days old; run it again.
- **The app can't reach your Mac's server:** the server is on `FADE_BIND=0.0.0.0:8080`, both are on the same Wi-Fi, and Local Network is allowed for napsack (Settings › Privacy & Security). In Safari on the phone, `http://<name>.local:8080/api/config` should show the server's settings.
- **Xcode changed `project.pbxproj` and you didn't mean it to:** usually a team picked in Signing & Capabilities. Move the team to `Local.xcconfig` and `git checkout ios/Napsack.xcodeproj/project.pbxproj`.
