# Growing the single server (plan)

Status: **plan, nothing built.** Written 2026-10-23. This is the other path from [horizontal-scaling.md](horizontal-scaling.md): keep today's stack (one EC2 server running everything: the app, SQLite, Caddy, pics on its data disk), and grow it as napsack grows. It answers which limit we'll hit first, how we'll see it coming, and what to do at each step, cheapest first.

## Where we are (measured 2026-10-23)

| Resource | Have | Using | Notes |
|---|---|---|---|
| Accounts | cap 100 (`FADE_MAX_ACCOUNTS`) | 16 | A deliberate safety cap, not a machine limit |
| CPU | t4g.nano: 2 vCPUs, 5% baseline each (6 credits an hour, at most 144 banked) | 0.27% average over 3 days; busiest hour 7.5% | Credit balance never below 26. **Standard credit mode**: out of credits means slowed to 5%, not billed |
| Memory | 412 MB | 185 MB used, 215 MB available | systemd-journald 42 MB, Caddy 39 MB, SSM agent 35–60 MB, napsack 23 MB |
| Data disk | 1 GB gp3 (xfs) | 52 MB | Database 1 MB (half of it profile and group pictures), pics transient |
| System disk | 8 GB gp3 | 1.9 GB | |
| Traffic | | ~400 messages a week; p95 response 7 ms | 2-day-old metrics, 4 days of users |
| Recovery | EC2 simplified automatic recovery is on (the default) | | A hardware failure restarts the server elsewhere with the same disks and address |

Everything is far from its limit. The question is which one gets there first.

## What runs out first, in order

### 1. The account cap (100)

The first wall is one we set. `FADE_MAX_ACCOUNTS=100` exists so an invite link leaking can't fill the server. Raising it is a settings change: `terraform.tfvars`, then `terraform apply` updates the SSM parameter, then a restart of a second or two. It should go up in step with what the machine can hold. The rest of this list says what that is.

Before any `terraform apply` that touches the settings parameter, reconcile `FADE_ADMINS`: production's admin list differs from `terraform.tfvars`, and applying would overwrite it ([horizontal-scaling.md](horizontal-scaling.md) planning found this).

### 2. Memory (0.5 GB): the first real upgrade

Memory is the tightest resource on a t4g.nano, and it fails abruptly: the kernel kills a process rather than slowing down. Three things use it:

- **The baseline**, about 160–190 MB: journald, Caddy, the SSM agent, the OS. The app itself is small (23 MB).
- **Spikes:**
  - Re-encoding an uploaded profile or group picture can allocate up to 96 MB (`images.rs`; one at a time). End-to-end encrypted pics are never decoded on the server, so only pictures count.
  - Each password check (Argon2, default settings) takes about 19 MB. Several sign-ins at once stack up, because nothing limits how many run together.
- **Open connections:** each WebSocket holds its buffers, estimated at roughly 100–200 KB, mostly a read buffer far larger than our 16 KB message limit. To be measured (step 0 below).

On a nano, after setting aside room for one picture and a couple of sign-ins, roughly 60–70 MB is left for connections: on the order of a few hundred open connections. That's about where the 500-connection cap sits. So the nano is fine up to the 100-account cap, and going well past it means more memory.

**Cheap first (free, code and config):**
- Cap journald's memory (`RuntimeMaxUse=32M` in the boot script): saves about 20–30 MB.
- Let only two password checks run at once (a semaphore around Argon2): bounds sign-in spikes at about 40 MB; queued sign-ins wait milliseconds.
- Shrink the WebSocket read buffer to fit our 16 KB message cap (axum's `read_buffer_size`): could cut per-connection memory several times. Measure before and after.

**Then the upgrade: t4g.nano → t4g.micro** (1 GB, +$3.07 a month). Doubling memory roughly quadruples what's free for connections, because the baseline doesn't grow. When upgrading, raise the app's `MemoryMax=400M` (in the boot script) to fit, since today it's higher than what the nano can actually spare.

**Watch for it:** the Metrics tab's memory chart (watch at 80%, red at 90%), swap in use, and server memory against its limit.

### 3. Backups grow with the database, forever

Every hour the backup job copies the whole database to S3 (compressed), and copies are kept forever: Standard storage, then Glacier Instant Retrieval after 30 days. Today a copy is 0.4 MB, about 300 MB a month in total, which costs nothing. But the total grows with **database size × 720 copies a month**, and keeps growing. Ciphertext and JPEG pictures barely compress.

| Database | Added each month | Cost added each month (and it accumulates) |
|---|---|---|
| 1 MB (today) | ~0.3 GB | ~$0.001 |
| 100 MB | ~70 GB | ~$0.30 in Glacier IR (plus ~$1.70 while in Standard) |
| 1 GB | ~700 GB | ~$3 a month more, every month |

Copying and compressing a large database every hour also costs CPU and memory on a small machine.

**What to do, before the database passes about 50 MB:** switch to **incremental** backups with **Litestream**, which copies each change to S3 within a second. That's point-in-time restore with seconds of loss instead of an hour, and storage grows with changes rather than size × hours. Keep a daily full copy forever, so the "kept forever" promise still holds. This changes the backup policy in [BACKUPS.md](BACKUPS.md), so it's Nate's decision. It's also the first step of the "group of one" option in [horizontal-scaling.md](horizontal-scaling.md#cheaper-alternatives).

### 4. CPU credits

Steady messaging is cheap: a request is well under a millisecond of CPU. The expensive moments are password checks (tens of milliseconds each), re-encoding pictures (a fraction of a second), TLS handshakes in Caddy, and encrypting push notifications (a group message to 32 people with several devices each is a few hundred small encryptions).

The baseline allows 6 CPU-minutes per hour. That's very roughly 200,000+ ordinary requests an hour before the credit bank starts to drain. We're far below.

**This server is in standard credit mode.** When credits run out it isn't billed; it's slowed to 5% of each vCPU. Requests get slow, and the Metrics tab shows steal rising and credits at zero. Two ways out:
- **Switch to unlimited mode** (one Terraform setting, no restart): CPU above the baseline is billed at $0.04 per vCPU-hour. Good for occasional bursts.
- **Step up a size:** t4g.micro doubles the baseline to 10%; t4g.small, 20%. Cheaper than unlimited once usage above the baseline is steady. Break-even for nano → micro is about 0.1 vCPU of steady extra use ($3.07 a month ÷ $0.04 ÷ 730 hours).

**Watch for it:** the CPU credits chart (watch below a third of a full bank, red below a tenth), and steal.

### 5. The data disk (1 GB)

The database grows by roughly 100 KB per active person per month: about 90 bytes of ciphertext per text plus row and index overhead, group message keys, and every profile or group picture they ever set (about 20 KB each, kept forever). Unopened pics are capped at 256 MB direct + 200 MB group, so about half the disk is the database's.

| Active people | Fills the database's half in about |
|---|---|
| 100 | 4 years |
| 500 | 9 months |
| 2,000 | 2 months |

The guard refuses uploads, then all writes, before the disk fills, so it fails safely. But growing it should happen long before that.

**What to do when the data disk passes about 60%:** grow the volume, with no downtime.
1. Snapshot it (Rule 1).
2. Raise `data_volume_gb` in tfvars and apply. That changes `aws_ebs_volume.data` in place, the one kind of change allowed for it.
3. Once AWS finishes optimizing the volume, run `sudo xfs_growfs /var/lib/fade`.
4. Raise the pic caps (`FADE_SNAP_DISK_MB`, `FADE_GROUP_PIC_DISK_MB`) to match.

gp3 costs $0.08 per GB a month, so 10 GB is $0.80. A volume can grow once every 6 hours and never shrink.

### 6. SQLite and slow queries

SQLite (WAL, `synchronous=NORMAL`, 5 connections) on gp3 (3,000 IOPS) handles hundreds of write transactions a second or more. A messenger with a few thousand active people makes a few a second. The single-writer database is not a near-term limit.

The first slow queries will be the admin panel's: its user list counts friends, texts, and pics with a subquery per user (up to 500), and the daily chart scans messages. They'll slow down long before anything people use. **When the admin stats take more than a few hundred ms**, keep running counts instead of recounting. Watch p95 response time and "pool full" warnings in the logs.

### 7. Connections and network

- Open connections are capped at 500 (`FADE_MAX_SOCKETS`). The file limit (65,535) and threads aren't close. The cap should follow memory (step 2).
- A t4g.nano's network baseline is about 32 Mbit/s (it bursts higher). Pics are 200 KB or less, so that's about 20 pics a second sustained: far off.

### 8. What growing one server can't fix

- **One server is one point of failure.** Automatic recovery covers hardware faults; a zone outage or a bad boot still takes napsack down until the server is rebuilt (the data volume and snapshots survive).
- **Deploys restart the server**, dropping connections for a second or two; apps reconnect on their own.
- **The biggest burstable size** (t4g.2xlarge: 8 vCPUs, 32 GB) is far beyond anything here. Beyond burstable, an m7g (steady full CPU) costs more per vCPU but never throttles.

Those are what [horizontal-scaling.md](horizontal-scaling.md) solves. If they matter before capacity does, the cheap route there is the "group of one" with Litestream (step 3).

## The upgrade ladder

| Size | vCPUs | Memory | Baseline per vCPU | Per month | Roughly enough for |
|---|---|---|---|---|---|
| t4g.nano (today) | 2 | 0.5 GB | 5% | $3.07 | the 100-account cap |
| t4g.micro | 2 | 1 GB | 10% | $6.13 | several hundred active people |
| t4g.small | 2 | 2 GB | 20% | $12.26 | a few thousand |
| t4g.medium | 2 | 4 GB | 20% | $24.53 | many thousands |
| m7g.medium (not burstable) | 1 | 4 GB | 100% | about $29.80 | steady CPU-heavy load |

The "enough for" column is an estimate from the measurements above. Step 0 replaces it with measured numbers.

**How to step up:** change `instance_type` in tfvars.
- **Read the plan first:** Terraform should say **update in-place** (it stops the server, changes the size, and starts it again). The data volume, the Elastic IP and everything on disk stay. `user_data_replace_on_change` only replaces the server when the boot script changes, so don't combine the two in one apply.
- **Downtime:** about a minute or two. Pick the quietest hour (the Metrics tab's 3-day Requests chart shows it).
- **Rule 1:** the usual infrastructure checklist: a snapshot first, row counts before and after, and the Metrics tab afterwards.

## Step 0: measure, before the first upgrade

The estimates above (memory per connection, CPU per message) should be measured once, so the upgrade points are real numbers.

1. Add `tests/load_test.py`, run locally only, never against production: open N WebSocket connections as N test users, send messages at a steady rate, and sign in a few at once.
2. Read memory and CPU from the local Metrics tab at N = 100, 500 and 1,000.
3. Record the results here, and set `FADE_MAX_SOCKETS`, `FADE_MAX_ACCOUNTS` and the upgrade triggers from them.

## Free improvements on the way

**Put CloudFront in front, still one server.** CloudFront can reach a single EC2 server in a private subnet (a "VPC origin", WebSockets included):
- The Elastic IP goes away ($3.65 a month saved), and Caddy with it (39 MB of memory and its TLS CPU).
- The server becomes unreachable from the internet.
- It costs nothing at our size (CloudFront's free tier).

The server still needs a way out to push services and AWS: IPv6 through a free egress-only gateway, as [horizontal-scaling.md](horizontal-scaling.md#network-and-security) describes. It's also the first piece of that design, so nothing is wasted if napsack later goes to two servers.

## Summary: what to do, and when

| When | Do | Cost |
|---|---|---|
| Now | Step 0: measure. Cap journald; limit concurrent password checks; trim WebSocket buffers. Fix the Metrics tab's message for standard credit mode | free |
| Before raising the 100-account cap | t4g.micro; raise `MemoryMax`, the socket cap and the account cap together | +$3.07/mo |
| Database passes ~50 MB | Litestream incremental backups (Nate's call on retention) | cents |
| Data disk passes ~60% | Grow the volume online; raise the pic caps | $0.08/GB/mo |
| Credits draining for days | Unlimited mode for bursts, or the next size up for steady load | per use, or +$3–12/mo |
| Admin stats slower than a few hundred ms | Running counts instead of recounting | free |
| Any time | CloudFront in front: no public address, no Caddy | −$3.65/mo |
| A zone outage, or deploys without blips, start to matter | [horizontal-scaling.md](horizontal-scaling.md) | +$1 to +$46/mo |
