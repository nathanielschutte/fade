# Shared by scripts/test.sh and scripts/test-one.sh (sourced, not run): which
# Python and browser the tests use, and a throwaway server to run them against.
# Expects to be sourced from the repository root, with PORT set.

# Python: $PYTHON, else the test venv (~/.venvs/napsack-tests) if it exists, else whatever python3 is on PATH.
VENV_PY="$HOME/.venvs/napsack-tests/bin/python"
if [ -n "${PYTHON:-}" ]; then PY="$PYTHON"
elif [ -x "$VENV_PY" ]; then PY="$VENV_PY"
else PY="$(command -v python3 || command -v python)"; fi

# The browser. Linux without Google Chrome: Playwright's own Chromium (its
# Ubuntu 24.04 build runs on newer releases Playwright doesn't recognize yet).
# macOS: Playwright's own headless browser too, so no Chrome window appears and
# no test waits on Chrome's slow exit there; the one test that needs Chrome's
# codecs asks for it (common.py, launch). CI's runners have Chrome, and use it.
case "$(uname -s)" in
  Linux)
    if ! command -v google-chrome >/dev/null; then
      export E2E_CHROME="${E2E_CHROME:-bundled}"
      if grep -qE '^VERSION_ID="(2[6-9]|[3-9][0-9])' /etc/os-release 2>/dev/null; then
        export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE="${PLAYWRIGHT_HOST_PLATFORM_OVERRIDE:-ubuntu24.04-x64}"
      fi
    fi ;;
  Darwin) export E2E_CHROME="${E2E_CHROME:-bundled}" ;;
esac

# Python prints as it goes, so a log shows when each line happened (CI's timestamps).
export PYTHONUNBUFFERED=1

BIN=server/target/debug/fade-server
# A folder shared by a Windows and a Linux build has both binaries, so choose by OS, not by what exists.
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
  # Two runs on one port would quietly test each other's server (and read the
  # wrong database), so refuse instead.
  if curl -sf "$NAPSACK_URL/api/config" >/dev/null 2>&1; then
    echo "Something is already serving on port $PORT (another test run?). Stop it, or run with PORT=<another port>."
    exit 1
  fi
  FADE_BIND="127.0.0.1:$PORT" \
  FADE_DATABASE_URL="sqlite://$NAPSACK_DB" \
  FADE_INVITE_CODE="$NAPSACK_INVITE" \
  FADE_ADMINS="$NAPSACK_ADMIN,smoke_admin" \
  FADE_MIN_CLIENT_VERSIONS="ios=1.2.0" \
  FADE_PUSH_ALLOW_LOCAL=true \
  FADE_MAX_ACCOUNTS=1000 \
  RUST_LOG="${RUST_LOG:-fade_server=warn}" \
    "$BIN" >> "$TMP/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    curl -sf "$NAPSACK_URL/api/config" >/dev/null && break
    sleep 0.2
  done
  if ! kill -0 "$SERVER_PID" 2>/dev/null || ! curl -sf "$NAPSACK_URL/api/config" >/dev/null; then
    cat "$TMP/server.log"; echo "server didn't start"; exit 1
  fi
}
