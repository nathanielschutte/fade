#!/usr/bin/env bash
# Build the server, run it on a throwaway database, and run every test against it:
# unit tests, crypto vector checks, the API smoke test, and (unless --no-browser)
# the browser tests, which include shared/crypto's checks against the pinned vectors.
#
#   scripts/test.sh               everything
#   scripts/test.sh --no-browser  skip Playwright (no Chrome needed)
#
# Needs: cargo, Node.js 22+, python3 with tests/requirements.txt installed, and Chrome
# (or E2E_CHROME=bundled after `python3 -m playwright install chromium`).
# Works in WSL, Linux, macOS, and CI. On this Windows machine, Smart App Control
# blocks freshly built binaries, so run it in WSL (setup: CLAUDE.md).
set -euo pipefail
cd "$(dirname "$0")/.."

BROWSER=1
[ "${1:-}" = "--no-browser" ] && BROWSER=0
PORT="${PORT:-8099}"
# Python: $PYTHON, else the WSL test venv if it exists, else whatever python3 is on PATH.
VENV_PY="$HOME/.venvs/napsack-tests/bin/python"
if [ -n "${PYTHON:-}" ]; then PY="$PYTHON"
elif [ -x "$VENV_PY" ]; then PY="$VENV_PY"
else PY="$(command -v python3 || command -v python)"; fi

# Linux without Google Chrome (WSL): use Playwright's own Chromium. Its build for
# Ubuntu 24.04 runs on newer Ubuntu releases Playwright doesn't recognize yet.
if [ "$(uname -s)" = Linux ] && ! command -v google-chrome >/dev/null; then
  export E2E_CHROME="${E2E_CHROME:-bundled}"
  if grep -qE '^VERSION_ID="(2[6-9]|[3-9][0-9])' /etc/os-release 2>/dev/null; then
    export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE="${PLAYWRIGHT_HOST_PLATFORM_OVERRIDE:-ubuntu24.04-x64}"
  fi
fi

echo "==> unit tests"
(cd server && cargo test --quiet)

echo "==> crypto vectors (independent implementation)"
"$PY" tests/vectors/check_format1.py
"$PY" tests/vectors/check_format2.py
"$PY" tests/vectors/check_recovery.py

echo "==> shared crypto against the vectors (Node)"
# WSL installs Node with nvm, which non-interactive shells don't load.
if ! command -v node >/dev/null && [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi
command -v node >/dev/null || { echo "Node.js is required (see CLAUDE.md, Environment notes)"; exit 1; }
node --test "shared/**/*.test.js"

echo "==> building server"
(cd server && cargo build --quiet)
BIN=server/target/debug/fade-server
# server/target is shared by Windows and WSL builds, so choose by OS, not by what exists.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) BIN="$BIN.exe" ;; esac

TMP="$(mktemp -d)"
# A Windows binary and Windows Python need a Windows-style path.
command -v cygpath >/dev/null && TMP="$(cygpath -m "$TMP")"

export NAPSACK_URL="http://127.0.0.1:$PORT"
export NAPSACK_INVITE="letmein"
export NAPSACK_ADMIN="e2e_admin"
export NAPSACK_DB="$TMP/test.db"
export NAPSACK_SHOTS="${NAPSACK_SHOTS:-$TMP/shots}"

start_server() {
  FADE_BIND="127.0.0.1:$PORT" \
  FADE_DATABASE_URL="sqlite://$NAPSACK_DB" \
  FADE_INVITE_CODE="$NAPSACK_INVITE" \
  FADE_ADMINS="$NAPSACK_ADMIN,smoke_admin" \
  FADE_MIN_CLIENT_VERSIONS="ios=1.2.0" \
  RUST_LOG="${RUST_LOG:-fade_server=warn}" \
    "$BIN" >> "$TMP/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    curl -sf "$NAPSACK_URL/api/config" >/dev/null && break
    sleep 0.2
  done
  curl -sf "$NAPSACK_URL/api/config" >/dev/null || { cat "$TMP/server.log"; echo "server didn't start"; exit 1; }
}
trap 'kill ${SERVER_PID:-} 2>/dev/null || true' EXIT
start_server

echo "==> API smoke test"
"$PY" tests/smoke_test.py

echo "==> unopened pics survive a restart"
export NAPSACK_RESTART_STATE="$TMP/restart.json"
"$PY" tests/restart_test.py before
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
start_server
"$PY" tests/restart_test.py after

if [ "$BROWSER" = 1 ]; then
  for t in tests/e2e/test_*.py; do
    echo "==> $t"
    (cd tests/e2e && "$PY" "$(basename "$t")")
  done
  echo "screenshots: $NAPSACK_SHOTS"
fi

echo "==> all tests passed"
