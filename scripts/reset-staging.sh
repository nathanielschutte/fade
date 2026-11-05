#!/usr/bin/env bash
# Owner only (napsack's Admin). Needs the owner's AWS credentials, access to
# staging's Terraform state and its terraform.tfvars, and an SSH key on the
# servers, set up privately; none of it is in this repository, and without it
# this stops at its first step.
#
# Resets staging's data (docs/operations/staging.md, "Resetting staging"):
# every account, message, and pic on staging is set aside, the server starts
# on an empty database, and the seed (scripts/seed/seed.mjs) fills it with a
# few friends and their chats, encrypted as the apps do it. Never production:
# it refuses any address that isn't staging's, the same way test-staging.sh
# does, and only ever connects to staging's server.
#   scripts/reset-staging.sh          # says what it would do
#   scripts/reset-staging.sh --yes    # does it
# The one previous copy is kept on the server (/var/lib/fade/db/before-reset/,
# replacing any older one). The machine running it should be in staging's
# exempt_addresses (infra/staging/terraform.tfvars), as for test-staging.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

URL=$(terraform -chdir=infra/staging output -raw url)
case "$URL" in https://staging.*) ;; *) echo "refusing: $URL isn't staging"; exit 1;; esac
INVITE=$(sed -n 's/^invite_code *= *"\(.*\)"/\1/p' infra/staging/terraform.tfvars)
[ -n "$INVITE" ] || { echo "no invite_code in infra/staging/terraform.tfvars"; exit 1; }
# The seeded people's password: staging's own, as for test-staging.sh.
PASSWORD=$(sed -n 's/^test_password *= *"\(.*\)"/\1/p' infra/staging/terraform.tfvars)
[ -n "$PASSWORD" ] || { echo "no test_password in infra/staging/terraform.tfvars"; exit 1; }
if ! command -v node >/dev/null && [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi
command -v node >/dev/null || { echo "Node.js is required for the seed (docs/onboarding.md)"; exit 1; }
LOADTEST="tests/.loadtest-${URL#https://}.json"

cat <<EOF
This resets $URL:
  - stops the server, and moves its database and unopened pics to
    /var/lib/fade/db/before-reset/ (replacing the copy from the last reset)
  - starts it on an empty database, and seeds it (scripts/seed/seed.mjs):
    e2e_admin and six friends, their chats, two groups, a pic waiting
  - deletes $LOADTEST here, since its accounts will be gone
Every account on staging, and everything in it, goes. Production isn't touched.
EOF
if [ "${1:-}" != "--yes" ]; then
  echo "Run again with --yes to do it."
  exit 2
fi

echo "==> emptying staging"
# Over SSM, as root, on staging's machine only (FADE_STACK=staging). The metrics
# history (metrics.db) stays: it isn't anyone's data.
FADE_STACK=staging scripts/ssh.sh "sudo bash -s" <<'REMOTE'
set -euo pipefail
DB=/var/lib/fade/db
systemctl stop fade
rm -rf "$DB/before-reset"
mkdir -m 0700 "$DB/before-reset"
for f in fade.db fade.db-wal fade.db-shm pics; do
  if [ -e "$DB/$f" ]; then mv "$DB/$f" "$DB/before-reset/"; fi
done
systemctl start fade
echo "set aside: $(du -sh "$DB/before-reset" | cut -f1)"
REMOTE

echo "==> waiting for $URL"
for _ in $(seq 1 60); do
  curl -sf "$URL/api/health" >/dev/null && break
  sleep 1
done
curl -sf "$URL/api/health" >/dev/null || { echo "staging didn't come back: FADE_STACK=staging scripts/ssh.sh \"sudo journalctl -u fade -n 50\""; exit 1; }

echo "==> seeding"
NAPSACK_INVITE="$INVITE" NAPSACK_PASSWORD="$PASSWORD" node scripts/seed/seed.mjs --url "$URL"

if [ -e "$LOADTEST" ]; then
  rm "$LOADTEST"
  echo "deleted $LOADTEST: its accounts are gone (tests/load_test.py makes new ones)"
fi
echo "staging is reset: $URL"
