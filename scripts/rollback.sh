#!/usr/bin/env bash
# Put an earlier production build back into service.
#
#   scripts/rollback.sh              list the builds kept in S3
#   scripts/rollback.sh 0.31.0       roll back to a release (releases/tags/)
#   scripts/rollback.sh 0.31.0-6b3c483   or to a hotfix (releases/hotfix/)
#
# Works because migrations are additive and the server ignores ones it
# doesn't know (docs/operations/releasing.md). Afterwards, a new release tag
# is the way forward again. Needs: AWS CLI, terraform, ssh.
set -euo pipefail
cd "$(dirname "$0")/.."

out() { terraform -chdir=infra output -raw "$1"; }
BUCKET=$(out artifacts_bucket)
REGION=$(out region)
HOST=$(out ssh_host)
CONF=infra/.ssh_config
out ssh_config > "$CONF"

list() {
  aws s3 ls "s3://$BUCKET/$1" --region "$REGION" \
    | awk '$4 ~ /^fade-server-/ { sub("fade-server-", "", $4); print "  " $1 " " $2 "  " $4 }'
}
if [ $# -eq 0 ]; then
  echo "Releases (releases/tags/, newest last):"; list releases/tags/
  echo "Hotfixes (releases/hotfix/):"; list releases/hotfix/
  exit 0
fi

KEY=""
for k in "releases/tags/fade-server-$1" "releases/hotfix/fade-server-$1"; do
  if aws s3 ls "s3://$BUCKET/$k" --region "$REGION" >/dev/null 2>&1; then KEY=$k; break; fi
done
[ -n "$KEY" ] || { echo "no build $1 in S3 (run without arguments to list them)"; exit 1; }

echo "==> making $KEY what production runs"
aws s3 cp "s3://$BUCKET/$KEY" "s3://$BUCKET/releases/fade-server" --region "$REGION" --only-show-errors

echo "==> installing on $HOST"
ssh -F "$CONF" "$HOST" sudo /usr/local/bin/fade-update

URL=$(out url)
echo "==> $URL is running build $(curl -sf "$URL/api/config" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p')"
