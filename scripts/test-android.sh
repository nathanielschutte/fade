#!/usr/bin/env bash
# The Android app's tests, as scripts/test-ios.sh runs the iPhone app's: the
# encryption against the pinned vectors and the app's logic on the JVM (no
# emulator), a release build's checks, then the app's tests on an emulator,
# against a fresh server and throwaway database (the emulator reaches this
# computer as 10.0.2.2).
#
#   bash scripts/test-android.sh                  everything
#   bash scripts/test-android.sh --no-emulator    the JVM tests only: the same commands as CI (.github/workflows/android.yml; keep them matching)
#   AVD=Pixel_9_API_37 bash scripts/test-android.sh   another emulator (emulator -list-avds)
#
# A phone or emulator already connected (adb devices) is used as it is, and
# left running; an emulator this starts, it shuts down. Needs JDK 21 and the
# Android SDK (docs/android-onboarding.md). Gradle's output goes to a log; this
# prints each failure and where the log is.
set -euo pipefail
cd "$(dirname "$0")/.."
EMULATOR=1
case "${1:-}" in
  --no-emulator) EMULATOR=0 ;;
  "") ;;
  *) echo "usage: $0 [--no-emulator]"; exit 2 ;;
esac

# JDK 21: $JAVA_HOME if set, else the usual places Homebrew, macOS, and Linux put it.
if [ -z "${JAVA_HOME:-}" ]; then
  for jdk in /opt/homebrew/opt/openjdk@21 /usr/local/opt/openjdk@21 "$(/usr/libexec/java_home -v 21 2>/dev/null || true)" /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-21-openjdk-arm64 /usr/lib/jvm/java-21-openjdk; do
    if [ -n "$jdk" ] && [ -x "$jdk/bin/java" ]; then export JAVA_HOME="$jdk"; break; fi
  done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "JDK 21 not found: install it, or set JAVA_HOME (docs/android-onboarding.md)."; exit 2; }
# The SDK: $ANDROID_HOME, else android/local.properties (Android Studio writes it), else where Android Studio puts it.
if [ -z "${ANDROID_HOME:-}" ]; then
  ANDROID_HOME="$(sed -n 's/^sdk\.dir=//p' android/local.properties 2>/dev/null || true)"
  for sdk in "$ANDROID_HOME" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -n "$sdk" ] && [ -d "$sdk/platforms" ]; then ANDROID_HOME="$sdk"; break; fi
  done
  export ANDROID_HOME
fi
[ -d "${ANDROID_HOME:-}/platforms" ] || { echo "Android SDK not found: install Android Studio, or set ANDROID_HOME (docs/android-onboarding.md)."; exit 2; }
ADB="$ANDROID_HOME/platform-tools/adb"
AAPT2="$(ls -d "$ANDROID_HOME"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)"

PORT="${PORT:-8199}"
# The emulator tests are the app itself, so the server needs no particular Android version.
NAPSACK_MIN_CLIENTS=""
. scripts/test-env.sh

STARTED=$SECONDS
SECTION="" SECTION_START=$SECONDS TIMES=""
STARTED_EMULATOR=""
section() {
  [ -n "$SECTION" ] && TIMES="$TIMES$(printf '%6ss  %s' $((SECONDS - SECTION_START)) "$SECTION")"$'\n'
  SECTION="$1" SECTION_START=$SECONDS
  [ -n "$1" ] && echo "==> $1"
  return 0
}
finish() {
  local code=$?
  kill "${SERVER_PID:-}" 2>/dev/null || true
  if [ -n "$STARTED_EMULATOR" ]; then "$ADB" -s "$STARTED_EMULATOR" emu kill >/dev/null 2>&1 || true; fi
  section ""
  echo; echo "==> times"; printf "%s" "$TIMES"; printf '%6ss  total\n' $((SECONDS - STARTED))
  if [ "$code" -eq 0 ]; then echo "==> all Android tests passed"; else echo "==> failed"; fi
}
trap finish EXIT

# Gradle, with its output in a log; on a failure, what went wrong and where the log is.
gradle() {
  local log="$TMP/gradle-$1.log"; shift
  if ! (cd android && ./gradlew --console=plain "$@") >"$log" 2>&1; then
    grep -E "FAILED|^\* What went wrong|^e: |Exception|AssertionFailedError|expected:" -A3 "$log" | head -60 || true
    echo "full log: $log"
    return 1
  fi
}
# Tests, failures, and skips from JUnit's XML reports under a folder.
counts() {
  find "$1" -name 'TEST-*.xml' -exec cat {} + 2>/dev/null | grep -o '<testsuite [^>]*>' |
    awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); gsub(/[">]/, "", kv[2]); n[kv[1]] += kv[2] } }
         END { printf "%d passed, %d failed, %d skipped\n", n["tests"] - n["failures"] - n["errors"] - n["skipped"], n["failures"] + n["errors"], n["skipped"] }'
}
# Each failed test's name and the first line of why, from the same reports.
failures() {
  find "$1" -name 'TEST-*.xml' -exec cat {} + 2>/dev/null |
    awk 'match($0, /<testcase name="[^"]*"/) { name = substr($0, RSTART + 16, RLENGTH - 17) }
         /<(failure|error)/ { sub(/.*<(failure|error)[^>]*>/, ""); print "FAILED " name ": " substr($0, 1, 300) }'
}

section "crypto against the pinned vectors, and the app's logic (JVM)"
gradle jvm :crypto:test :app:testDebugUnitTest || exit 1
echo "crypto: $(counts android/crypto/build/test-results/test)"
echo "app: $(counts android/app/build/test-results/testDebugUnitTest)"

section "release build: https only, nothing backed up"
gradle release :app:assembleRelease || exit 1
APK=android/app/build/outputs/apk/release/app-release-unsigned.apk
grep -q 'SERVER_URL = "https://' android/app/build/generated/source/buildConfig/release/io/napsack/app/BuildConfig.java ||
  { echo "a release build's server isn't https"; exit 1; }
# Each dump is read whole first: grep -q stopping early would fail the pipe (pipefail).
# Release builds shorten resource paths, so the network rules are found by name.
RESOURCES="$("$AAPT2" dump resources "$APK")"
NSC="$(grep -A1 'xml/network_security_config$' <<<"$RESOURCES" | sed -n 's/.*(file) \([^ ]*\) type=XML.*/\1/p')"
[ -n "$NSC" ] || { echo "a release build has no network security config"; exit 1; }
RULES="$("$AAPT2" dump xmltree --file "$NSC" "$APK")"
grep -q 'cleartextTrafficPermitted=false' <<<"$RULES" && ! grep -q 'cleartextTrafficPermitted=true' <<<"$RULES" ||
  { echo "a release build allows plain http (development builds only: src/debug/res/xml)"; exit 1; }
MANIFEST="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$APK")"
grep -q 'allowBackup(0x01010280)=false' <<<"$MANIFEST" ||
  { echo "a release build allows backups"; exit 1; }
# Reaching a development server is debug builds' alone (src/debug/AndroidManifest.xml).
if grep -q 'ACCESS_LOCAL_NETWORK' <<<"$MANIFEST"; then echo "a release build asks for the local network"; exit 1; fi

[ "$EMULATOR" = 1 ] || exit 0

section "building server"
(cd server && cargo build --quiet)
start_server
SERVER_VERSION="$(curl -sf "$NAPSACK_URL/api/config" | sed -n 's/.*"server_version":"\([^"]*\)".*/\1/p')"
# The emulator's 10.0.2.2 is this computer's 127.0.0.1, where the server listens.
EMULATOR_URL="http://10.0.2.2:$PORT"

section "emulator"
"$ADB" start-server >/dev/null 2>&1
DEVICE="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
if [ -z "$DEVICE" ]; then
  AVD="${AVD:-Medium_Phone_API_37.0}"
  "$ANDROID_HOME/emulator/emulator" -list-avds | grep -qx "$AVD" ||
    { echo "no emulator named $AVD: make one in Android Studio's Device Manager, or set AVD= (emulator -list-avds)"; exit 1; }
  # A free console port of its own (5554, 5556, ...), so its serial is known before it's up.
  EMU_PORT=5554
  while "$ADB" devices | grep -q "^emulator-$EMU_PORT"; do EMU_PORT=$((EMU_PORT + 2)); done
  DEVICE="emulator-$EMU_PORT"
  echo "starting $AVD, without a window"
  "$ANDROID_HOME/emulator/emulator" -avd "$AVD" -port "$EMU_PORT" -no-window -no-audio -no-boot-anim >"$TMP/emulator.log" 2>&1 &
  STARTED_EMULATOR="$DEVICE"
  BOOTED=""
  for _ in $(seq 1 180); do
    if [ "$("$ADB" -s "$DEVICE" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then BOOTED=1; break; fi
    sleep 1
  done
  [ -n "$BOOTED" ] || { tail -20 "$TMP/emulator.log"; echo "the emulator didn't finish starting in 3 minutes (log: $TMP/emulator.log)"; exit 1; }
else
  echo "using $DEVICE, already connected"
fi
export ANDROID_SERIAL="$DEVICE"

section "app tests on $DEVICE, live against $EMULATOR_URL (server $SERVER_VERSION)"
rm -rf android/app/build/outputs/androidTest-results
if ! gradle connected :app:connectedDebugAndroidTest \
    -Pandroid.testInstrumentationRunnerArguments.napsackServer="$EMULATOR_URL" \
    -Pandroid.testInstrumentationRunnerArguments.napsackServerVersion="$SERVER_VERSION"; then
  failures android/app/build/outputs/androidTest-results
  echo "report: android/app/build/reports/androidTests/connected/debug/index.html"
  echo "--- server warnings"; grep -E "WARN|ERROR" "$TMP/server.log" | tail -20 || true
  exit 1
fi
counts android/app/build/outputs/androidTest-results
