# The iOS app

The plan for napsack's native app: what it's built with, how it shares the encryption with the web client, and how it's developed, versioned, and released. Release rules that apply to every client are in [RELEASING.md](RELEASING.md).

## Stack: Expo (React Native, TypeScript)

**Decision:** build the app with Expo and React Native, in TypeScript, and build, sign, and ship it with Expo Application Services (EAS).

Why this over the alternatives:

- **It works from Windows.** EAS builds and signs iOS apps on Apple hardware in the cloud, so day-to-day work happens in Windows and WSL, and the phone runs real builds. The MacBook stays optional: useful for the iOS Simulator and for debugging native crashes, but not required to ship. A Swift app would need the Mac for everything, and Flutter's iOS builds also need a Mac or a separate cloud builder.
- **It can share the encryption with the web client.** Message format 1 is defined by `crypto.js`, which uses the WebCrypto API. React Native gets the same API (`crypto.subtle`: ECDH P-256, HKDF, PBKDF2, AES-GCM) from `react-native-quick-crypto`, which runs it natively. One JavaScript implementation then serves both clients, so they can't drift apart. Getting this wrong would make messages unreadable across clients, which is the most expensive bug this project can have.
- **It's a real native app.** React Native renders native iOS views. It isn't a web page in a wrapper. That's what matters for the camera, the Keychain, and push notifications, and it's also what closes the "server delivers the JavaScript" gap from [how-napsack-works.md](how-napsack-works.md#limits), because the app's code is signed and reviewed before install.
- **It covers Android later** from the same code, if that ever matters.

The trade-off: a dependency on Expo's tooling and cloud. The free tier's build queue is slow, and there's a paid plan if that ever hurts. The app stays a standard React Native project, so it could leave EAS later.

## How it fits the repo

```
server/            Rust server; also serves the web client
  static/          web client (plain JS, no build step)
shared/            code both clients use, plain JS modules with JSDoc types
  crypto/          the format 1 implementation, moved out of server/static/crypto.js
  crypto/vectors.json   test vectors: fixed inputs and the exact bytes they must produce
mobile/            the Expo app (TypeScript)
```

- **Shared crypto, no build step for the web.** The crypto moves to `shared/crypto/` as plain ES modules with JSDoc types. The server keeps compiling it into the binary for the web client, and the mobile app imports the same files through Metro. Storage is the only platform-specific part: IndexedDB on the web, the iOS Keychain on the phone. It moves behind a small interface.
- **Test vectors keep the two in lockstep.** A script runs the web implementation over fixed inputs (password, salts, keys, IVs) and records every intermediate value and ciphertext in `vectors.json`. The web tests and the mobile tests both check against it, and CI fails if either disagrees.
- **Keys on the phone.** The unwrapped private key goes in the iOS Keychain (via `expo-secure-store`), readable only while the phone is unlocked and never synced to iCloud or other devices. The password-derived sign-in works exactly as on the web, so history works on the phone from day one.
- **Version handshake.** Every request carries `X-Napsack-Client: ios/<version>+<build>`. At launch the app reads `GET /api/config`. If the server's `min_client_versions.ios` is newer than the app, it shows an update screen that links to the App Store. A message whose `format` it doesn't know shows "Update napsack to read this".

## Getting set up

Accounts:
- **Apple Developer Program** ($99/year), needed to put builds on your own iPhone, for TestFlight, and for the App Store.
- **Expo account** (free to start), for EAS Build, Submit, and Update.

On Windows (not WSL, so the phone and Expo's dev server can reach each other on your network):
- Node.js LTS, then `npm install -g eas-cli` and `eas login`.
- In `mobile/`: `eas build --profile development --platform ios` once, to make a development build of the app, and install it on your phone. After that, `npx expo start` gives live reload from Windows.
- If the phone can't reach the dev server on your network, `npx expo start --tunnel` works anywhere.

The development build points at a server you choose: your own (`scripts/test.sh` setup, reachable over the tunnel) or production.

## Versions, builds, and releases

| | Where | Who changes it |
|---|---|---|
| App version (`1.2.0`) | `version` in `mobile/app.config.ts` | You, per release: SemVer like the server |
| Build number (`37`) | stored by EAS | EAS, automatically on every build |
| Native fingerprint | computed by Expo from native code and config | Expo; decides which installed apps an over-the-air update can reach |

Build profiles in `mobile/eas.json`:
- **development**: dev client with live reload, installed on registered devices.
- **preview**: a release build on TestFlight for internal testing.
- **production**: the App Store build.

Shipping:
1. **Native change.** Bump `version`, commit, and tag `ios-v1.2.0`. A workflow (added with the app) runs `eas build --profile production --auto-submit`, which builds in the cloud and uploads to TestFlight. Test it there, then submit for review in App Store Connect.
2. **JavaScript-only fix.** `eas update --channel production` publishes it. Only installed apps with the same native fingerprint receive it, so a fix can't reach an app whose native side it doesn't match. It's bound by the same compatibility rules as everything else.

Release order always follows [RELEASING.md](RELEASING.md): server first, then the app. Raise `min_client_versions.ios` only after the newer app is out and installed.

## First milestones

1. **Crypto spike.** Move the crypto to `shared/`, generate test vectors, and prove `react-native-quick-crypto` reproduces them byte for byte on a real iPhone, including 600,000-round PBKDF2 in about a second. If it can't, the fallback is the audited `@noble` libraries, but PBKDF2 would be slow in pure JavaScript, so this is the biggest risk and goes first.
2. **Skeleton.** Sign in, chat list, chat screen, sending and reading texts, against production.
3. **Camera and snaps.** Mirrored front camera and the same 200 KB compression as the web.
4. **Push notifications.** Device tokens on the server and APNs delivery. The server can't read messages, so notifications say who sent something, never what.
5. **TestFlight** for friends, then the App Store.
