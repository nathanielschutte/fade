#!/usr/bin/env bash
# Build an ARM64 static binary, push it to the box over SSH, and restart.
# The normal path is a tagged release through GitHub Actions (docs/operations/releasing.md);
# this script is for hotfixes and for when CI is unavailable.
# Needs: cargo-zigbuild (cargo install cargo-zigbuild; pip install ziglang),
#        rustup target add aarch64-unknown-linux-musl, AWS CLI, terraform, ssh.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=aarch64-unknown-linux-musl
# FADE_STACK=staging deploys to staging (infra/staging; docs/operations/staging.md) instead.
TF="infra${FADE_STACK:+/$FADE_STACK}"
out() { terraform -chdir="$TF" output -raw "$1"; }
BUCKET=$(out artifacts_bucket)
REGION=$(out region)
HOST=$(out ssh_host)
# Production's releases live in releases/; staging's in releases/staging/, never production's.
PREFIX=$(out release_prefix 2>/dev/null || echo releases)
CONF="$TF/.ssh_config"
out ssh_config > "$CONF"

# The build id shows in /api/config and the admin panel, so you can always tell what's live.
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' server/Cargo.toml | head -1)
BUILD=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain -- server)" ]; then
  BUILD="$BUILD-dirty"
  echo "warning: deploying uncommitted server changes (build $BUILD)"
fi

# sqlx embeds migrations at compile time and cargo can miss a new file;
# touching the file that embeds them forces a fresh copy.
touch server/src/db.rs
echo "==> building $VERSION ($BUILD) for $TARGET"
(cd server && FADE_BUILD="$BUILD" cargo zigbuild --release --target "$TARGET")
BIN="server/target/$TARGET/release/fade-server"
ls -lh "$BIN"

echo "==> copying to $HOST"
scp -F "$CONF" -q "$BIN" "$HOST:fade-server.new"

echo "==> installing and restarting"
ssh -F "$CONF" "$HOST" sudo /usr/local/bin/fade-update '~/fade-server.new'

# A replaced instance boots from <prefix>/fade-server, so keep it current.
# The versioned copy is for rollbacks: scripts/rollback.sh <version>-<build>.
echo "==> saving release to s3://$BUCKET/$PREFIX/"
aws s3 cp "$BIN" "s3://$BUCKET/$PREFIX/fade-server-$VERSION-$BUILD" --region "$REGION" --only-show-errors
aws s3 cp "$BIN" "s3://$BUCKET/$PREFIX/fade-server" --region "$REGION" --only-show-errors

URL=$(out url)
LIVE=$(curl -sf "$URL/api/config" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p')
echo "==> $URL is running build ${LIVE:-unknown}"
[ "$LIVE" = "$BUILD" ] || { echo "error: expected build $BUILD"; exit 1; }
# Development live reload is compiled out of release builds (server/src/web.rs).
DEV=$(curl -s -o /dev/null -w '%{http_code}' "$URL/dev/changes")
[ "$DEV" = 404 ] || { echo "error: $URL answers /dev/changes ($DEV): a debug build is live"; exit 1; }
