# Backups and restores

User data is never deleted ([CLAUDE.md](../CLAUDE.md)), and it lives in one SQLite file on one disk. This is how it's protected, and how to get it back.

## What runs

| | Database backups | Disk snapshots |
|---|---|---|
| What | A consistent copy of `fade.db` (SQLite's online backup API, so the app keeps running), integrity-checked, gzipped | The whole data volume: database, TLS certificates, SSH host keys, backup status |
| How often | Hourly (systemd timer `fade-backup.timer`) | Daily at 09:00 UTC (AWS Data Lifecycle Manager) |
| Where | `s3://fade-backups-<account>-us-east-1/db/YYYY/MM/DD/fade-<time>.db.gz` | EBS snapshots tagged `Backup=fade-daily` |
| Kept | Forever. After 30 days they move to cheaper storage (Glacier Instant Retrieval), still readable in milliseconds | 30 days |
| Protected by | Versioned bucket with `prevent_destroy`; the server may only add objects, never delete or overwrite | AWS retention policy |
| Status | `/admin` → Server → Last backup (from `/var/lib/fade/backups/last.json`); the job's journal: `journalctl -u fade-backup` | `aws ec2 describe-snapshots --filters Name=tag:Backup,Values=fade-daily` |

A backup older than two hours shows as **Overdue** in the admin panel, and a failed one shows its error.

## Proving they work

`scripts/restore-drill.sh` downloads the newest backup (or a key you name), checks its integrity, and compares its row counts with production, all read-only. Run it after any change to backups, and every month or so. Log the result below.

## Restoring the database

Only for real data loss or corruption, and only with the user's go-ahead. A restore brings back the database as of the backup's time; anything written after that is not in it, so the current file is set aside rather than deleted.

1. **Snapshot the data volume first** (CLAUDE.md Rule 1), so this restore can be undone too.
2. **Pick and check the backup:** `scripts/restore-drill.sh <key>` confirms it's intact. Download it again into `restored.db` (`aws s3 cp s3://<bucket>/<key> - | gunzip > restored.db`).
3. **Copy it to the server:** `scp -F infra/.ssh_config restored.db fade:`
4. **Swap it in, keeping the old file:**
   ```sh
   scripts/ssh.sh 'set -e
     sudo systemctl stop fade
     d=/var/lib/fade/db/replaced-$(date -u +%Y%m%dT%H%M%SZ); sudo install -d -o fade -g fade -m 0750 $d
     sudo mv /var/lib/fade/db/fade.db* $d/
     sudo install -o fade -g fade -m 0640 ~/restored.db /var/lib/fade/db/fade.db
     sudo systemctl start fade'
   ```
5. **Verify:** row counts (CLAUDE.md), the site loads, and `/api/config` answers. The set-aside copy in `replaced-*` stays, in case messages written after the backup need recovering from it.

### Restoring the whole volume

If the disk itself is lost, create a volume from the newest `fade-daily` snapshot in the same availability zone, then point Terraform at it (`terraform import aws_ebs_volume.data <new-volume-id>` after `terraform state rm aws_ebs_volume.data`, which needs `prevent_destroy` respected: removing from state doesn't destroy anything). Apply, and the instance mounts it at boot. Then restore the newest database backup on top (above), since the snapshot can be up to a day old.

## Drill log

| Date | Backup | Result |
|---|---|---|
| 2026-10-20 | `db/2026/10/20/fade-20261020T004239Z.db.gz` (first backup, 5 KB) | Passed: integrity ok; 3 users, 2 friendships, 26 messages, matching production. Also confirmed the server's role gets AccessDenied for delete and list on the bucket. |
