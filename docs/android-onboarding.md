# Android onboarding

Building the napsack Android app: what's in `android/`, setting up a machine the first time, the daily loop, and how the pieces work. It assumes you know napsack ([onboarding.md](onboarding.md)) but not Android, so it explains the Android words as they come up. The plan for the app (why native Kotlin, the stack, the order it's built in) is in [android.md](design/android.md), and its task list is [plan-android.md](management/plan-android.md).

Where things stand (2026-11-05): the app is a single development screen. It talks to a server and times the password's key derivation on the device. The encryption is being ported to Kotlin one format at a time; format 1 passes its vectors.

## The pieces

```
android/
├── settings.gradle.kts      the project: its modules, and where libraries come from
├── build.gradle.kts         the plugins every module shares
├── gradle.properties        Gradle's own settings
├── gradle/
│   ├── libs.versions.toml   every version, in one place
│   └── wrapper/             which Gradle to use (gradlew fetches it)
├── gradlew, gradlew.bat     run Gradle without installing it
├── crypto/                  the encryption, plain Kotlin (no Android), its own tests
│   ├── build.gradle.kts
│   └── src/
│       ├── main/kotlin/io/napsack/crypto/E2E.kt         the formats
│       └── test/kotlin/io/napsack/crypto/               the vector checks
└── app/                     the app
    ├── build.gradle.kts     the app's settings: its id, versions, SDK levels, servers
    └── src/
        ├── main/
        │   ├── AndroidManifest.xml     what the app tells Android about itself
        │   ├── kotlin/io/napsack/app/
        │   │   ├── MainActivity.kt     where the app starts
        │   │   ├── ServerScreen.kt     the screen you see
        │   │   ├── Server.kt           talking to a napsack server
        │   │   └── Theme.kt            napsack's colors
        │   └── res/                    the icon, the name, the network and backup rules
        ├── debug/res/          what debug builds change (plain http to this computer)
        ├── test/kotlin/        unit tests, on the JVM
        └── androidTest/kotlin/ tests on an emulator or phone, live against a server
```

The Android words, in the order you'll meet them:

- **Android Studio**: the editor, built on IntelliJ. It brings the **SDK** (Android's libraries and tools) and the **emulator** (a phone running on this computer). Open the `android/` folder in it, not the repository root.
- **Gradle**: the build tool. It reads the `*.gradle.kts` files (Kotlin), downloads libraries, compiles, and runs tests. Android Studio drives it; so can the command line (`./gradlew <task>` in `android/`). Its first run downloads a lot; later ones are quick.
- **The wrapper** (`gradlew`, `gradle/wrapper/`): a small script that downloads the exact Gradle version the project pins (9.8.2) and runs it, so nobody installs Gradle.
- **Module**: one thing Gradle builds, with its own `build.gradle.kts` and `src/`. There are two: **`:crypto`** (a plain Kotlin library, so its tests run on any computer with a JDK in seconds) and **`:app`** (the app, which uses `:crypto`).
- **Version catalog** (`gradle/libs.versions.toml`): every library's and plugin's version, named once. The build files refer to them as `libs.okhttp` and the like.
- **AGP** (the Android Gradle Plugin, 9.5): the part of Gradle that knows how to build an app. Kotlin is built into it.
- **SDK levels**, in `app/build.gradle.kts`: **API level** is Android's version as a number (37 is Android 17). `compileSdk` is the Android the code is compiled against, `targetSdk` the one whose rules the app follows, and `minSdk` the oldest it installs on (29, Android 10).
- **Build types**: **debug** (what Run builds: debuggable, talks to your computer) and **release** (what would go to Google Play: https only). Each has its own settings, like the server it starts on.
- **BuildConfig**: a class Gradle writes for each build type, holding settings from `build.gradle.kts` (`BuildConfig.SERVER_URL`, the version).
- **applicationId and namespace**: `com.getattr.napsack` is the app's permanent identity on phones and Google Play (the same as the iPhone app's bundle id). `io.napsack.app` is where the code lives. They don't have to match.
- **The manifest** (`AndroidManifest.xml`): what Android needs to know: the app's name and icon, its screens, its permissions, its backup and network rules.
- **Resources** (`res/`): everything that isn't code: the icon (`mipmap-anydpi`, `drawable`), strings, colors, and the XML rule files. A file in `src/debug/res/` replaces the one with the same name for debug builds only.
- **Activity**: a screen as Android sees it. The app has one, `MainActivity`, and Compose draws everything inside it.
- **Jetpack Compose**: how the screens are written, like SwiftUI on the iPhone. A screen is a function marked `@Composable` that describes what to show; when a value held with `remember { mutableStateOf(...) }` changes, Compose redraws what depends on it. `@Preview` functions show a screen in Android Studio's editor (the Split or Design view) without running the app.
- **AVD** (Android Virtual Device): an emulator's settings (which phone, which Android). This machine's is `Medium_Phone_API_37.0`; Android Studio's **Device Manager** makes more.
- **adb** (Android Debug Bridge, in the SDK's `platform-tools`): the command line for a connected phone or emulator: `adb devices` lists them, `adb logcat` shows their logs, `adb shell` opens a shell on them.
- **Unit tests and instrumented tests**: `src/test/` runs on your computer's JVM (fast, no phone); `src/androidTest/` runs on an emulator or phone (the real app, slower). The crypto's tests are unit tests in `crypto/src/test/`.

## First time on a machine

### macOS

1. **Android Studio**, from [developer.android.com/studio](https://developer.android.com/studio) (this was set up with Android Studio 2026.2). Open it once and let the setup wizard install the SDK, the emulator, and a system image. In **Settings › Languages & Frameworks › Android SDK**, make sure **Android 17 (API 37)** is installed under SDK Platforms.
2. **JDK 21**, for the command line (Android Studio brings its own, newer one):
   ```sh
   brew install openjdk@21
   ```
   `scripts/test-android.sh` finds it there. To use `./gradlew` by hand, set `JAVA_HOME=/opt/homebrew/opt/openjdk@21` (or put it in your shell profile).
3. **Open the project:** File › Open, then choose the repository's `android/` folder (or `make android-open`). Android Studio syncs: it runs Gradle once to learn the project (the first time downloads Gradle and the libraries: a few minutes). It also writes `android/local.properties` with your SDK's path, which git ignores.
4. **The Gradle JDK:** if the sync complains about Java, set **Settings › Build, Execution, Deployment › Build Tools › Gradle › Gradle JDK** to a JDK 21 (or Android Studio's own; the build then fetches 21 itself, the `foojay` plugin in `settings.gradle.kts`).
5. **An emulator:** Device Manager (the phone icon on the right edge) lists them. If there's none, **+** › Create Virtual Device › **Medium Phone**, then the **API 37** image (with Google Play), then Finish.
6. **Try it:** choose the `app` configuration and the emulator at the top, then Run (▶, or ⌃R). The emulator starts and the development screen opens. **Check** asks the server on your computer about itself (run one first: `make run`).

### Linux

The same, with:
- Android Studio from its tarball (or `sudo snap install android-studio --classic`). The SDK goes to `~/Android/Sdk`.
- `sudo apt install openjdk-21-jdk` (the script finds it in `/usr/lib/jvm`).
- The emulator needs hardware acceleration: KVM. `sudo apt install qemu-kvm`, add yourself to the `kvm` group (`sudo adduser $USER kvm`), and log in again. `emulator -accel-check` says whether it works.

### Windows (WSL)

The server and the JVM tests run in WSL as everything else does; the emulator doesn't, easily (WSL has no hardware acceleration for it and no display of its own). Two ways:
- **The JVM tests only, in WSL** (`make android-jvm`): install JDK 21 (`sudo apt install openjdk-21-jdk`), and the SDK's command-line tools from [developer.android.com/studio](https://developer.android.com/studio#command-line-tools-only) (unzip to `~/Android/Sdk/cmdline-tools/latest`, then `sdkmanager "platforms;android-37.0" "build-tools;36.0.0"`). That's what CI does.
- **The app on an emulator:** install Android Studio on Windows itself, open the repository's `android/` folder through `\\wsl$\...`, and run the emulator there. The emulator's `10.0.2.2` is Windows' own localhost, which reaches a server running in WSL. `make android` (the emulator tests) won't find that emulator from inside WSL; run the emulator tests from Android Studio instead.

### Your Android phone (optional)

The emulator does nearly everything. A real phone is for the camera, notifications, and timing the key derivation on real hardware.

1. **Developer options:** Settings › About phone, tap **Build number** seven times. Then Settings › System › Developer options › turn on **USB debugging**.
2. Connect it with a USB cable and unlock it. Allow USB debugging for this computer when it asks (tick "Always allow").
3. `adb devices` lists it as `device` (`unauthorized` means step 2's question is still waiting on the phone). Android Studio offers it beside the emulators; Run puts the app on it.
4. **Wireless:** Developer options › Wireless debugging, then in Android Studio the device list's **Pair Devices Using Wi-Fi**.

## The daily loop

- **Run** ⌃R (▶), **stop** ⌘F2 (■). Run builds the debug app, installs it on the chosen device, and opens it. **Apply Changes** (the ⚡ buttons beside Run) pushes small code changes without reinstalling.
- **Logcat** (View › Tool Windows › Logcat) shows the device's logs, filtered to the app while it runs from Android Studio. Crashes show there with their stack trace.
- **Previews:** open `ServerScreen.kt` and choose Split at the top right; the `@Preview` shows the screen as you edit it.
- **Tests in Android Studio:** the green arrows beside a test class or function run it. Unit tests run on the JVM; tests in `androidTest/` run on the chosen device.
- **The encryption's tests,** on the JVM in seconds (from `android/`):
  ```sh
  ./gradlew :crypto:test
  ```
- **Everything:** `make android` (`scripts/test-android.sh`): the crypto and the app's logic on the JVM, a release build's checks (https only, nothing backed up), then the app's emulator tests live against a fresh server on port 8199, starting an emulator without a window if none is running (and shutting down the one it started). `make android-jvm` is the same without the emulator and server, as CI runs it. Run `make android` before pushing Android work.

### Pointing the app at your own server

Debug builds start on `http://10.0.2.2:8080` and release builds on `https://api.napsack.io` (`buildConfigField` in `app/build.gradle.kts`); the address on the screen can be changed, and the app remembers it.

- **Emulator:** run the server (`make run`, port 8080) and keep the address as it is. The emulator reaches this computer as `10.0.2.2`. The first **Check** asks to allow napsack to find and connect to nearby devices: say Allow. Android 17 counts a development server (any private address, `10.0.2.2` included) as the local network, and an app targeting it needs the person's yes (`ACCESS_LOCAL_NETWORK`, shown as "Nearby devices"); without it the connection just times out. Only debug builds declare it (`src/debug/AndroidManifest.xml`), as only the iPhone's Debug builds ask about the local network.
- **A phone over USB:** `adb reverse tcp:8080 tcp:8080` makes the phone's own `localhost:8080` reach this computer's, so use `http://localhost:8080`. It lasts until the cable comes out.
- **Anything else** has to be https (staging, for example: `https://staging.napsack.io`). Plain http is allowed only to `10.0.2.2`, `localhost`, and `127.0.0.1`, and only in debug builds (`src/debug/res/xml/network_security_config.xml`); release builds never allow it, and `make android` checks.

## How it works

- **`MainActivity.kt`** is where the app starts. It draws edge to edge (behind the status and navigation bars) and shows `ServerScreen` in napsack's theme.
- **`Server.kt`** talks to a napsack server, with OkHttp. Every request says which app is asking (`X-Napsack-Client: android/0.1.0+1`), so a server can turn away an app older than it supports. `ServerConfig` is `GET /api/config` ([api.md](spec/api.md)), read with kotlinx.serialization. `ClientVersion` compares versions the way the server does (`server/src/version.rs`), and `updateNeeded` checks `min_client_versions.android`.
- **`ServerScreen.kt`** is the development screen. It checks a server, shows its version, build, and formats, and warns when the server needs a newer app. Before checking a server on the local network in a debug build, it asks for the local network permission (`LocalNetwork` in `Server.kt`). It also times the 600,000-round key derivation a sign-in runs, which has to stay near a second on a phone. An answer that arrives after the address changed is dropped (the screen has moved on).
- **`Theme.kt`** is napsack's palette from the web app (`server/static/style.css`), always dark, as the web is.
- **`crypto/`** is the encryption. It implements the formats in `shared/crypto/crypto.js` (the reference) with the Java crypto APIs Android ships (PBKDF2, HMAC for HKDF, ECDH on P-256, AES-GCM), byte for byte ([how-napsack-works.md](how-napsack-works.md)). Its tests read the pinned vectors in `tests/vectors/` straight from the repository and make the same checks `shared/crypto/vector-checks.js` makes, under the same names (`VectorChecks.kt`, `VectorTest.kt`). Format 1 is done.
- **Nothing is backed up:** `android:allowBackup="false"` and `res/xml/data_extraction_rules.xml` keep the app's files out of Google's backups and off a new phone, as the iPhone keeps its keys on the one device.
- **The emulator test** (`androidTest/.../ServerScreenTest.kt`) grants the local network permission, types the test server's address into the screen, checks, and expects the server's version; `scripts/test-android.sh` passes both as instrumentation arguments. It also times the derivation on the device.

### Porting the next format

Step 2 of the plan ([android.md](design/android.md)) is every format passing its vectors, in the order the iPhone took them. For each one:
1. Read its section of `crypto.js` and its checks in `vector-checks.js`; the Swift port (`ios/NapsackCrypto/Sources/NapsackCrypto/`) shows the same thing in a typed language.
2. Add the functions to `crypto/` (a file per area, following `E2E.kt`).
3. Add its vector file's fields to `Vectors.kt`, and its checks to `VectorChecks.kt`, in `vector-checks.js`'s order and under its names. `VectorTest.sameChecksAsJavaScript` fails if a name or the order differs; add the new names to its `format1` list (rename it as it grows), until every check is ported and it compares with `javaScript` as a whole.
4. `./gradlew :crypto:test` until it's green.

A check that disagrees with a vector means the Kotlin is wrong. The vectors are never changed (CLAUDE.md, Code standards).

## Working on it

- **A branch and a pull request,** like everything else (`<name>/android-...`; [onboarding.md](onboarding.md), Working together), with the row in [plan-android.md](management/plan-android.md) kept current.
- **Check it on your machine:** `make android` (or `make android-jvm` without an emulator), and run it on the emulator for anything you can see.
- **Server CI doesn't run** for a pull request that only changes `android/` and the docs (`ci.yml` skips them), and there's nothing to merge into staging or tag. When the app needs something new from the server, that's a server change with its own pull request and release, and it ships first ([releasing.md](operations/releasing.md), rule 1).
- **The app's CI** (`.github/workflows/android.yml`) runs `make android-jvm`'s script on Linux, and only by hand (Actions › Android app › Run workflow): this machine is the Android CI to start, as the Mac is the iPhone's. Keep it running the same script.
- **Versions:** the app's version is `versionName` and its build number `versionCode` (`app/build.gradle.kts`). Libraries' and plugins' versions are in `gradle/libs.versions.toml`; a new library does real work, and the change says why.
- **Screens:** Android phones vary more than iPhones (sizes, densities, cutouts, gesture or button navigation, foldables, font scale up to 200%). Never write for one: use the safe insets (`WindowInsets.safeDrawing`), let text wrap, and look at the smallest and largest emulator profiles at the largest font scale:
  ```sh
  adb shell settings put system font_scale 2.0    # back with 1.0
  adb exec-out screencap -p > screen.png          # a screenshot of the device
  ```

## When it doesn't work

- **The sync fails with "Unsupported class file major version" or a Java error:** Gradle is running on the wrong JDK. Set the Gradle JDK (First time, step 4), or `JAVA_HOME` on the command line.
- **"SDK location not found":** open the project in Android Studio once (it writes `local.properties`), or set `ANDROID_HOME` (`~/Library/Android/sdk` on a Mac, `~/Android/Sdk` on Linux).
- **"Failed to find target with hash string 'android-37'":** API 37 isn't installed: Settings › Languages & Frameworks › Android SDK › SDK Platforms.
- **The app says it can't reach the server, "after 10000ms":** napsack isn't allowed on the local network: Settings › Apps › napsack › Permissions › Nearby devices › Allow (or reinstall and say Allow when Check asks).
- **The app says it can't reach the server:** the server is running (`curl http://127.0.0.1:8080/api/config` on this computer), the address is `http://10.0.2.2:8080` on the emulator or `http://localhost:8080` after `adb reverse` on a phone. "Cleartext HTTP traffic not permitted" in Logcat means plain http to some other address: use https there.
- **`make android` says something is already serving on port 8199:** another run is still going (or its server was left behind): stop it, or run with `PORT=<another port>`.
- **The emulator doesn't start from `make android`:** look at the log it names. `emulator -list-avds` lists the emulators there are; set `AVD=<name>` to use another. Starting it from Android Studio first works too: the script uses a running one as it is.
- **`adb devices` shows nothing, or `unauthorized`:** unlock the phone, accept the USB debugging question, try another cable (some only charge), or `adb kill-server` and try again.
- **A test on the emulator fails and the reason isn't clear:** the full Gradle log's path is printed; the HTML report is in `android/app/build/reports/androidTests/connected/`.
