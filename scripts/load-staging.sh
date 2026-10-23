#!/usr/bin/env bash
# Load test staging (docs/staging.md; tests/load_test.py). Never production.
#   scripts/load-staging.sh --stages 50,100,200 --rate 6 --duration 60
set -euo pipefail
cd "$(dirname "$0")/.."
URL=$(terraform -chdir=infra/staging output -raw url)
case "$URL" in https://staging.*) ;; *) echo "refusing: $URL isn't staging"; exit 1;; esac
INVITE=$(sed -n 's/^invite_code *= *"\(.*\)"/\1/p' infra/staging/terraform.tfvars)
VENV_PY="$HOME/.venvs/napsack-tests/bin/python"
PY="${PYTHON:-$( [ -x "$VENV_PY" ] && echo "$VENV_PY" || command -v python3 )}"
NAPSACK_URL="$URL" NAPSACK_INVITE="$INVITE" "$PY" tests/load_test.py "$@"
