#!/usr/bin/env bash
# The iOS app's tests, as scripts/test.sh runs the server's: the encryption
# package against the pinned vectors (swift test), then the app's tests on a
# Simulator, against a fresh server and throwaway database so the live tests
# (sign-in, sending, the socket, the log viewer) run too.
#
#   bash scripts/test-ios.sh                everything
#   bash scripts/test-ios.sh --no-live      without a server: the same commands as CI (.github/workflows/ios.yml; keep them matching)
#   bash scripts/test-ios.sh --staging      live against staging, a real deployment (makes test accounts there; never production)
#   ONLY=NapsackTests/SendingTests bash scripts/test-ios.sh     one suite (or a test: .../SendingTests/name())
#   SIMULATOR="iPhone 17 Pro" bash scripts/test-ios.sh
#
# Needs a Mac with Xcode (docs/ios-onboarding.md). The full xcodebuild output
# goes to a log; this prints each failure and where the log is.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo "The iOS tests need a Mac with Xcode (docs/ios-onboarding.md)."; exit 2; }
LIVE=1 STAGING=0
case "${1:-}" in
  --no-live) LIVE=0 ;;
  --staging) STAGING=1 ;;
  "") ;;
  *) echo "usage: $0 [--no-live | --staging]"; exit 2 ;;
esac

PORT="${PORT:-8097}"
# The smoke test needs an iOS app older than the server allows (ios=1.2.0); this one is the app itself.
NAPSACK_MIN_CLIENTS=""
. scripts/test-env.sh
SIMULATOR="${SIMULATOR:-iPhone 17}"

STARTED=$SECONDS
SECTION="" SECTION_START=$SECONDS TIMES=""
section() {
  [ -n "$SECTION" ] && TIMES="$TIMES$(printf '%6ss  %s' $((SECONDS - SECTION_START)) "$SECTION")"$'\n'
  SECTION="$1" SECTION_START=$SECONDS
  [ -n "$1" ] && echo "==> $1"
  return 0
}
finish() {
  local code=$?
  kill "${SERVER_PID:-}" 2>/dev/null || true
  section ""
  echo; echo "==> times"; printf "%s" "$TIMES"; printf '%6ss  total\n' $((SECONDS - STARTED))
  if [ "$code" -eq 0 ]; then echo "==> all iOS tests passed"; else echo "==> failed"; fi
}
trap finish EXIT

section "crypto against the pinned vectors (swift test)"
swift test --package-path ios/NapsackCrypto 2>&1 | grep -E "✔ Test run|✘|error:" || true
swift test --package-path ios/NapsackCrypto >/dev/null 2>&1 || { echo "swift test failed: run it to see why"; exit 1; }

ENV=()
if [ "$STAGING" = 1 ]; then
  # As scripts/test-staging.sh: staging's address and invite from its Terraform, and only staging.
  NAPSACK_URL=$(terraform -chdir=infra/staging output -raw url)
  case "$NAPSACK_URL" in https://staging.*) ;; *) echo "refusing: $NAPSACK_URL isn't staging"; exit 1;; esac
  NAPSACK_INVITE=$(sed -n 's/^invite_code *= *"\(.*\)"/\1/p' infra/staging/terraform.tfvars)
  [ -n "$NAPSACK_INVITE" ] || { echo "no invite_code in infra/staging/terraform.tfvars"; exit 1; }
  echo "==> $NAPSACK_URL is running build $(curl -sf "$NAPSACK_URL/api/config" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p')"
elif [ "$LIVE" = 1 ]; then
  section "building server"
  (cd server && cargo build --quiet)
  start_server
fi
if [ "$LIVE" = 1 ]; then
  # xcodebuild hands the tests every TEST_RUNNER_ variable, without the prefix.
  ENV=(TEST_RUNNER_NAPSACK_TEST_SERVER="$NAPSACK_URL" TEST_RUNNER_NAPSACK_TEST_INVITE="$NAPSACK_INVITE"
       TEST_RUNNER_NAPSACK_TEST_ADMIN="$NAPSACK_ADMIN")
fi

section "app tests on the $SIMULATOR Simulator$([ "$LIVE" = 1 ] && echo ", live against $NAPSACK_URL")"
LOG="$TMP/ios-test.log"
ARGS=(test -project ios/Napsack.xcodeproj -scheme Napsack -destination "platform=iOS Simulator,name=$SIMULATOR")
[ -n "${ONLY:-}" ] && ARGS+=("-only-testing:$ONLY")
# Counts from xcodebuild's own lines ("Test case 'Suite/name()' passed on ..."), the same with or without parallel Simulator clones.
count() { grep -cE "^Test case '.*' $1 on" "$LOG" || true; }
if env ${ENV[@]+"${ENV[@]}"} xcodebuild "${ARGS[@]}" >"$LOG" 2>&1; then
  echo "$(count passed) passed, $(count skipped) skipped$([ "$LIVE" = 0 ] && echo " (the live ones need a server)")"
else
  grep -E "^Test case '.*' failed on|error:" "$LOG" | sed -E "s/ on '.*//" | head -40 || true
  echo "$(count passed) passed, $(count failed) failed. Why, in Xcode's words: open the .xcresult below, or the full log"
  grep -oE "/[^ ]*\.xcresult" "$LOG" | tail -1 || true
  echo "full log: $LOG"
  if [ "$LIVE" = 1 ] && [ "$STAGING" = 0 ]; then echo "--- server warnings"; grep -E "WARN|ERROR" "$TMP/server.log" | tail -20 || true; fi
  exit 1
fi
