#!/usr/bin/env bash
# Runs one browser test against a fresh server and throwaway database: the
# quick loop while working on a feature. scripts/test.sh runs everything.
#
#   bash scripts/test-one.sh test_profile.py      (a file in tests/e2e/)
#   bash scripts/test-one.sh smoke                (the API smoke test)
#
# Same setup as scripts/test.sh (scripts/test-env.sh; docs/onboarding.md).
# Prints where the screenshots went, and the server's warnings if the test fails.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: $0 <test_file.py in tests/e2e | smoke>"; exit 2; }

PORT="${PORT:-8098}"
# Info and up, so a failure can show the server's warnings.
export RUST_LOG="${RUST_LOG:-fade_server=info}"
. scripts/test-env.sh

(cd server && cargo build --quiet)
trap 'kill ${SERVER_PID:-} 2>/dev/null || true' EXIT
start_server

warnings() { echo "--- server warnings"; grep -E "WARN|ERROR" "$TMP/server.log" | tail -20; exit 1; }
if [ "$1" = smoke ]; then
  "$PY" tests/smoke_test.py || warnings
else
  (cd tests/e2e && "$PY" "$(basename "$1")") || warnings
fi
echo "screenshots: $NAPSACK_SHOTS"
