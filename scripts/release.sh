#!/usr/bin/env bash
# CI only: GitHub Actions runs it, with the short-lived AWS role each job gets
# (infra/github.tf). People don't run it; without that role it stops at its
# first step.
#
# The release pipeline's steps (docs/operations/releasing.md), run by GitHub
# Actions: .github/workflows/ci.yml (main → a release candidate on staging)
# and release-server.yml (a server-v* tag → a release on production).
#
#   release.sh staging-ran <sha>        succeed only if main's CI put this commit on staging
#                                       (its "Release candidate on staging" job passed)
#   release.sh build <build>            build the ARM64 server into dist/fade-server, and
#                                       print its sha256 (the record fetch-candidate checks)
#   release.sh candidate <build>        upload it as releases/main/fade-server-<build>,
#                                       make it staging's, keep the newest $KEEP
#   release.sh fetch-candidate <build> <sha>   download releases/main/fade-server-<build>, if
#                                       it's kept and its sha256 is what main's CI built
#   release.sh check-sha256 <sha256>    fail unless dist/fade-server has this sha256
#   release.sh publish <version>        upload dist/fade-server as releases/tags/fade-server-<version>
#                                       (never over an existing one; $BUILD as its build metadata)
#                                       and make it production's
#   release.sh backup <app>             back up the database on every <app> server first
#   release.sh update <app> <url> <build>   run fade-update on every <app> server, then
#                                       check <url> reports <build>
#   release.sh github-release <version> a GitHub Release for server-v<version>, its notes
#                                       the pull requests since the last server release
#
# Settings (environment): BUCKET, AWS_REGION; KEEP (candidates kept, 10);
# GITHUB_REPOSITORY and GH_TOKEN for staging-ran, fetch-candidate, and
# github-release. AWS credentials come from the job's role; each role can
# reach only its own servers and releases (infra/github.tf).
# Public CI logs: nothing printed here names an instance, a backup, or a count.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=aarch64-unknown-linux-musl
KEEP="${KEEP:-10}"
REPO="${GITHUB_REPOSITORY:-nathanielschutte/fade}"
# The job in ci.yml that builds each candidate, without any AWS role.
BUILD_JOB="Build the release candidate"
s3() { aws s3 "$@" --region "$AWS_REGION" --only-show-errors; }
exists() { aws s3api head-object --bucket "$BUCKET" --key "$1" --region "$AWS_REGION" >/dev/null 2>&1; }
sha256() { sha256sum "$1" | cut -d' ' -f1; }

# main's CI run that passed for commit <sha> (pushed to main), or nothing.
main_ci_run() {
  gh api "repos/$REPO/actions/workflows/ci.yml/runs?head_sha=$1&branch=main&event=push" \
    --jq '[.workflow_runs[] | select(.conclusion == "success")][0].id // empty'
}

# The sha256 that main's CI recorded when it built the candidate for commit
# <sha> (build <build>), or nothing if there's no record. The record is the
# "==> sha256" line `build` printed in the build job's own log. Only that job
# writes its log, and it has no AWS role; the staging role, which can replace
# anything in releases/main/, can't change it. So a candidate swapped in S3
# after it was built doesn't match. (Logs expire after 90 days; by then the
# candidate is long gone too.)
recorded_sha256() {
  local run job
  run=$(main_ci_run "$1")
  [ -n "$run" ] || return 0
  job=$(gh api "repos/$REPO/actions/runs/$run/jobs" --jq ".jobs[] | select(.name == \"$BUILD_JOB\") | .id")
  [ -n "$job" ] || return 0
  # curl, not gh: gh refuses output with terminal colours in it, as build logs have.
  { curl -sfL -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$REPO/actions/jobs/$job/logs" || true; } \
    | tr -d '\r' \
    | { grep -oE "==> sha256 [0-9a-f]{64} fade-server-$2\$" || true; } | awk '{ print $3 }' | sort -u
}

# Runs one shell command on every running server tagged App=<app>, through
# SSM, and fails unless it worked on all of them. Says how many servers, not
# which: CI's logs are public.
on_servers() {
  local app=$1 command=$2 ids cmd status n=0
  ids=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:App,Values=$app" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [ -n "$ids" ] || { echo "no running $app server"; exit 1; }
  # shellcheck disable=SC2086
  echo "==> on $(echo $ids | wc -w | tr -d ' ') $app server(s): $command"
  # shellcheck disable=SC2086
  cmd=$(aws ssm send-command --region "$AWS_REGION" --instance-ids $ids \
    --document-name AWS-RunShellScript --comment "release.sh on $app" \
    --parameters "$(jq -nc --arg c "$command" '{commands: [$c]}')" --query Command.CommandId --output text)
  for id in $ids; do
    n=$((n + 1))
    aws ssm wait command-executed --region "$AWS_REGION" --command-id "$cmd" --instance-id "$id" || true
    aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd" --instance-id "$id" \
      --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
    status=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd" --instance-id "$id" \
      --query Status --output text)
    [ "$status" = Success ] || { echo "failed on server $n: $status"; exit 1; }
  done
}

case "${1:-}" in
  staging-ran)
    # The rule (releasing.md): production only gets what staging ran. A tag on
    # a commit whose main CI failed, or that made no candidate (only ios/ or
    # docs changed), has nothing staging ran; 0.42.2 once shipped that way.
    SHA=$2
    RUN=$(main_ci_run "$SHA")
    if [ -z "$RUN" ]; then
      echo "refusing: main's CI didn't pass for $SHA, so staging never ran it. Tag a commit staging's /api/config shows."
      exit 1
    fi
    JOB=$(gh api "repos/$REPO/actions/runs/$RUN/jobs" --jq '.jobs[] | select(.name == "Release candidate on staging") | .conclusion')
    if [ "$JOB" != "success" ]; then
      echo "refusing: $SHA made no release candidate (${JOB:-no such job}), so staging never ran it. Tag a commit staging's /api/config shows."
      exit 1
    fi
    echo "==> staging ran $SHA (CI run $RUN)"
    ;;

  github-release)
    VERSION=$2
    TAG="server-v$VERSION"
    # Notes since the last server release, not the last tag of any kind (iOS ones will come).
    PREV=$(git describe --tags --abbrev=0 --match 'server-v*' "$TAG^" 2>/dev/null || true)
    gh release create "$TAG" --repo "$REPO" --title "napsack server $VERSION" \
      --generate-notes ${PREV:+--notes-start-tag "$PREV"} --latest --verify-tag
    ;;

  build)
    BUILD=$2
    # sqlx embeds migrations at compile time and cargo can miss a new file.
    touch server/src/db.rs
    (cd server && FADE_BUILD="$BUILD" cargo zigbuild --release --target "$TARGET")
    mkdir -p dist
    cp "server/target/$TARGET/release/fade-server" dist/fade-server
    ls -l dist/fade-server
    # The record a release checks the candidate against (fetch-candidate): this
    # line, in this job's own log. Kept beside the binary for the jobs after it.
    sha256 dist/fade-server > dist/fade-server.sha256
    echo "==> sha256 $(cat dist/fade-server.sha256) fade-server-$BUILD"
    ;;

  check-sha256)
    # dist/fade-server is the binary with this sha256 (handed from one job to the next).
    WANT=$2 GOT=$(sha256 dist/fade-server)
    [ "$GOT" = "$WANT" ] || { echo "refusing: dist/fade-server's sha256 is $GOT, not ${WANT:-(none given)}"; exit 1; }
    echo "==> dist/fade-server is $WANT"
    ;;

  candidate)
    BUILD=$2
    echo "==> release candidate $BUILD"
    s3 cp dist/fade-server "s3://$BUCKET/releases/main/fade-server-$BUILD" --metadata "build=$BUILD"
    # What staging runs (its server pulls this key; infra/staging/main.tf).
    s3 cp dist/fade-server "s3://$BUCKET/releases/main/fade-server" --metadata "build=$BUILD"
    # Keep the newest $KEEP candidates; releases (releases/tags/) are kept forever.
    # (The listing must work: an error stops the job rather than skipping the cleanup.)
    keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix releases/main/fade-server- --region "$AWS_REGION" \
      --query 'sort_by(Contents, &LastModified)[].Key' --output text)
    # shellcheck disable=SC2086
    old=$(printf '%s\n' $keys | grep -v '^None$' | head -n "-$KEEP" || true)
    for key in $old; do
      echo "    removing old candidate $key"
      aws s3 rm "s3://$BUCKET/$key" --region "$AWS_REGION" --only-show-errors
    done
    ;;

  fetch-candidate)
    # Exits 3 when there's nothing to promote (the workflow builds it again,
    # without the role), and 1 when the kept candidate isn't what main's CI
    # built: then it was replaced in S3, and nothing is released.
    BUILD=$2 SHA=$3
    mkdir -p dist
    if ! exists "releases/main/fade-server-$BUILD"; then
      echo "==> no kept candidate for $BUILD"
      exit 3
    fi
    WANT=$(recorded_sha256 "$SHA" "$BUILD")
    if [ -z "$WANT" ]; then
      echo "==> no record of what main's CI built for $BUILD: building it again instead"
      exit 3
    fi
    s3 cp "s3://$BUCKET/releases/main/fade-server-$BUILD" dist/fade-server
    GOT=$(sha256 dist/fade-server)
    if [ "$GOT" != "$WANT" ]; then
      rm -f dist/fade-server
      echo "refusing: releases/main/fade-server-$BUILD has sha256 $GOT, but main's CI built" $WANT
      echo "It was replaced after it was built. Release nothing until the owner finds out who wrote it."
      exit 1
    fi
    echo "$GOT" > dist/fade-server.sha256
    echo "==> using the candidate staging ran: releases/main/fade-server-$BUILD (sha256 $GOT, as main's CI built it)"
    ;;

  publish)
    VERSION=$2
    KEY="releases/tags/fade-server-$VERSION"
    # A release is never replaced: a fix is a new version.
    if exists "$KEY"; then echo "$KEY already exists: bump the version in server/Cargo.toml"; exit 1; fi
    echo "==> release $VERSION"
    # The commit it was built from rides along as metadata ($BUILD, from the workflow).
    s3 cp dist/fade-server "s3://$BUCKET/$KEY" --metadata "build=${BUILD:-unknown}"
    # What production runs (its servers pull this key, at boot and on fade-update).
    s3 cp dist/fade-server "s3://$BUCKET/releases/fade-server" --metadata "build=${BUILD:-unknown},version=$VERSION"
    ;;

  backup)
    # CLAUDE.md: a fresh backup right before deploying (the timer's job, run now).
    # Says only that it worked and its size: the status file also has the
    # backup's key and row counts, which don't belong in public CI logs.
    on_servers "$2" "systemctl start fade-backup && f=/var/lib/fade/backups/last.json && grep -qE '.ok.: true' \$f && echo backup ok: \$(grep -oE '.bytes.: [0-9]+' \$f | grep -oE '[0-9]+') bytes"
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
    awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0"
    exit 2
    ;;
esac
