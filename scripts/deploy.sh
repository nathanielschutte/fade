#!/usr/bin/env bash
# Build an ARM64 static binary, push it to the box over SSH, and restart.
# Needs: cargo-zigbuild (cargo install cargo-zigbuild; pip install ziglang),
#        rustup target add aarch64-unknown-linux-musl, AWS CLI, terraform, ssh.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=aarch64-unknown-linux-musl
out() { terraform -chdir=infra output -raw "$1"; }
BUCKET=$(out artifacts_bucket)
REGION=$(out region)
HOST=$(out ssh_host)
CONF=infra/.ssh_config
out ssh_config > "$CONF"

echo "==> building $TARGET"
(cd server && cargo zigbuild --release --target "$TARGET")
BIN="server/target/$TARGET/release/fade-server"
ls -lh "$BIN"

echo "==> copying to $HOST"
scp -F "$CONF" -q "$BIN" "$HOST:fade-server.new"

echo "==> installing and restarting"
ssh -F "$CONF" "$HOST" sudo /usr/local/bin/fade-update '~/fade-server.new'

# A replaced instance boots from whatever release is in S3, so keep it current.
echo "==> saving release to s3://$BUCKET/releases/"
aws s3 cp "$BIN" "s3://$BUCKET/releases/fade-server" --region "$REGION" --only-show-errors

echo "==> $(out url)"
