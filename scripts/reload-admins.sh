#!/usr/bin/env bash
# Tell the running server to read the admin list (/<app>/admins) again
# (docs/roles.md). Same as System -> Roles -> Reload admin list.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/ssh.sh "sudo systemctl kill -s HUP fade && sleep 2 && sudo journalctl -u fade --since '-10 sec' --no-pager | grep -E 'admin list' || true"
