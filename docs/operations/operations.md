# Operations

Running napsack in production: the AWS setup, settings, getting a shell, domains, and what it costs. Releasing is in [releasing.md](releasing.md), backups in [backups.md](backups.md), limits and what to do under attack in [security.md](../security.md). The rules for touching production (above all: data is never deleted) are in [CLAUDE.md](../../CLAUDE.md).

## Deploy to AWS

```sh
cd infra
cp terraform.tfvars.example terraform.tfvars   # set invite_code
terraform init && terraform apply
cd ..

# one-time build tooling
rustup target add aarch64-unknown-linux-musl
cargo install cargo-zigbuild && pip install ziglang

scripts/deploy.sh          # build, copy over SSH, restart, check the live build
scripts/ssh.sh             # shell on the box; extra args run a command
scripts/rollback.sh        # list kept builds, or roll back to one
```

The normal way to ship the server is the release pipeline: a push to `main` is tested, built once, and put on staging; a `server-v*` tag puts that same build on production (after a backup). `scripts/deploy.sh` is for hotfixes. Versioning, compatibility rules, rollbacks, and one-time CI setup are in [releasing.md](releasing.md).

SSH uses `~/.ssh/id_ed25519` by default (`ssh_public_key_path`). With `ssh_allowed_cidrs` empty, port 22 stays closed and SSH is tunneled through SSM, which needs the AWS CLI and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Set it to e.g. `["203.0.113.7/32"]` to connect directly instead. To use plain `ssh fade`, scp, or VS Code Remote-SSH, run `terraform -chdir=infra output -raw ssh_config >> ~/.ssh/config`.

Deploy runs `sudo fade-update <file>` on the box: it keeps the old binary as `fade-server.prev`, restarts, and fails if the service doesn't come back up. It also copies the build to S3, so a replaced instance boots with the same release.

With no `domain` set, the app is served at `https://<elastic-ip-with-dashes>.sslip.io` with a real Let's Encrypt cert, so you don't need DNS. To use your own domain on a fresh deploy, run `terraform apply -target=aws_eip.app` first, point an A record at that IP, set `domain`, then run a full `terraform apply`. Otherwise Caddy requests the cert before DNS resolves and backs off. Changing it replaces the instance, but the data volume survives.

What you get: one Graviton `t4g.nano` running Amazon Linux 2023, Caddy for TLS, and the app under a hardened systemd unit. The DB and certs sit on a separate encrypted EBS volume with daily snapshots. You get in over SSH as `ec2-user`, which has sudo. The SSH host keys live on the data volume, so replacing the instance doesn't trigger host-key warnings.

Changing config: edit tfvars, run `terraform apply` (which updates the SSM parameter), then `scripts/ssh.sh sudo systemctl restart fade`. Rollback: `scripts/rollback.sh`.

### Rough monthly cost (us-east-1, on-demand)

| | |
|---|---|
| t4g.nano | ~$3.07 |
| Public IPv4 (Elastic IP) | ~$3.65 |
| 8 GB root + 1 GB data gp3 | ~$0.72 |
| Snapshots, S3, SSM parameter | cents |
| **Total** | **~$7.50** |

The admin panel's **Metrics** tab shows a live version of this estimate, what AWS has actually billed for everything tagged `App=fade` (from Cost Explorer, checked twice a day, $0.01 a check), and the price of the next instance size up.

The first 100 GB/month of outbound data is free. Check current prices before relying on these numbers. The IPv4 charge is the biggest line after compute. Putting CloudFront in front could eventually remove it, but that's not worth the complexity yet.

## Settings

The server reads these environment variables. In production they come from an AWS Parameter Store entry that Terraform writes (`local.env_file` in `infra/main.tf`).

| Variable | Default | |
|---|---|---|
| `FADE_BIND` | `127.0.0.1:8080` | |
| `FADE_DATABASE_URL` | `sqlite://fade.db` | |
| `FADE_INVITE_CODE` | unset (open signup) | Required to register when set |
| `FADE_SNAP_TTL_HOURS` | `720` | Unopened direct pics expire after this (30 days) |
| `FADE_SNAP_MAX_KB` | `512` | Hard cap per encrypted pic. The client compresses every photo to 200 KB or less |
| `FADE_VIDEO_MAX_KB` | `4096` | Hard cap per encrypted video. Clients record about 1.5 Mbit/s, so 10 seconds is about 2 MB |
| `FADE_VIDEO_MAX_SECONDS` | `10` | The longest video a client records (1 to 60) |
| `FADE_SNAP_DISK_MB` | `256` | Disk ceiling for all unopened direct pics |
| `FADE_MAX_ACCOUNTS` · `FADE_MAX_SESSIONS` | `100` · `4` | Hard caps: accounts in total, signed-in devices per person ([security.md](../security.md)) |
| `FADE_REQUESTS_PER_ADDRESS` · `FADE_MAX_IN_FLIGHT` · `FADE_MAX_SOCKETS` | `3000` · `200` · `500` | Request budget per address per 10 minutes; requests at once; live connections |
| `FADE_PUBLIC_URL` | `https://localhost` | The site's address (Terraform sets it); the contact in push requests |
| `FADE_SESSION_DAYS` | `90` | |
| `FADE_ADMINS` | unset | Admins, comma-separated (development and tests). Production uses `FADE_ADMINS_PARAM` instead ([roles.md](../implementation/roles.md)) |
| `FADE_ADMINS_PARAM` | unset | The SSM parameter holding the admin list (production: `/fade/admins`), read at start and on reload. Set it with `scripts/set-admins.sh nate,liana`, then `scripts/reload-admins.sh` |
| `FADE_ENVIRONMENT` | unset (production) | A non-production copy's name, like `staging`: every page then says "napsack (staging)", shows an amber band and the build in the corner, and notifications start with `[staging]`. Letters, digits, and hyphens; empty, `production` or `prod` mean production |
| `FADE_HEALTH_PREFIX` | `health/` | Where the Metrics tab reads incident records in the artifacts bucket. Staging sets `staging/health/` so it never reads production's |
| `FADE_EXEMPT_ADDRESSES` | unset | **Staging only.** Comma-separated client addresses treated like local requests: no per-address limits or scanner bans, so test machines can run the suites and load tests ([staging.md](staging.md)). Never set in production |
| `RUST_LOG` | `fade_server=info` | What goes to stdout (the system journal on the server) |
| `FADE_LOG_BUFFER` | `fade_server=debug` | What the admin log viewer keeps (last 20,000 entries, in memory) |
| `FADE_MIN_CLIENT_VERSIONS` | unset | e.g. `ios=1.2.0`. Older native apps get `426` and an update prompt ([releasing.md](releasing.md)) |
| `FADE_METRICS_RETENTION_HOURS` | `72` | How much history the admin Metrics tab keeps (up to 31 days). Changing it takes effect on restart |
| `FADE_METRICS_DB` | `metrics.db` beside the database | The metrics store. Not user data: a fixed-size ring that overwrites itself |

## Metrics

How every figure is measured and drawn: [metrics.md](../implementation/metrics.md). In short, `/admin#metrics` shows how the machine and the server are doing: a status per machine (All good, Worth watching, In the red, with the reasons), cost, and charts for the last hour (10-second readings), 24 hours, or the whole retention window (3 days by default; each minute kept as min/avg/max, so spikes stay visible).

- **Where it comes from:** the server reads `/proc` every 10 seconds (machine CPU including steal and iowait, memory, both disks' space and activity, network; its own CPU, memory, threads, open files) and times every request (exact p50/p95/p99 per minute). History is in `metrics.db` on the data volume, so it survives deploys.
- **What "in the red" means:** memory or a disk over 90% (80% is "watch"), the server near its 400 MB systemd limit, response times (p95) over 2 seconds (500 ms watch), server errors, or AWS holding back CPU (steal). A t4g is burstable, so for CPU what matters is the **credit balance** (from CloudWatch every 5 minutes, free): low credits mean that past zero, CPU over the free baseline (5% on a t4g.nano) is billed. The CPU chart draws that baseline.
- **AWS permissions:** the instance role needs `cloudwatch:GetMetricStatistics` and `ce:GetCostAndUsage` (`ReadCpuCredits` and `ReadCosts` in `infra/main.tf`). Without them the tab still works; it just says AWS refused, and the credits chart and billed cost are missing.
- **More machines later:** every reading is stored with its host (the instance id). Another machine can feed the same store; the tab shows a machine picker once there's more than one.

## Health monitor

A Lambda (`fade-health`) checks `/api/health` every 5 minutes and, after two failures in a row, tries to fix the server: restart the app, reboot, stop and start, then asks for a human ([health-monitor.md](../implementation/health-monitor.md)). Incidents (evidence and actions): `aws s3 ls s3://$(terraform -chdir=infra output -raw artifacts_bucket 2>/dev/null)/health/incidents/`. Notifications go to the SNS topic in `terraform -chdir=infra output -raw health_topic_arn`; subscribe an email to receive them. Watch-only mode: `health_act = false` in tfvars.

## Staging

A separate napsack at staging.napsack.io (`infra/staging/`, its own Terraform state), for the browser tests and load tests against a real deployment. No backups, no user data, and no access to production's settings, data, or releases. How to deploy, test, and load test it, and why it can't touch production: [staging.md](staging.md). Set `FADE_STACK=staging` for `scripts/deploy.sh` and `scripts/ssh.sh`.
