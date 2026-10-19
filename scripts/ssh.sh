#!/usr/bin/env bash
# SSH to the box. Extra args pass through: scripts/ssh.sh journalctl -u fade -f
set -euo pipefail
cd "$(dirname "$0")/.."

CONF=infra/.ssh_config
terraform -chdir=infra output -raw ssh_config > "$CONF"
exec ssh -F "$CONF" "$(terraform -chdir=infra output -raw ssh_host)" "$@"
