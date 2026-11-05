#!/usr/bin/env bash
# Owner only (napsack's Admin). Needs the owner's AWS credentials, access to
# the Terraform state, and an SSH key on the servers, set up privately; none
# of it is in this repository, and without it this stops at its first step.
#
# A local copy of the live database to look around in with any SQLite client.
# SQLite is a file, not a server, so there's no port to tunnel: this takes a
# consistent snapshot over the SSH tunnel (scripts/ssh.sh), opening the live
# file read-only (?mode=ro) so it never writes to or blocks production.
#
# Secrets never leave the server: the snapshot is made in memory there
# (/dev/shm), and before it's sent, everything that could unlock an account
# or a message is replaced with a placeholder (password and recovery hashes,
# wrapped private keys, session and invite hashes, push and passkey secrets,
# the server's own keys) along with every message's contents, which no one
# needs to look around. The page space they used is rewritten (VACUUM), so
# no trace is left in the file.
#
# The copy is still people's data (usernames, names, who's friends with
# whom, when). Account deletion promises to reach every copy within 30 days
# (docs/design/account-deletion.md), so copies here are deleted after 7 days
# each time this runs; delete them sooner when you're done.
#
#   scripts/db-copy.sh                     production
#   FADE_STACK=staging scripts/db-copy.sh  staging
#
# Then: sqlite3 -readonly <file>, or open it in a SQLite app.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="${FADE_DB_COPIES:-$HOME/.napsack-db-copies}"
mkdir -p "$DIR" && chmod 700 "$DIR"
find "$DIR" -name 'fade-*.db' -mtime +7 -delete

OUT="$DIR/fade-${FADE_STACK:-production}-$(date -u +%Y%m%dT%H%M%SZ).db"
echo "==> snapshot of ${FADE_STACK:-production} (read-only), secrets removed on the server"
scripts/ssh.sh "sudo python3 - /var/lib/fade/db/fade.db | gzip -c" 2>/dev/null <<'PY' | gunzip > "$OUT.part"
import os, sqlite3, sys, tempfile

# Replaced with "(hidden)" (or its length, for contents), never sent.
SECRETS = {
    "users": ["auth_hash", "wrapped_private_key", "recovery_hash", "recovery_wrapped_key"],
    "credential_history": ["auth_hash", "wrapped_private_key", "recovery_hash", "recovery_wrapped_key"],
    "sessions": ["token_hash"],
    "invites": ["token_hash"],
    "reset_codes": ["code_hash"],
    "passkeys": ["credential_id", "wrapped_key"],
    "push_subscriptions": ["session_hash", "endpoint", "p256dh", "auth"],
    "apns_devices": ["session_hash", "token"],
    "server_keys": ["value"],
    "group_message_keys": ["wrapped"],
    "group_edit_keys": ["wrapped"],
}
CONTENTS = {
    "messages": ["ciphertext"],
    "message_edits": ["ciphertext"],
    "reactions": ["ciphertext"],
    "group_messages": ["body"],
}

src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
with tempfile.TemporaryDirectory(dir="/dev/shm") as d:
    path = os.path.join(d, "copy.db")
    dst = sqlite3.connect(path)
    src.backup(dst)
    src.close()
    tables = {r[0] for r in dst.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    for spec, value in ((SECRETS, "'(hidden ' || rowid || ')'"),
                        (CONTENTS, "'(' || length({c}) || ' bytes)'")):
        for table, cols in spec.items():
            if table not in tables:
                continue
            present = {r[1] for r in dst.execute(f"PRAGMA table_info({table})")}
            for c in cols:
                if c in present:
                    dst.execute(f"UPDATE {table} SET {c} = {value.format(c=c)} WHERE {c} IS NOT NULL")
    dst.commit()
    dst.execute("PRAGMA journal_mode = DELETE")
    dst.execute("VACUUM")
    dst.close()
    with open(path, "rb") as f:
        sys.stdout.buffer.write(f.read())
PY

[ -s "$OUT.part" ] || { rm -f "$OUT.part"; echo "the snapshot came back empty: try scripts/ssh.sh on its own"; exit 1; }
CHECK=$(sqlite3 "$OUT.part" "PRAGMA integrity_check")
[ "$CHECK" = ok ] || { rm -f "$OUT.part"; echo "the copy failed its integrity check: $CHECK"; exit 1; }
mv "$OUT.part" "$OUT" && chmod 400 "$OUT"

echo "==> $OUT"
sqlite3 -readonly "$OUT" "SELECT 'users ' || (SELECT COUNT(*) FROM users) || ', friendships ' || (SELECT COUNT(*) FROM friendships) || ', messages ' || (SELECT COUNT(*) FROM messages)"
echo "    open it: sqlite3 -readonly \"$OUT\""
echo "    delete it when you're done; copies older than 7 days go on the next run"
