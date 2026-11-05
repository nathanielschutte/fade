#!/usr/bin/env bash
# Owner only (napsack's Admin). Needs the owner's AWS credentials, access to
# the Terraform state, and an SSH key on the servers, set up privately; none
# of it is in this repository, and without it this stops at its first step.
#
# Tell the running server to read the admin list (/<app>/admins) again
# (docs/implementation/roles.md). Same as System -> Roles -> Reload admin list.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/ssh.sh "sudo systemctl kill -s HUP fade && sleep 2 && sudo journalctl -u fade --since '-10 sec' --no-pager | grep -E 'admin list' || true"
