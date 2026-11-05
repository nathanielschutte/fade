# The Android app

The plan for napsack on Android: what it's built with, how it's laid out in the repository, how it keeps the encryption identical to the web's and the iPhone's, and the order it's built in. The reasons for native apps at all, and the rules every client shares, are in [mobile.md](mobile.md) and [releasing.md](../operations/releasing.md). The task list is [plan-android.md](../management/plan-android.md); setting up a machine and the daily loop are in [android-onboarding.md](../android-onboarding.md).

Plan entry: [F29](../management/plan.md#f29-android-app). Started 2026-11-04 (Nate: "get a shell android app going like we did when we started ios development").

## Stack

**Native Kotlin, as decided for Android on 2026-10-29** ([mobile.md](mobile.md#stack-native-swift-then-kotlin)): the same reasons as Swift on the iPhone (the camera, a real phone layout, the platform used as documented, signed code).

| What | With | Why |
|---|---|---|
| Language | Kotlin 2.4 | Android's own language; coroutines for the async work |
| Screens | Jetpack Compose, Material 3 (napsack's own colors and type, not Material's look) | Declarative like SwiftUI, so screens port across in the same shape |
| Navigation | Navigation Compose, one activity | One back stack, like the iPhone's one navigation path |
| Build | Gradle 9.8 (wrapper, Kotlin DSL), Android Gradle Plugin 9.5 (Kotlin built in), a version catalog (`gradle/libs.versions.toml`) | Android Studio's standard; versions in one file |
| JDK | 21 (Homebrew's `openjdk@21`; on Android Studio's own, newer JDK the build fetches 21 itself, the foojay plugin) | What the build compiles with (the Kotlin and Java toolchain) |
| SDK | compile and target API 37 (Android 17); minimum API 29 (Android 10) | Android 10 and up covers nearly every phone in use and gives one storage and permissions model |
| HTTP and the live socket | OkHttp (one client for both) | The standard; a WebSocket built in |
| JSON | kotlinx.serialization | No reflection; matches the server's names exactly |
| Camera | CameraX: photos, video, zoom, torch, front and back | Google's camera library: it absorbs the differences between phone makers |
| Video | Media3: ExoPlayer to play, Transformer to encode H.264/AAC MP4 as the other apps send | One library for both sides |
| Keys on the phone | The Android Keystore | Hardware-backed where the phone has it (StrongBox on newer phones) |
| Notifications | Firebase Cloud Messaging | The only way to wake an Android app; needs a server change ([below](#notifications)) |
| Passkeys | Credential Manager (`androidx.credentials`) | Android's passkey API, with the PRF extension the passkeys design needs |
| Tests | JUnit 5 on the JVM (logic, the crypto vectors); Compose UI tests on an emulator against a real local server (JUnit 4 there: Android's test runner runs only JUnit 4) | As `make ios` does: a fresh server, the real app |

Nothing else is added without saying why in the change (as on the web: a dependency has to do real work).

## How it fits the repository

```
android/
  settings.gradle.kts, build.gradle.kts, gradle.properties
  gradle/libs.versions.toml     every version, in one place
  gradlew, gradle/wrapper/      the pinned Gradle (no Gradle install needed)
  crypto/                       NapsackCrypto: the formats in plain Kotlin (no Android), its own tests
    src/main/kotlin/io/napsack/crypto/
    src/test/kotlin/            reads ../../tests/vectors/*.json, the checks vector-checks.js makes
  app/                          the app (Compose)
    src/main/kotlin/io/napsack/app/
    src/test/kotlin/            JVM unit tests
    src/androidTest/kotlin/     emulator tests, live against a local server
```

- **`crypto/` is a plain Kotlin library, not an Android one.** Its tests run on any machine with a JDK in seconds, without an emulator, so the vectors are checked as often as the web's. It's the counterpart of `ios/NapsackCrypto`. The app also runs the same vector checks on the emulator and on a phone (`androidTest`), because Android's crypto provider isn't the desktop JDK's, and the 600,000-round PBKDF2 has to be timed on a real phone.
- **Package name `com.getattr.napsack`**, the same as the iPhone app's bundle id. Code lives under `io.napsack.*` (Kotlin packages don't have to match). The package name is permanent once on Google Play: **Nate to confirm before the first upload.**
- **Settings in the build files, never in Android Studio's local state.** The server address for each build type is a `buildConfigField` in `app/build.gradle.kts`, as the iPhone's are in `ios/Config/*.xcconfig`. Per-machine things (the SDK path) go in `android/local.properties`, which git ignores.
- **Development servers are the local network.** Android 17 makes an app targeting it ask the person before it reaches a private address, the emulator's `10.0.2.2` included (`ACCESS_LOCAL_NETWORK`, shown as "Nearby devices"). Only debug builds declare it and ask (`app/src/debug/AndroidManifest.xml`), as only the iPhone's Debug builds ask about the local network; release builds talk only to `https://api.napsack.io`.

## The encryption in Kotlin

Everything the formats use is in the Java crypto APIs that ship with Android. No third-party crypto:

| What | Where |
|---|---|
| PBKDF2-SHA256, 600,000 rounds | `SecretKeyFactory("PBKDF2WithHmacSHA256")` |
| HKDF-SHA256 | about twenty lines over `Mac("HmacSHA256")` (RFC 5869), checked by the vectors |
| P-256 key agreement | `KeyAgreement("ECDH")`, `KeyPairGenerator("EC")` with `secp256r1`; keys as PKCS#8 and SPKI DER (`PKCS8EncodedKeySpec`, `X509EncodedKeySpec`), as the web exports them |
| AES-256-GCM with associated data | `Cipher("AES/GCM/NoPadding")`, `updateAAD` |

The formats, in the order the iPhone took them: texts (1, 2), pics (1, 2), videos and photos (4 to 7), group messages (3, 5, 7), edits, reactions (`isReaction`, the same rule and test cases), recovery keys, safety codes, passkeys. `shared/crypto/crypto.js` stays the reference, and the pinned vectors in `tests/vectors/` are the contract: the Kotlin port makes every check `shared/crypto/vector-checks.js` makes, under the same names. If a check fails, the port is wrong, never the vector.

## Keys on the phone

The private key is unwrapped at sign-in exactly as on the web (from the password, so history works from the first launch). It's then kept encrypted by an AES key that lives in the Android Keystore: never exportable, hardware-backed where the phone has it, usable only while the phone is unlocked. The encrypted copy sits in the app's private files, kept out of backups and device transfer (`dataExtractionRules`), as the iPhone keeps its Keychain item on the one device. Signing out deletes both, along with kept chats and settings, as on the other clients.

## The server

Little changes, and what does ships before the app, as always ([releasing.md](../operations/releasing.md)):

- **The version handshake works already.** The app sends `X-Napsack-Client: android/<version>+<build>` (`version.rs` reads any platform). `min_client_versions` gains an `android` entry when an Android build first needs one.
- **App links.** `/i/<token>` links (and later passkeys) need `/.well-known/assetlinks.json`, served from the binary like `apple-app-site-association`: the package name and the signing key's fingerprint.
- **<a id="notifications"></a>Notifications.** Firebase Cloud Messaging's HTTP v1 API, from the server, signed with a service account (`fcm.googleapis.com` is already among the push hosts the server allows, for browsers). Who, never what, as for the iPhone. This needs a Firebase project and its key in settings: **Nate's, when we get there.**

## Getting set up

This Mac already has Android Studio 2026.2, the API 37 SDK, a phone emulator (`Medium_Phone_API_37.0`), and JDK 21. Step by step for someone new to Android: [android-onboarding.md](../android-onboarding.md). In short:

- **Android Studio** (it brings the SDK and the emulator), or the command-line SDK tools on Linux.
- **JDK 21.** The Gradle wrapper fetches Gradle itself.
- **An Android phone is optional to start.** The emulator does almost everything; the camera, notifications, and the PBKDF2 timing want a real phone. Developer options and USB debugging go on once per phone.
- **Google Play Console** ($25, once) is needed for testers and the store, as the Apple Developer Program was for TestFlight. Internal testing (up to 100 people, no review) is the TestFlight equivalent. Not needed until there's something to hand out: **Nate's, when we get there.**

## How it's tested

The same rules as every client ([CLAUDE.md](../../CLAUDE.md)): logic gets a unit test, a feature gets a test of what a person does, and checks wait for what they check.

- `make android` (`scripts/test-android.sh`): the crypto vectors and unit tests on the JVM, then the app's emulator tests live against a fresh local server (the emulator reaches the Mac as `10.0.2.2`), as `make ios` does.
- **CI:** like the iPhone app, the Mac is Android's CI machine to start (Nate, 2026-11-03: billed minutes). An `android.yml` workflow runs only by hand. The JVM tests (crypto, logic) need no emulator, so they could later run on Linux cheaply when `android/` changes.
- **Screens:** Android phones vary more than iPhones (sizes, densities, cutouts, gesture or button navigation, foldables, font scale up to 200%). Never write for one; check the smallest and largest emulator profiles at the largest font scale, as [ios-onboarding.md](../ios-onboarding.md#screen-sizes-and-shapes) does for the iPhone.

## The order it's built in

The iPhone app's path, which worked ([plan-ios.md](../management/plan-ios.md)):

1. **The shell (this change):** the Gradle project, one development screen (the server's `/api/config` with the version handshake, and the sign-in key derivation timed on the device), `crypto/` with format 1 against the vectors, onboarding, `make android`.
2. **Every encryption format in Kotlin**, checked on the JVM, the emulator, and a phone.
3. **Signing in and up** (keys in the Keystore), the update screen, sign out.
4. **The chat list and chats:** texts, replies, reactions, edits, the live socket.
5. **Pics and videos:** CameraX, review in place, captions, drawing, Send to…, the viewer.
6. **Friends, profiles, groups, report and block, account deletion** (Google Play requires deletion inside the app, as Apple does).
7. **Notifications** (FCM, with the server change), app links, passkeys.
8. **Into people's hands:** Play Console, internal testing, the store listing, the data safety form.

## Decisions for Nate

- **Package name** `com.getattr.napsack` (matching the iPhone): permanent once uploaded. Default built: that.
- **Minimum Android version:** 10 (API 29). Lower reaches a few more old phones but costs testing and older storage rules. Default built: 10.
- **When to set up Firebase (notifications) and the Play Console** (accounts and money): not needed for steps 1 to 6.
- **An Android phone to test on:** the emulator covers most of it; a real phone is wanted by step 5 (the camera).
