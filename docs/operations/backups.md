# Backups and restores

User data is never deleted ([CLAUDE.md](../../CLAUDE.md)), except by a person deleting their own account, and it lives in one SQLite file on one disk. This is how it's protected, and how it comes back after a loss.

## What runs

| | Database backups | Disk snapshots |
|---|---|---|
| What | A consistent copy of `fade.db` (SQLite's online backup API, so the app keeps running), integrity-checked, gzipped | The whole data volume: database, TLS certificates, SSH host keys, backup status |
| How often | Hourly (systemd timer `fade-backup.timer`) | Daily at 09:00 UTC (AWS Data Lifecycle Manager) |
| Where | `s3://fade-backups-<account>-us-east-1/db/YYYY/MM/DD/fade-<time>.db.gz` | EBS snapshots tagged `Backup=fade-daily` |
| Kept | 30 days, then gone, every version (Nate, 2026-11-03), so a deleted account is in no copy after 30 days ([account-deletion.md](../design/account-deletion.md)). Before that, backups were kept forever | 30 days |
| Protected by | Versioned bucket with `prevent_destroy`; the server may only add objects, never read, list, or delete them. It could write over one it knows the name of; the version written over is kept a day | AWS retention policy |
| Status | `/admin` → Server → Last backup (from `/var/lib/fade/backups/last.json`), and the job's own journal | The snapshot list in AWS |

A backup older than two hours shows as **Overdue** in the admin panel, and a failed one shows its error.

## Proving they work

The owner runs a restore drill (`scripts/restore-drill.sh`) after any change to backups, and every month or so: it downloads the newest backup (or one named), checks its integrity, and compares its row counts with production, all read-only. The first, on 2026-10-20, also confirmed the server's role is refused when it tries to delete or list the bucket. The owner keeps the drill log.

## Restoring

Only for real data loss or corruption, and only with the owner's go-ahead. A restore brings back the database as of the backup's time; anything written after that is not in it, so the current file is set aside on the data volume, never deleted, in case messages written after the backup need recovering from it. The data volume is snapshotted first (CLAUDE.md Rule 1), so a restore can be undone too, and the same checks follow as after any infrastructure change: row counts, the site, and `/api/config`.

If the disk itself is lost, a new volume is made from the newest daily snapshot and handed to Terraform in place of the old one (without destroying anything), and the newest database backup goes on top, since the snapshot can be up to a day old.

The step-by-step for both is in the owner's private notes.

**Deletions survive a restore.** A backup can hold accounts deleted since it was made. Each deletion left a marker in the bucket (`deletions/<id>`, the id only), and the server wipes any marked account it finds when it starts (`deletion::reapply`, logged as "deleted account wiped again"). So the server starts after a restore as usual, and the journal shows those lines.

**Manual snapshots** taken before infrastructure changes (Rule 1) hold everyone's data too: they're deleted once they're 30 days old, like the backups.
