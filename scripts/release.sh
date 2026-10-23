#!/usr/bin/env bash
# The release pipeline's steps (docs/operations/releasing.md), run by GitHub
# Actions: .github/workflows/ci.yml (main → a release candidate on staging)
# and release-server.yml (a server-v* tag → a release on production).
#
#   release.sh build <build>            build the ARM64 server into dist/fade-server
#   release.sh candidate <build>        upload it as releases/main/fade-server-<build>,
#                                       make it staging's, keep the newest $KEEP
#   release.sh fetch-candidate <build>  download releases/main/fade-server-<build>, if it's kept
#   release.sh publish <version>        upload dist/fade-server as releases/tags/fade-server-<version>
#                                       (never over an existing one) and make it production's
#   release.sh backup <app>             back up the database on every <app> server first
#   release.sh update <app> <url> <build>   run fade-update on every <app> server, then
#                                       check <url> reports <build>
#
# Settings (environment): BUCKET, AWS_REGION; KEEP (candidates kept, 10).
# AWS credentials come from the job's role; each role can reach only its own
# servers and releases (infra/github.tf).
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=aarch64-unknown-linux-musl
KEEP="${KEEP:-10}"
s3() { aws s3 "$@" --region "$AWS_REGION" --only-show-errors; }
exists() { aws s3api head-object --bucket "$BUCKET" --key "$1" --region "$AWS_REGION" >/dev/null 2>&1; }

# Runs one shell command on every running server tagged App=<app>, through
# SSM, and fails unless it worked on all of them.
on_servers() {
  local app=$1 command=$2 ids cmd status
  ids=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:App,Values=$app" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [ -n "$ids" ] || { echo "no running $app server"; exit 1; }
  echo "==> on $app ($ids): $command"
  # shellcheck disable=SC2086
  cmd=$(aws ssm send-command --region "$AWS_REGION" --instance-ids $ids \
    --document-name AWS-RunShellScript --comment "release.sh on $app" \
    --parameters "commands=[\"$command\"]" --query Command.CommandId --output text)
  for id in $ids; do
    aws ssm wait command-executed --region "$AWS_REGION" --command-id "$cmd" --instance-id "$id" || true
    aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd" --instance-id "$id" \
      --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
    status=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd" --instance-id "$id" \
      --query Status --output text)
    [ "$status" = Success ] || { echo "failed on $id: $status"; exit 1; }
  done
}

case "${1:-}" in
  build)
    BUILD=$2
    # sqlx embeds migrations at compile time and cargo can miss a new file.
    touch server/src/db.rs
    (cd server && FADE_BUILD="$BUILD" cargo zigbuild --release --target "$TARGET")
    mkdir -p dist
    cp "server/target/$TARGET/release/fade-server" dist/fade-server
    ls -l dist/fade-server
    ;;

  candidate)
    BUILD=$2
    echo "==> release candidate $BUILD"
    s3 cp dist/fade-server "s3://$BUCKET/releases/main/fade-server-$BUILD"
    # What staging runs (its server pulls this key; infra/staging/main.tf).
    s3 cp dist/fade-server "s3://$BUCKET/releases/main/fade-server"
    # Keep the newest $KEEP candidates; releases (releases/tags/) are kept forever.
    old=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix releases/main/fade-server- --region "$AWS_REGION" \
      --query 'sort_by(Contents, &LastModified)[].Key' --output text | tr '\t' '\n' | grep -v '^None$' | head -n "-$KEEP" || true)
    for key in $old; do
      echo "    removing old candidate $key"
      aws s3 rm "s3://$BUCKET/$key" --region "$AWS_REGION" --only-show-errors
    done
    ;;

  fetch-candidate)
    BUILD=$2
    mkdir -p dist
    if exists "releases/main/fade-server-$BUILD"; then
      s3 cp "s3://$BUCKET/releases/main/fade-server-$BUILD" dist/fade-server
      echo "==> using the candidate staging ran: releases/main/fade-server-$BUILD"
    else
      echo "==> no kept candidate for $BUILD"
      exit 3
    fi
    ;;

  publish)
    VERSION=$2
    KEY="releases/tags/fade-server-$VERSION"
    # A release is never replaced: a fix is a new version.
    if exists "$KEY"; then echo "$KEY already exists: bump the version in server/Cargo.toml"; exit 1; fi
    echo "==> release $VERSION"
    s3 cp dist/fade-server "s3://$BUCKET/$KEY"
    # What production runs (its servers pull this key, at boot and on fade-update).
    s3 cp dist/fade-server "s3://$BUCKET/releases/fade-server"
    ;;

  backup)
    # CLAUDE.md: a fresh backup right before deploying (the timer's job, run now).
    on_servers "$2" "systemctl start fade-backup && cat /var/lib/fade/backups/last.json"
    ;;

  update)
    APP=$2 URL=$3 BUILD=$4
    on_servers "$APP" "/usr/local/bin/fade-update"
    for _ in $(seq 1 30); do
      LIVE=$(curl -sf "$URL/api/config" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p' || true)
      if [ "$LIVE" = "$BUILD" ]; then echo "==> $URL is running $BUILD"; exit 0; fi
      sleep 2
    done
    echo "expected build $BUILD at $URL, live is ${LIVE:-unreachable}"
    exit 1
    ;;

  *)
    sed -n '2,20p' "$0"
    exit 2
    ;;
esac
