#!/usr/bin/env bash
# Set who's an Admin (docs/implementation/roles.md): usernames, comma-separated.
#   scripts/set-admins.sh nate,liana
# Stored as the SSM parameter /<app>/admins (SecureString), outside Terraform,
# so the list isn't in source control or Terraform state. Then reload it on
# the server: scripts/reload-admins.sh (or System -> Roles -> Reload admin list).
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: scripts/set-admins.sh user1,user2"; exit 1; }
case "$1" in *[!A-Za-z0-9_.,]*) echo "usernames are letters, digits, _ and . separated by commas"; exit 1;; esac

REGION=$(terraform -chdir=infra output -raw region)
APP=$(terraform -chdir=infra output -raw app_name 2>/dev/null || echo fade)
MSYS_NO_PATHCONV=1 aws ssm put-parameter --region "$REGION" --name "/$APP/admins" \
  --type SecureString --value "$1" --overwrite >/dev/null
echo "==> /$APP/admins updated ($(echo "$1" | tr ',' '\n' | grep -c .) admins). Now: scripts/reload-admins.sh"
