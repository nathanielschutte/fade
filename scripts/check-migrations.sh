#!/usr/bin/env bash
# Runs the current server, and so its migrations, against a copy of the newest
# production backup, then checks that no rows were lost and the database is
# intact. Never touches production. Run before releasing any new migration
# (CLAUDE.md). Needs: AWS CLI, terraform, cargo, python3, curl. Run in WSL.
set -euo pipefail
cd "$(dirname "$0")/.."

out() { terraform -chdir=infra output -raw "$1"; }
BUCKET=$(out backups_bucket)
REGION=$(out region)
KEY=$(aws s3 ls "s3://$BUCKET/db/" --recursive --region "$REGION" | sort | tail -1 | awk '{print $4}')
[ -n "$KEY" ] || { echo "no backups yet"; exit 1; }

W=$(mktemp -d)
trap 'kill "${PID:-}" 2>/dev/null || true; rm -rf "$W"' EXIT
aws s3 cp "s3://$BUCKET/$KEY" "$W/prod.db.gz" --region "$REGION" --only-show-errors
gunzip "$W/prod.db.gz"

cat > "$W/count.py" <<'PY'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
tables = [r[0] for r in c.execute(
    "SELECT name FROM sqlite_master WHERE type = 'table'"
    " AND substr(name, 1, 1) != '_' AND name NOT LIKE 'sqlite%'")]
print(json.dumps({t: c.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in sorted(tables)}))
PY
BEFORE=$(python3 "$W/count.py" "$W/prod.db")
echo "==> copy of $KEY"
echo "    before: $BEFORE"

(cd server && cargo build --quiet)
FADE_BIND=127.0.0.1:8093 FADE_DATABASE_URL="sqlite://$W/prod.db" ./server/target/debug/fade-server >"$W/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 50); do curl -sf http://127.0.0.1:8093/api/config >/dev/null && break; sleep 0.2; done
curl -sf http://127.0.0.1:8093/api/config >/dev/null || { cat "$W/server.log"; echo "server didn't start on the copy"; exit 1; }
kill "$PID"; wait "$PID" 2>/dev/null || true

AFTER=$(python3 "$W/count.py" "$W/prod.db")
echo "    after:  $AFTER"
python3 - "$W/prod.db" "$BEFORE" "$AFTER" <<'PY'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
before, after = json.loads(sys.argv[2]), json.loads(sys.argv[3])
for table, n in before.items():
    if after.get(table, 0) < n:
        sys.exit(f"{table} lost rows: {n} -> {after.get(table)}")
assert c.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "integrity check failed"
print("    migrations:", [r[0] for r in c.execute("SELECT version FROM _sqlx_migrations")])
print("==> migrations are safe on a copy of production")
PY
