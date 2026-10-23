#!/usr/bin/env bash
# Put an earlier server build back into service.
#
#   scripts/rollback.sh             list the builds kept in S3
#   scripts/rollback.sh 0.2.0-3f9c1a2   roll back to that build
#
# Works because migrations are additive and the server ignores ones it
# doesn't know (docs/operations/releasing.md). Needs: AWS CLI, terraform, ssh.
set -euo pipefail
cd "$(dirname "$0")/.."

out() { terraform -chdir=infra output -raw "$1"; }
BUCKET=$(out artifacts_bucket)
REGION=$(out region)
HOST=$(out ssh_host)
CONF=infra/.ssh_config
out ssh_config > "$CONF"

if [ $# -eq 0 ]; then
  echo "Builds in s3://$BUCKET/releases/ (newest last):"
  aws s3 ls "s3://$BUCKET/releases/" --region "$REGION" \
    | awk '$4 ~ /^fade-server-/ { sub("fade-server-", "", $4); print "  " $1 " " $2 "  " $4 }'
  exit 0
fi

KEY="releases/fade-server-$1"
aws s3 ls "s3://$BUCKET/$KEY" --region "$REGION" >/dev/null || { echo "no build $1 in S3"; exit 1; }

echo "==> making $1 the current release"
aws s3 cp "s3://$BUCKET/$KEY" "s3://$BUCKET/releases/fade-server" --region "$REGION" --only-show-errors

echo "==> installing on $HOST"
ssh -F "$CONF" "$HOST" sudo /usr/local/bin/fade-update

URL=$(out url)
echo "==> $URL is running build $(curl -sf "$URL/api/config" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p')"
