#!/usr/bin/env bash
# SSH to the box. Extra args pass through: scripts/ssh.sh journalctl -u fade -f
set -euo pipefail
cd "$(dirname "$0")/.."

# FADE_STACK=staging: staging's server (infra/staging; docs/operations/staging.md).
TF="infra${FADE_STACK:+/$FADE_STACK}"
CONF="$TF/.ssh_config"
terraform -chdir="$TF" output -raw ssh_config > "$CONF"
exec ssh -F "$CONF" "$(terraform -chdir="$TF" output -raw ssh_host)" "$@"
