# Operations

Running napsack in production: the AWS setup, settings, getting a shell, domains, and what it costs. Releasing is in [RELEASING.md](RELEASING.md), backups in [BACKUPS.md](BACKUPS.md), limits and what to do under attack in [SECURITY.md](SECURITY.md). The rules for touching production (above all: data is never deleted) are in [CLAUDE.md](../CLAUDE.md).

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

The normal way to ship the server is a `server-v*` tag, which GitHub Actions tests, builds, and deploys. `scripts/deploy.sh` is for hotfixes. Versioning, compatibility rules, rollbacks, and one-time CI setup are in [RELEASING.md](RELEASING.md).

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
| `FADE_SNAP_DISK_MB` | `256` | Disk ceiling for all unopened direct pics |
| `FADE_MAX_ACCOUNTS` · `FADE_MAX_SESSIONS` | `100` · `4` | Hard caps: accounts in total, signed-in devices per person ([SECURITY.md](SECURITY.md)) |
| `FADE_REQUESTS_PER_ADDRESS` · `FADE_MAX_IN_FLIGHT` · `FADE_MAX_SOCKETS` | `3000` · `200` · `500` | Request budget per address per 10 minutes; requests at once; live connections |
| `FADE_PUBLIC_URL` | `https://localhost` | The site's address (Terraform sets it); the contact in push requests |
| `FADE_SESSION_DAYS` | `90` | |
| `FADE_ADMINS` | unset (panel off) | Comma-separated usernames allowed into `/admin` |
| `RUST_LOG` | `fade_server=info` | What goes to stdout (the system journal on the server) |
| `FADE_LOG_BUFFER` | `fade_server=debug` | What the admin log viewer keeps (last 20,000 entries, in memory) |
| `FADE_MIN_CLIENT_VERSIONS` | unset | e.g. `ios=1.2.0`. Older native apps get `426` and an update prompt ([RELEASING.md](RELEASING.md)) |
