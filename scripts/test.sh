#!/usr/bin/env bash
# Build the server, run it on a throwaway database, and run every test against it:
# unit tests, crypto vector checks, the API smoke test, and (unless --no-browser)
# the browser tests, which include crypto.js's unit tests against the pinned vectors.
#
#   scripts/test.sh               everything
#   scripts/test.sh --no-browser  skip Playwright (no Chrome needed)
#
# Needs: cargo, python3 with tests/requirements.txt installed, and Chrome
# (or E2E_CHROME=bundled after `python3 -m playwright install chromium`).
# Works in WSL, Linux, macOS, CI, and Git Bash on Windows.
set -euo pipefail
cd "$(dirname "$0")/.."

BROWSER=1
[ "${1:-}" = "--no-browser" ] && BROWSER=0
PORT="${PORT:-8099}"
PY="${PYTHON:-$(command -v python3 || command -v python)}"

echo "==> unit tests"
(cd server && cargo test --quiet)

echo "==> crypto vectors (independent implementation)"
"$PY" tests/vectors/check_format1.py

echo "==> building server"
(cd server && cargo build --quiet)
BIN=server/target/debug/fade-server
[ -f "$BIN.exe" ] && BIN="$BIN.exe"

TMP="$(mktemp -d)"
# A Windows binary and Windows Python need a Windows-style path.
command -v cygpath >/dev/null && TMP="$(cygpath -m "$TMP")"

export NAPSACK_URL="http://127.0.0.1:$PORT"
export NAPSACK_INVITE="letmein"
export NAPSACK_ADMIN="e2e_admin"
export NAPSACK_DB="$TMP/test.db"
export NAPSACK_SHOTS="${NAPSACK_SHOTS:-$TMP/shots}"

FADE_BIND="127.0.0.1:$PORT" \
FADE_DATABASE_URL="sqlite://$NAPSACK_DB" \
FADE_INVITE_CODE="$NAPSACK_INVITE" \
FADE_ADMINS="$NAPSACK_ADMIN" \
FADE_MIN_CLIENT_VERSIONS="ios=1.2.0" \
RUST_LOG="${RUST_LOG:-fade_server=warn}" \
  "$BIN" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  curl -sf "$NAPSACK_URL/api/config" >/dev/null && break
  sleep 0.2
done
curl -sf "$NAPSACK_URL/api/config" >/dev/null || { cat "$TMP/server.log"; echo "server didn't start"; exit 1; }

echo "==> API smoke test"
"$PY" tests/smoke_test.py

if [ "$BROWSER" = 1 ]; then
  for t in tests/e2e/test_*.py; do
    echo "==> $t"
    (cd tests/e2e && "$PY" "$(basename "$t")")
  done
  echo "screenshots: $NAPSACK_SHOTS"
fi

echo "==> all tests passed"
