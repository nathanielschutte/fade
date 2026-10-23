#!/usr/bin/env bash
# Runs one browser test against a fresh server and throwaway database: the
# quick loop while working on a feature. scripts/test.sh runs everything.
#
#   bash scripts/test-one.sh test_profile.py      (a file in tests/e2e/)
#   bash scripts/test-one.sh smoke                (the API smoke test)
#
# Same setup as scripts/test.sh (run it in WSL here). Prints where the
# screenshots went, and the server's warnings if the test fails.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: $0 <test_file.py in tests/e2e | smoke>"; exit 2; }

PORT="${PORT:-8098}"
VENV_PY="$HOME/.venvs/napsack-tests/bin/python"
PY="${PYTHON:-$([ -x "$VENV_PY" ] && echo "$VENV_PY" || command -v python3)}"
if [ "$(uname -s)" = Linux ] && ! command -v google-chrome >/dev/null; then
  export E2E_CHROME="${E2E_CHROME:-bundled}"
  export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE="${PLAYWRIGHT_HOST_PLATFORM_OVERRIDE:-ubuntu24.04-x64}"
fi

(cd server && cargo build --quiet)
TMP="$(mktemp -d)"
export NAPSACK_URL="http://127.0.0.1:$PORT" NAPSACK_INVITE=letmein NAPSACK_ADMIN=e2e_admin
export NAPSACK_DB="$TMP/test.db" NAPSACK_SHOTS="$TMP/shots"
if curl -sf "$NAPSACK_URL/api/config" >/dev/null 2>&1; then
  echo "Something is already serving on port $PORT (another test run?). Stop it, or run with PORT=<another port>."
  exit 1
fi
FADE_BIND="127.0.0.1:$PORT" FADE_DATABASE_URL="sqlite://$NAPSACK_DB" FADE_INVITE_CODE=letmein \
  FADE_ADMINS="e2e_admin,smoke_admin" FADE_PUSH_ALLOW_LOCAL=true FADE_MAX_ACCOUNTS=1000 \
  RUST_LOG="${RUST_LOG:-fade_server=info}" server/target/debug/fade-server > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -sf "$NAPSACK_URL/api/config" >/dev/null && break; sleep 0.2; done

if [ "$1" = smoke ]; then
  "$PY" tests/smoke_test.py || { grep -E "WARN|ERROR" "$TMP/server.log" | tail -20; exit 1; }
else
  (cd tests/e2e && "$PY" "$(basename "$1")") || { echo "--- server warnings"; grep -E "WARN|ERROR" "$TMP/server.log" | tail -20; exit 1; }
fi
echo "screenshots: $NAPSACK_SHOTS"
