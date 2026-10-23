#!/usr/bin/env bash
# Proves the newest database backup restores: downloads it, checks its
# integrity, and compares its row counts with production. Read-only: it never
# touches production data. Run it after backup changes and now and then
# (docs/operations/backups.md keeps a log). Needs: AWS CLI, terraform, python3, ssh.
#
#   scripts/restore-drill.sh            newest backup
#   scripts/restore-drill.sh <s3 key>   a specific one, e.g. db/2026/10/20/fade-...db.gz
set -euo pipefail
cd "$(dirname "$0")/.."

out() { terraform -chdir=infra output -raw "$1"; }
BUCKET=$(out backups_bucket)
REGION=$(out region)
PY="$(command -v python3 || command -v python)"

KEY="${1:-$(aws s3 ls "s3://$BUCKET/db/" --recursive --region "$REGION" | sort | tail -1 | awk '{print $4}')}"
[ -n "$KEY" ] || { echo "no backups in s3://$BUCKET/db/ yet"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
command -v cygpath >/dev/null && TMP="$(cygpath -m "$TMP")"
echo "==> downloading $KEY"
aws s3 cp "s3://$BUCKET/$KEY" "$TMP/backup.db.gz" --region "$REGION" --only-show-errors
gunzip "$TMP/backup.db.gz"

echo "==> checking the restored copy"
BACKUP_COUNTS=$("$PY" - "$TMP/backup.db" <<'PY'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
check = c.execute("PRAGMA integrity_check").fetchone()[0]
if check != "ok":
    sys.exit(f"integrity check failed: {check}")
print(json.dumps({t: c.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                  for t in ("users", "friendships", "messages")}))
PY
)
echo "    integrity ok, $BACKUP_COUNTS"

echo "==> comparing with production (read-only)"
LIVE_COUNTS=$(scripts/ssh.sh "sudo python3 -c \"import json, sqlite3; c=sqlite3.connect('file:/var/lib/fade/db/fade.db?mode=ro', uri=True); print(json.dumps({t: c.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0] for t in ('users','friendships','messages')}))\"" 2>/dev/null | tail -1)
echo "    production: $LIVE_COUNTS"

# Production can only have grown since the backup (rows are never deleted),
# except friendships, which an unfriend removes.
"$PY" - "$BACKUP_COUNTS" "$LIVE_COUNTS" <<'PY'
import json, sys
backup, live = json.loads(sys.argv[1]), json.loads(sys.argv[2])
for t in ("users", "messages"):
    if backup[t] > live[t]:
        sys.exit(f"backup has more {t} ({backup[t]}) than production ({live[t]}): investigate")
print("==> restore drill passed")
PY
