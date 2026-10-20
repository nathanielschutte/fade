# The iOS app

The plan for napsack's native app: what it's built with, how it shares the encryption with the web client, and how it's developed, versioned, and released. Release rules that apply to every client are in [RELEASING.md](RELEASING.md).

## Stack: Expo (React Native, TypeScript)

**Decision:** build the app with Expo and React Native, in TypeScript, and build, sign, and ship it with Expo Application Services (EAS).

Why this over the alternatives:

- **It works from Windows.** EAS builds and signs iOS apps on Apple hardware in the cloud, so day-to-day work happens in Windows and WSL, and the phone runs real builds. The MacBook stays optional: useful for the iOS Simulator and for debugging native crashes, but not required to ship. A Swift app would need the Mac for everything, and Flutter's iOS builds also need a Mac or a separate cloud builder.
- **It can share the encryption with the web client.** The message formats are defined by `shared/crypto/crypto.js`, which uses the WebCrypto API. React Native gets the same API (`crypto.subtle`: ECDH P-256, HKDF, PBKDF2, AES-GCM) from `react-native-quick-crypto`, which runs it natively. One JavaScript implementation then serves both clients, so they can't drift apart. Getting this wrong would make messages unreadable across clients, which is the most expensive bug this project can have.
- **It's a real native app.** React Native renders native iOS views. It isn't a web page in a wrapper. That's what matters for the camera, the Keychain, and push notifications, and it's also what closes the "server delivers the JavaScript" gap from [how-napsack-works.md](how-napsack-works.md#limits), because the app's code is signed and reviewed before install.
- **It covers Android later** from the same code, if that ever matters.

The trade-off: a dependency on Expo's tooling and cloud. The free tier's build queue is slow, and there's a paid plan if that ever hurts. The app stays a standard React Native project, so it could leave EAS later.

## How it fits the repo

```
server/            Rust server; also serves the web client
  static/          web client (plain JS, no build step); keystore.js is its IndexedDB key storage
shared/            code every client uses: plain ES modules, no build step
  crypto/          crypto.js (formats 1 and 2), vector-checks.js, vectors.test.js
mobile/            the Expo app (TypeScript, Expo SDK 58)
tests/vectors/     format1.json, format2.json: fixed inputs and the exact bytes they must produce
```

- **Shared crypto, no build step for the web.** The crypto lives in `shared/crypto/crypto.js` as a plain ES module. The server compiles it into the binary and serves it as `/crypto.js` for the web client; the app imports the same file through Metro (`mobile/metro.config.js` watches `shared/`). Key storage is the only platform-specific part, so it isn't in that file: IndexedDB on the web (`server/static/keystore.js`), the iOS Keychain on the phone.
- **Test vectors keep the clients in lockstep.** [`tests/vectors/format1.json`](../tests/vectors/format1.json) and [`format2.json`](../tests/vectors/format2.json) pin a password, two key pairs, a wrapped key, a text, pics with and without captions, and a safety code, generated once from the web implementation. `shared/crypto/vector-checks.js` runs every check against them; Node runs it in CI (`node --test`), and the app runs it on the phone. The browser runs the same checks in `tests/e2e/test_crypto_vectors.py`, and Python checks the documented layouts independently.
- **Keys on the phone.** The unwrapped private key goes in the iOS Keychain (via `expo-secure-store`), readable only while the phone is unlocked and never synced to iCloud or other devices. The password-derived sign-in works exactly as on the web, so history works on the phone from day one.
- **Version handshake.** Every request carries `X-Napsack-Client: ios/<version>+<build>`. At launch the app reads `GET /api/config`. If the server's `min_client_versions.ios` is newer than the app, it shows an update screen that links to the App Store. A message whose `format` it doesn't know shows "Update napsack to read this".

## Getting set up

Accounts:
- **Apple Developer Program** ($99/year), needed to put builds on your own iPhone, for TestFlight, and for the App Store.
- **Expo account** (free to start), for EAS Build, Submit, and Update.

**Everything runs in WSL**, like the server. Smart App Control blocks the unsigned native binaries that many npm packages ship, so Node tooling doesn't run reliably on Windows here. EAS builds and signs in Expo's cloud, so no Mac is needed.
- Node: installed with nvm (`~/.nvm`), currently Node 24 LTS. Non-interactive shells need `. ~/.nvm/nvm.sh` first; `scripts/test.sh` does that on its own.
- EAS CLI: `npx eas-cli@latest <command>` from `mobile/` (no global install needed).

One-time, once Apple approves the developer account (all in `mobile/`, interactive):
1. `npx eas-cli@latest login`, then `npx eas-cli@latest init`. That links the project and prints its id; put it in `extra.eas.projectId` in `app.config.ts`.
2. `npx eas-cli@latest device:create` to register your iPhone (open the link it gives on the phone).
3. `npx eas-cli@latest build --profile development --platform ios`. The first time, it signs in to your Apple account and makes the certificates and provisioning profile itself. Install the result on the phone from the link it prints.
4. On the phone: Settings › Privacy & Security › Developer Mode, on (iOS asks once for development builds).

Then, day to day: `npx expo start --tunnel` in `mobile/`, and open the project in the napsack development build on the phone. The tunnel is needed because the phone can't reach WSL's network directly. A new development build is only needed when native code changes (a new native package, or config plugins).

The development build will point at a server you choose: your own (`scripts/test.sh` setup, through a tunnel) or production.

## Decisions still open

- **Which address the app talks to.** An installed app keeps whatever server address it was built with, and old versions stay installed for months. Since the domain will change again, the app should use an address that never changes (for example a dedicated `api.` name, or a small "where is the server" lookup), or every move needs the old domain kept forever. Decide before the first TestFlight build.
- **Export compliance.** App Store Connect asks whether the app uses encryption. It does (end-to-end, with standard algorithms), which usually qualifies for an exemption but has to be declared. Answer it at the first upload.

## Versions, builds, and releases

| | Where | Who changes it |
|---|---|---|
| App version (`1.2.0`) | `version` in `mobile/app.config.ts` | You, per release: SemVer like the server |
| Build number (`37`) | stored by EAS | EAS, automatically on every build |
| Native fingerprint | computed by Expo from native code and config | Expo; decides which installed apps an over-the-air update can reach |

Build profiles in `mobile/eas.json`:
- **development**: dev client with live reload, installed on registered devices.
- **simulator**: the same dev client for the iOS Simulator on a Mac. Unsigned, so it needs no Apple developer account: `npx eas-cli@latest build --profile simulator --platform ios`, then drag the downloaded app onto a running Simulator (or let `eas build:run -p ios` install it).
- **preview**: a release build installed directly on registered devices (no TestFlight), for trying a release build quickly.
- **production**: the store build; goes to TestFlight and then the App Store. EAS bumps the build number.

Shipping:
1. **Native change.** Bump `version`, commit, and tag `ios-v1.2.0`. A workflow (added with the app) runs `eas build --profile production --auto-submit`, which builds in the cloud and uploads to TestFlight. Test it there, then submit for review in App Store Connect.
2. **JavaScript-only fix.** `eas update --channel production` publishes it. Only installed apps with the same native fingerprint receive it, so a fix can't reach an app whose native side it doesn't match. It's bound by the same compatibility rules as everything else.

Release order always follows [RELEASING.md](RELEASING.md): server first, then the app. Raise `min_client_versions.ios` only after the newer app is out and installed.

## First milestones

1. **Crypto spike.** Move the crypto to `shared/`, and prove `react-native-quick-crypto` reproduces them byte for byte on a real iPhone, including 600,000-round PBKDF2 in about a second. If it can't, the fallback is the audited `@noble` libraries, but PBKDF2 would be slow in pure JavaScript, so this is the biggest risk and goes first.
   - Done so far: the crypto is in `shared/crypto/` (the web client is unchanged in behavior), the checks pass in Node and Chromium, and the app (`mobile/`) is a single screen that runs every check on the phone and times PBKDF2. On paper, quick-crypto supports every operation we use; the open questions are AES-GCM's `additionalData` and HKDF deriving an AES-GCM key, which the screen tests.
   - Left: a development build on the iPhone (waiting on Apple), and reading the screen. All green with PBKDF2 near a second means the plan holds.
2. **Skeleton.** Sign in, chat list, chat screen, sending and reading texts, against production.
3. **Camera and snaps.** Mirrored front camera and the same 200 KB compression as the web.
4. **Push notifications.** Device tokens on the server and APNs delivery. The server can't read messages, so notifications say who sent something, never what.
5. **TestFlight** for friends, then the App Store.
