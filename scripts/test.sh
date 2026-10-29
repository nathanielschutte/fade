#!/usr/bin/env bash
# Build the server, run it on a throwaway database, and run every test against it:
# unit tests, crypto vector checks, the API smoke test, and (unless --no-browser)
# the browser tests, which include shared/crypto's checks against the pinned vectors.
# Prints how long each part took, and the total, at the end (even when one fails).
#
#   scripts/test.sh               everything
#   scripts/test.sh --no-browser  skip Playwright (no Chrome needed)
#
# Needs: cargo, Node.js 22+, python3 with tests/requirements.txt installed, and
# Playwright's Chromium (`python3 -m playwright install chromium`); Google Chrome
# for the video test. Works on Linux, macOS, and CI; on Windows, in WSL (setup:
# docs/onboarding.md). The browser tests run several at a time (tests/e2e/run.py;
# E2E_JOBS=1 for one at a time).
set -euo pipefail
cd "$(dirname "$0")/.."

BROWSER=1
[ "${1:-}" = "--no-browser" ] && BROWSER=0
PORT="${PORT:-8099}"
. scripts/test-env.sh

# Seconds, to the millisecond: bash 5's clock, else Perl's (macOS ships bash 3.2).
now() {
  if [ -n "${EPOCHREALTIME:-}" ]; then echo "${EPOCHREALTIME/,/.}"
  else perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; fi
}
STARTED="$(now)"
SECTION=""
SECTION_START=""
TIMES=""
# `section "name"` ends the one before (recording its time) and starts the next.
section() {
  local t
  t="$(now)"
  if [ -n "$SECTION" ]; then
    TIMES="$TIMES$(awk -v a="$SECTION_START" -v b="$t" -v n="$SECTION" 'BEGIN { printf "%7.1fs  %s", b - a, n }')"$'\n'
  fi
  SECTION="$1"
  SECTION_START="$t"
  if [ -n "$1" ]; then echo "==> $1"; fi
}
finish() {
  local code=$?
  kill "${SERVER_PID:-}" 2>/dev/null || true
  section ""
  echo
  echo "==> times"
  printf "%s" "$TIMES"
  awk -v a="$STARTED" -v b="$(now)" 'BEGIN { printf "%7.1fs  total\n", b - a }'
  if [ "$code" -eq 0 ]; then echo "==> all tests passed"; else echo "==> failed"; fi
}
trap finish EXIT

section "unit tests"
(cd server && cargo test --quiet)

section "crypto vectors (independent implementation)"
for check in tests/vectors/check_*.py; do "$PY" "$check"; done

section "shared crypto against the vectors (Node)"
# Node installed with nvm isn't loaded by non-interactive shells.
if ! command -v node >/dev/null && [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi
command -v node >/dev/null || { echo "Node.js is required (see CLAUDE.md, Environment notes)"; exit 1; }
node --test "shared/**/*.test.js"

section "health monitor (decisions, with AWS faked)"
"$PY" tests/health_monitor_test.py

section "building server"
(cd server && cargo build --quiet)
start_server

section "API smoke test"
"$PY" tests/smoke_test.py

section "unopened pics survive a restart"
export NAPSACK_RESTART_STATE="$TMP/restart.json"
"$PY" tests/restart_test.py before
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
start_server
"$PY" tests/restart_test.py after

if [ "$BROWSER" = 1 ]; then
  section "browser tests"
  "$PY" tests/e2e/run.py
  echo "screenshots: $NAPSACK_SHOTS"
fi
