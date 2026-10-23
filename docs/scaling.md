# Scaling out: two or more servers, across zones (design)

Status: **proposal, for Nate's review.** Nothing here is built, and no infrastructure changes until the design and cost are approved. Written 2026-10-23 for I3 in [plan.md](plan.md). It replaces I3's earlier decision (an ASG of one keeping SQLite), because the goal is now at least two servers in different availability zones.

## Goals

1. **Survive losing a server or a whole availability zone** without losing data or needing someone to step in.
2. **Run two or more servers at once**, so a deploy or a failure doesn't take napsack down, and so it can grow.
3. **Cost little.** Today everything costs about $7.50 a month. Every added dollar has to buy redundancy or save work.
4. **Keep it private.** Nothing reachable from the internet except the website itself; no SSH port; databases and servers on private addresses only.
5. **One way to deploy**, the same script on a laptop and in the CI release pipeline, with no SSH and automatic rollback.
6. **Rule 1 holds throughout.** Every account, friendship, message, and unopened pic survives the move, verified by counts, with the old data kept.

## Recommendation, in one picture

```
                 people (IPv4 and IPv6)
                          │  HTTPS, WebSockets
                          ▼
         CloudFront  (napsack.getattr.com; free TLS certificate; free tier)
                          │  private: "VPC origin", no public address on anything below
  ┌───────────────────────┼─────────────────────────────────────────────────┐
  │ VPC, two zones        ▼                                                 │
  │            internal load balancer (ALB)                                 │
  │              │                    │                                     │
  │   zone a     ▼          zone b    ▼                                     │
  │      server (t4g.nano)     server (t4g.nano)    ← Auto Scaling group, 2  │
  │          │     \              /      │                                  │
  │          │      PostgreSQL (RDS): data + live events between servers    │
  │          │                                                              │
  │          └── S3 (pics, releases, backups) via a free gateway endpoint   │
  │                                                                         │
  │   outbound only (push services, AWS APIs): IPv6 through a free          │
  │   egress-only gateway; no NAT gateway, no public IPv4                   │
  └─────────────────────────────────────────────────────────────────────────┘
```

- **Database:** move from SQLite to **PostgreSQL on RDS** (`db.t4g.micro`). It's the only database here that two servers can share safely, and it doubles as the channel that carries live events between servers (`LISTEN/NOTIFY`), so there's no Redis to pay for or run.
- **Pics:** move the encrypted pic files from the data disk to **S3**.
- **Servers:** an **Auto Scaling group** of two `t4g.nano`, one per zone, behind an **internal load balancer**, with **CloudFront** in front as the only public entry point. The servers are stateless; any can be replaced at any time.
- **Network:** private subnets only. Outbound calls go over **IPv6 through an egress-only gateway**, which is free, instead of a NAT gateway (about $33 a month).
- **Deploys:** upload a release to S3, point the group at it, and let **instance refresh** swap servers one at a time, launching new ones before stopping old ones. One script does it from a laptop or from CI.

The rest of this document is why, what changes in the code, what it costs, and the order to do it in.

## What has to change, and why

### The database

SQLite is a file on one server's disk. Two servers can't write it. Network file systems (EFS) corrupt it, as SQLite's own docs warn. The data volume (EBS) lives in one zone and attaches to one server.

| Option | Shared by 2+ servers | Survives a zone | Cost a month | Work | Verdict |
|---|---|---|---|---|---|
| **RDS PostgreSQL, single zone** (`db.t4g.micro`, 20 GB) | yes | restore from backup (minutes, to within 5 minutes of data) | about $14 | port the queries once | **recommended to start** |
| RDS PostgreSQL, Multi-AZ | yes | automatic failover, about 1–2 minutes | about $28 | same | recommended once it matters; a setting, no code change |
| SQLite + Litestream (continuous copy to S3), group of one | no: one server at a time | a new server restores and takes over, about 2–4 minutes, may lose the last second | about $8 (same as today) | small | the cheap fallback if 2 servers isn't worth $30 more; see [Cheaper alternatives](#cheaper-alternatives) |
| Aurora Serverless v2 | yes | yes | from about $43 (minimum capacity); scale-to-zero takes seconds to wake | port | too expensive, or too slow to wake for a messenger |
| Aurora DSQL | yes | yes | likely near $0 at this size | large: no foreign keys or `LISTEN/NOTIFY`, retry-on-conflict transactions | revisit later |
| rqlite / dqlite (SQLite over Raft) | yes | yes, with 3 servers | 3 servers minimum | large, and ours to operate | no |

**Why Postgres is cheap enough here:** it removes three things we'd otherwise run. It's the shared database. Its `LISTEN/NOTIFY` replaces Redis for live events between servers; ElastiCache costs $6–12 a month. And its advisory locks let exactly one server run each background job. RDS also does nightly snapshots with 7 days of point-in-time restore at no extra cost up to the database's size.

**What the port involves** (the server uses `sqlx`, which supports Postgres):

- Placeholders go from `?` to `$1, $2, ...`; `INSERT OR IGNORE` becomes `ON CONFLICT DO NOTHING`; SQLite `pragma_*` and `AUTOINCREMENT` go away; `BLOB` becomes `BYTEA`; integer ids become `BIGINT` identity columns.
- Migrations get a fresh, equivalent Postgres baseline. The SQLite migrations stay in the repo, unedited.
- The existing guard tests carry over: `migrations_never_destroy_data`, `code_never_deletes_rows`, and `sql_only_interpolates_constants`.
- Tests get a throwaway Postgres. `scripts/test.sh` starts one in a temporary folder (`initdb` + `pg_ctl`). That works in WSL after one `sudo apt install postgresql`, and in CI, where GitHub's Ubuntu runners already include it.

### The pics on disk

Unopened direct pics and group pics are files in `/var/lib/fade/db/pics` on the data volume, so only one server can see them. Profile and group pictures are already in the database, so they move with it.

**Move pics to S3**: one object per pic, written by whichever server receives it, read by whichever serves it. The server keeps doing the access checks and streams the bytes, so no S3 address ever reaches a browser. View-once still discards the object when a pic is opened or expires; that's the one designed exception to Rule 1, as now. A small storage interface keeps a local-folder version for development and tests. S3 costs cents here. Traffic goes through a **gateway endpoint**, which is free and private.

EFS would avoid the code change (mount it where the folder is now), but it adds a file system to run, with mount targets and permissions, for files that S3 handles more simply. **S3** is the better fit.

### What lives in a server's memory

Everything a server keeps in memory is either per-connection (fine), or has to be shared, or has to happen only once:

| Today, in one process | With several servers | How |
|---|---|---|
| Live connections and event delivery (`ws.rs` hub) | An event for a person must reach whichever server holds their connection | Each server sends events to its own connections as now, **and** publishes them on a Postgres `NOTIFY` channel. Every server listens and delivers to its own. Payloads over Postgres's 8 KB limit go as a reference the receiver loads. |
| Who's online, typing | Must be known across servers | Same channel: presence and typing are events. Admin "online now" adds up every server's count. |
| Sign-in and failed-password limits | Must be **global**, or a second server doubles an attacker's guesses | Moved to a small Postgres table (counters per key and window). |
| Other per-address and per-session limits, the scanner guard's bans | Per server is acceptable | Kept in memory. With two servers, an address that alternates gets up to twice the budget, so halve the numbers, or move bans to the table too (cheap). |
| Background jobs: pic expiry sweeps, reconciliation, AWS reads for metrics, backups | Should run once, not once per server | Each job takes a Postgres advisory lock and skips if another server holds it. The lock frees itself if that server dies. |
| Log viewer buffer | The admin panel would see only the server it reached | Each server also ships its log lines to CloudWatch Logs (30 days, well under $1 a month at our volume). The admin panel asks every server for its buffer and merges them. Servers find each other through a heartbeat row in Postgres. |
| Metrics (`metrics.db`) | Per server by design (each row carries its host) | The minute table moves into Postgres, so the Metrics tab shows every server, and RDS and the load balancer get added from CloudWatch's free metrics. |
| Caddy and its TLS certificates | Not needed | CloudFront does TLS with a free certificate. |
| The client's address (`X-Forwarded-For`, trusted from Caddy on the same machine) | Arrives from CloudFront through the load balancer | Use CloudFront's `CloudFront-Viewer-Address` header, trusted only from the load balancer's private addresses. |

Sessions, keys, accounts, VAPID keys, and everything else are already in the database.

### Getting traffic in

Two servers need something in front that sends each request to a healthy one and keeps WebSockets working.

- **CloudFront** becomes the public face: it holds `napsack.getattr.com` (an alias in the existing Route 53 zone), the TLS certificate (free from ACM), HTTP-to-HTTPS redirects, and HSTS. Its free tier covers 1 TB and 10 million requests a month, far above our use. Caching stays off: everything is dynamic or already versioned.
- Since May 2026, **CloudFront reaches private origins** ("VPC origins"), including an **internal load balancer**, WebSockets included, at no extra charge. So the load balancer gets no public address. That saves the $7.30 a month AWS charges for a load balancer's public IPv4 addresses, and nothing behind CloudFront can be reached from the internet.
- The **Application Load Balancer** (internal, two zones) health-checks each server on `/api/config` and spreads requests. It's the biggest new cost: about $16.40 a month plus a dollar or two of usage. There's no cheaper managed option for active-active servers (a Network Load Balancer costs the same). The only cheaper path is DNS round-robin, under [Cheaper alternatives](#cheaper-alternatives).

### Network and security

```
VPC 10.42.0.0/16 + an IPv6 block, two zones
  private subnet a (IPv4 + IPv6)    private subnet b (IPv4 + IPv6)
    servers, load balancer, RDS       servers, load balancer, RDS standby (Multi-AZ)
  no public IPv4 anywhere; no inbound route from the internet
  outbound IPv6 → egress-only internet gateway (free; replies only, nothing can connect in)
  S3 → gateway endpoint (free, private)
```

| Security group | Allows in | From |
|---|---|---|
| Load balancer | HTTP | CloudFront's managed prefix list only |
| Servers | the app port | the load balancer's group only (plus SSH from the EC2 Instance Connect endpoint, below) |
| RDS | 5432 | the servers' group only |

- **No public IPv4, no NAT gateway.** The servers call only push services (Google, Apple, Mozilla, Microsoft) and AWS APIs. I checked on 2026-10-23: all four push services, and AWS's dual-stack endpoints for SSM, CloudWatch, Cost Explorer, CloudWatch Logs, STS and S3, resolve over IPv6. So the servers can go out over IPv6 only, through the free egress-only gateway. A NAT gateway would cost about $33 a month per zone; interface endpoints for SSM, about $22 per zone. This needs a prototype check before relying on it. If something turns out IPv4-only, the fallback is a public IPv4 address per server ($3.65 each a month), still with no inbound allowed.
- **Shell access** moves from SSH-through-SSM to **EC2 Instance Connect Endpoint**: free, private, no open port, and no dependence on the SSM agent's IPv6 support (unconfirmed). `scripts/ssh.sh` becomes `aws ec2-instance-connect ssh` to a chosen server.
- **RDS:** encrypted, private subnets only, TLS required (`sslmode=verify-full`), a non-superuser app account whose password lives in the existing SSM settings parameter (free; Secrets Manager would add $0.40 a month), deletion protection on, and final snapshots kept.
- **Unchanged:** IMDSv2 only, every rule in CLAUDE.md's Security section, and the app's own headers. CloudFront adds TLS 1.2+ and HSTS. AWS WAF ($5+ a month) isn't needed yet; the app's guard already handles scanners.

### Deploying

Today `scripts/deploy.sh` copies the binary over SSH to one server, and the CI release finds "the one running instance" and runs an update over SSM. With a group of servers that come and go, the server should **pull** its release instead of having it pushed:

1. **Build** the ARM64 binary as now (cargo-zigbuild, in WSL or CI).
2. **Upload** it to S3 as `releases/fade-server-<version>-<build>`.
3. **Point** the SSM parameter `/fade/release` at it. Parameter history doubles as a free deploy log.
4. **Roll:** `aws autoscaling start-instance-refresh`, with minimum healthy 100% and maximum 200%. That launches each new server first, waits until the load balancer calls it healthy, then retires an old one. Auto-rollback is on: if new servers don't become healthy, the group goes back.
5. Each new server **boots** (launch template user data): fetch `/fade/release` and the settings, download the binary from S3, start. The first one to start runs pending migrations; Postgres locks make that happen once. Old servers keep running meanwhile, which the existing [RELEASING.md](RELEASING.md) rule (additive migrations only) already allows.
6. **Verify:** wait for the refresh to finish, then check `/api/config` reports the new build from every server. A new `X-Napsack-Instance` header says which server answered.

All of that is one script, **`scripts/release.sh`**. Locally it runs with your AWS profile; the CI release workflow (tag `server-v*`) runs the same script with its existing OIDC role, plus the new permissions it needs: `ssm:PutParameter` on `/fade/release`, and starting and reading instance refreshes on this group. Rollback is the same script given an older version. A deploy takes about 3–5 minutes. Connections move to the new servers as old ones go, which the app's reconnect logic (0.25.0) already handles.

**Before a release with a migration:** the script takes an RDS snapshot first, replacing today's manual backup step, and `scripts/check-migrations.sh` runs the migration against a copy of the newest backup in a local Postgres.

**Infrastructure changes** stay in Terraform. A launch template change (new AMI, new boot script) rolls out through the same instance refresh.

### Backups

- **RDS automated backups**: daily snapshots, 7 days of point-in-time restore, free up to the database's size.
- **Hourly `pg_dump` to the backups bucket, kept forever** (Glacier Instant Retrieval after 30 days, as now), run by whichever server holds the job's lock. This keeps today's promise of permanent history, independent of RDS.
- The old **EBS data volume and its snapshots are kept** after the move (Rule 1), detached, with `prevent_destroy` still on, and the final SQLite file is copied to the backups bucket. Its 1 GB costs $0.08 a month.

## Cost

Monthly, us-east-1, on-demand, 730 hours. Figures marked ~ are estimates at our traffic.

| | Today | Recommended (start) | Recommended + Multi-AZ database |
|---|---|---|---|
| Servers (t4g.nano) | 1 × $3.07 | 2 × $3.07 = $6.13 | $6.13 |
| Server disks (8 GB gp3) | $0.64 + data $0.08 | 2 × $0.64 = $1.28 (+ old data volume kept, $0.08) | $1.36 |
| Public IPv4 | $3.65 (Elastic IP) | $0 (IPv6 out; fallback +$7.30) | $0 |
| Load balancer (internal ALB) | – | $16.43 + ~$1.50 usage | ~$17.93 |
| CloudFront + certificate | – | $0 (free tier) | $0 |
| Database (RDS db.t4g.micro + 20 GB) | – | ~$11.68 + ~$2.30 = ~$14 | ~$28 |
| S3, CloudWatch Logs, snapshots | cents | ~$1 | ~$1 |
| **Total** | **~$7.50** | **~$40** | **~$54** |

Ways to bring it down once it's stable: a 1-year reserved RDS instance (about 28% off, around $8.50 instead of $11.68), and an EC2 Savings Plan for the servers.

### Cheaper alternatives

- **"Group of one" with Litestream: about $8 a month.** One server in a group spanning two zones. SQLite is continuously copied to S3 by Litestream; a replacement server in either zone restores it in seconds and takes over (the Elastic IP moves with it). Redundant across zones, with about 2–4 minutes of downtime on failure and possibly the last second of writes lost, but never two servers at once. The code barely changes (pics still need S3 or the volume). This is the right choice if two always-on servers aren't worth about $32 a month yet. Everything above except the database still applies later.
- **DNS round-robin instead of a load balancer: about $30 a month.** Two public servers each terminate TLS (Caddy, sharing certificates through S3), and Route 53 health checks ($0.50–1 each) drop a failed server from DNS. It saves about $10, but the servers are public, failover waits on DNS caching (a minute or more), and certificates have to be shared. Not worth it.

## Order of work

Each phase ships on its own, keeps napsack running, and is tested before the next. Infrastructure starts changing only in phase 4.

1. **Pics to S3** (small). Storage interface; S3 in production, a folder in development. Copy existing unopened pics to S3 and verify every one (count and checksum) before switching. `tests/restart_test.py` becomes "unopened pics survive a server being replaced".
2. **Postgres** (largest). Port the queries and tests, and the guard tests. Build a one-time copy tool, `fade-server migrate-from-sqlite`: table by table, ids preserved, sequences set, row counts and checksums compared, refusing to finish on any mismatch. Rehearse on a copy of the newest production backup. Cut over with a few minutes of maintenance page: final backup, copy, verify, switch. Still one server. The SQLite file and the data volume are kept.
3. **Many servers, correctly** (medium). Events, presence and typing over `NOTIFY`; global sign-in limits in Postgres; one-at-a-time background jobs; a log fan-out; metrics in Postgres. Tested locally by running **two servers against one Postgres** in `scripts/test.sh`: a message sent through one arrives on a socket held by the other, sign-in limits are shared, and sweeps run once.
4. **Network, group, and deploys** (medium). Terraform for the dual-stack VPC, private subnets, egress-only gateway, S3 endpoint, security groups, internal ALB, CloudFront with its VPC origin and certificate, RDS subnet group, launch template, Auto Scaling group, and Instance Connect endpoint. Plus `scripts/release.sh`, the CI release update, and new `ssh.sh`, `rollback.sh` and `check-migrations.sh`. **Built beside the current server**: test it through CloudFront's own address first, then switch the Route 53 record. Keep the old server stopped, not deleted, until the new setup has run cleanly for a week.

CLAUDE.md's Rule 1 infrastructure checklist, the "Shipping" section, OPERATIONS.md and SECURITY.md get rewritten in the same phases that change them.

## Decisions for Nate

1. **Two servers on Postgres (about $40 a month), or the group of one with Litestream (about $8)** for now, with the move to two later?
2. **Database redundancy:** single-zone RDS with restore from backup (about $14), or Multi-AZ with automatic failover (about $28)?
3. **IPv6-only outbound**, prototyped first, with a public IPv4 per server ($7.30) as the fallback?
4. **Logs to CloudWatch Logs** for 30 days (under $1)?
5. OK to **replace SSM shell access** with EC2 Instance Connect Endpoint?

## Sources and checks

- Checked 2026-10-23 from this machine: IPv6 (AAAA) records for `fcm.googleapis.com`, `web.push.apple.com`, `updates.push.services.mozilla.com`, `*.notify.windows.com`, and AWS's dual-stack endpoints for SSM, SSM messages, CloudWatch, Cost Explorer, STS, CloudWatch Logs and S3. `ec2messages` has none, but SSM Agent 3.3.40 and later uses `ssmmessages` instead.
- [Amazon CloudFront announces WebSocket support for VPC origins](https://aws.amazon.com/about-aws/whats-new/2026/05/amazon-cloudfront-websockets-vpc-origins/) (May 2026): ALBs, NLBs and EC2 in private subnets, no extra charge.
- [CloudFront VPC origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html): the origin's security group must allow CloudFront's managed prefix list.
- [SSM: ec2messages, ssmmessages and other API operations](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-setting-up-messageAPIs.html): newer agents prefer `ssmmessages`.
- [RDS for PostgreSQL pricing](https://aws.amazon.com/rds/postgresql/pricing) and [db.t4g.micro](https://www.bytebase.com/dbcost/rds/instance/db.t4g.micro/): about $11.68 a month on demand, about $8.47 reserved for a year.
- Other prices (ALB $0.0225 an hour, public IPv4 $0.005 an hour, NAT gateway $0.045 an hour, interface endpoints $0.01 an hour per zone, CloudFront's always-free tier) are AWS's published us-east-1 rates. Check them on the pricing pages before approving.
