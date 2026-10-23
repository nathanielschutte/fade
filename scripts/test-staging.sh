#!/usr/bin/env bash
# The smoke test and the browser tests against staging (docs/staging.md):
# a real deployment, behind Caddy, on AWS. Never production: it refuses any
# address that isn't staging's.
#   scripts/test-staging.sh            # everything
#   scripts/test-staging.sh --no-browser
# The machine running it must be in staging's exempt_addresses
# (infra/staging/terraform.tfvars), or per-address limits will throttle it.
set -euo pipefail
cd "$(dirname "$0")/.."

URL=$(terraform -chdir=infra/staging output -raw url)
case "$URL" in https://staging.*) ;; *) echo "refusing: $URL isn't staging"; exit 1;; esac
INVITE=$(sed -n 's/^invite_code *= *"\(.*\)"/\1/p' infra/staging/terraform.tfvars)
[ -n "$INVITE" ] || { echo "no invite_code in infra/staging/terraform.tfvars"; exit 1; }

VENV_PY="$HOME/.venvs/napsack-tests/bin/python"
if [ -n "${PYTHON:-}" ]; then PY="$PYTHON"
elif [ -x "$VENV_PY" ]; then PY="$VENV_PY"
else PY="$(command -v python3 || command -v python)"; fi
if [ "$(uname -s)" = Linux ] && ! command -v google-chrome >/dev/null; then
  export E2E_CHROME="${E2E_CHROME:-bundled}"
  if grep -qE '^VERSION_ID="(2[6-9]|[3-9][0-9])' /etc/os-release 2>/dev/null; then
    export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE="${PLAYWRIGHT_HOST_PLATFORM_OVERRIDE:-ubuntu24.04-x64}"
  fi
fi

export NAPSACK_URL="$URL" NAPSACK_INVITE="$INVITE" NAPSACK_ADMIN=e2e_admin NAPSACK_REMOTE=1
export NAPSACK_SHOTS="${NAPSACK_SHOTS:-$(mktemp -d)/shots}"
echo "==> $URL is running build $(curl -sf "$URL/api/config" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p')"

echo "==> API smoke test"
"$PY" tests/smoke_test.py

[ "${1:-}" = "--no-browser" ] && exit 0
for t in tests/e2e/test_*.py; do
  case "$t" in
    */test_dev_reload.py) echo "==> $t: skipped (staging runs a release build)"; continue ;;
  esac
  echo "==> $t"
  (cd tests/e2e && "$PY" "$(basename "$t")")
done
echo "screenshots: $NAPSACK_SHOTS"
