# Staging

A second, separate napsack at <https://staging.napsack.io>, for running the browser tests against a real deployment (Caddy, TLS, AWS) and for load testing. It shares production's network and nothing else. Plan entry: [I8](../management/plan.md#i8-staging).

## What it is

- **Its own Terraform root**, `infra/staging/`, with its own state (its own key in the state bucket; [operations.md](operations.md)). It never manages a production resource. It only *looks up* production's VPC and subnet (by their `Name` tags), the artifacts bucket, and the Route 53 zone.
- **Its own resources**, all tagged `App=fade-staging`: a t4g.nano (same size as production, so load numbers mean something), an Elastic IP, a security group, a 1 GB data volume, the settings parameter `/fade-staging/env`, an instance role, and the DNS record `staging.napsack.io`.
- **The same boot script as production** (`infra/user_data.sh.tftpl`), with two exact substitutions: the backup timer isn't enabled, and the server comes from `releases/main/fade-server`, the newest release candidate, instead of production's release. Preconditions on the instance fail the plan if the template changes so that either substitution would miss.
- **Its own accounts.** Its own invite code (in `infra/staging/terraform.tfvars`, gitignored) and admin list (`e2e_admin`, `smoke_admin`, the test accounts). Nobody's real data is on it.
- Cost: about $7.40 a month (instance $3.07, Elastic IP $3.65, volumes $0.72). `terraform -chdir=infra/staging destroy` removes it all (allowed for staging only; it holds no user data). Never run destroy in `infra/`.

## How you know you're on it

`FADE_ENVIRONMENT=staging` (in staging's settings) makes every page say so: "napsack (staging)" in the tab, a **staging** tag by the wordmark, a thin amber band across the top (and the browser bar, on phones), and the build in the bottom-right corner: `staging · v0.31.0 · f3fe492 · up 2h` (environment, server version, commit, time since the last restart, so a deploy shows). Notifications from staging start with `[staging]`.

It's all added on top of the design (`server/static/env.js`, and the "non-production copies" section of `style.css`, keyed on `<html data-env>`), so changing the design never means changing staging. Production leaves `FADE_ENVIRONMENT` unset and shows none of it. `tests/e2e/test_environment.py` checks both, and that the build line never covers any text.

## Why production can't be touched from it

| Path | What stops it |
|---|---|
| Production's settings (`/fade/env`, `/fade/admins`) | Staging's role explicitly denies `ssm:GetParameter*` on `/fade` and `/fade/*`, and denies `GetParametersByPath` everywhere. An explicit Deny beats `AmazonSSMManagedInstanceCore`, which would otherwise allow it. Checked from the staging machine: both are AccessDenied. |
| Production's backups and data | Staging's role has no access to the backups bucket and no backup timer. Production's database is on production's volume, which staging can't attach (different Terraform state; `prevent_destroy` in production). |
| Production's releases | Staging's server can read only the release candidates (`releases/main/*`). CI deploys them with its own role (`fade-github-staging`), which can write only `releases/main/` and reach only staging's server. `scripts/deploy.sh` with `FADE_STACK=staging` writes there too (the `release_prefix` output). |
| Production's bill | Staging's role has no Cost Explorer access, and a non-production server doesn't ask (its Metrics tab says billing is read in production only). Staging's own resources are tagged `App=fade-staging` in AWS Billing. |
| Production's health monitor | It watches instances tagged `App=fade` only, so it never restarts staging, and staging failures never page anyone. |
| Production's Terraform | Separate state. After every staging apply, `terraform plan` in `infra/` should still say "No changes". |
| Shared network | Separate security group; production's group doesn't allow anything from staging beyond what it allows from the internet. |

## Using it

Every script picks the stack from `FADE_STACK` (empty means production):

```sh
git push origin main                      # CI: tests, then builds and deploys the commit to staging
FADE_STACK=staging scripts/deploy.sh      # a local build instead, to staging only (needs cargo-zigbuild)
FADE_STACK=staging scripts/ssh.sh "sudo journalctl -u fade -n 30"
scripts/test-staging.sh                   # smoke test + all browser tests against staging
scripts/test-staging.sh --no-browser      # smoke test only
scripts/test-ios.sh --staging             # the iOS app's live tests against staging (make ios-staging; a Mac)
scripts/load-staging.sh --stages 50,100,200 --rate 6 --duration 60
```

`test-staging.sh` and `load-staging.sh` read the URL from `terraform -chdir=infra/staging output url` and refuse anything that isn't `https://staging.*`. `tests/load_test.py` refuses too.

**Tester addresses.** Per-address limits (request budgets, sign-up limits, scanner bans) would throttle a test run from one machine. On staging only, `FADE_EXEMPT_ADDRESSES` (from `exempt_addresses` in the staging tfvars) treats those addresses like local requests. Production never sets it. If your address changes, update the tfvars and `terraform -chdir=infra/staging apply` (it updates the setting; restart the service to pick it up).

What the remote runs skip (`NAPSACK_REMOTE=1`): the dev live-reload test (staging runs a release build), and the checks that need the server's own machine (the test server's log file, the "no AWS" cost estimate).

## Load test

`tests/load_test.py` registers test accounts once (a few at a time; each is a password hash on the server) and keeps them in `tests/.loadtest-staging.napsack.io.json` (gitignored) for later runs. Accounts are friends in a ring. At each stage, N accounts each hold a live socket (like an open app) and send texts to friends at the set rate. It reports:

- **send**: how long `POST /chats/{id}/messages` takes;
- **delivery**: from sending to the text arriving on the friend's socket (what people feel);
- `/api/health` response time under load, errors, and dropped sockets.

Results are saved next to the accounts file. Watch staging's own Metrics tab (sign in as `e2e_admin`) during a run for CPU, memory, and CPU credits.

### Results

**2026-10-23, 0.30.0, t4g.nano (2 vCPUs, 412 MB), from home over the internet.** Accounts are friends in a ring (3 on each side); each holds a socket and sends texts to friends. Times are seen from the test machine, so about 33 ms of every one is the round trip from home to us-east-1. Server figures are staging's own Metrics readings.

| Online | Texts a minute each | Texts/s | Send p50 / p95 | Delivery p50 / p95 | Errors | Server CPU (machine, peak) | Memory (machine) | napsack's memory |
|---|---|---|---|---|---|---|---|---|
| 50 | 6 | 5.7 | 34 / 44 ms | 33 / 43 ms | 0 | under 5% | 50% | 47 MB |
| 100 | 6 | 10.8 | 34 / 41 ms | 33 / 41 ms | 0 | under 5% | 53% | 55 MB |
| 200 | 6 | 22.3 | 34 / 41 ms | 34 / 40 ms | 0 | under 5% | 63% | 74 MB |
| 400 | 6 | 47.6 | 35 / 49 ms | 34 / 49 ms | 0 | 7% | 80% | 108 MB |
| 400 | 30 | 207 | 37 / 53 ms | 37 / 52 ms | 0 | 19% | 85% | 113 MB |
| 400 | 60 | 392 | 38 / 48 ms | 37 / 48 ms | 0 | 34% | 85% | 120 MB |
| 400 | 120 | 718 | 41 / 71 ms | 44 / 82 ms | 0 | 56% | 86% | 122 MB |

Every text arrived (delivered = sent at every stage), and `/api/health` stayed under 160 ms throughout.

What it means:
- **Memory runs out first, not CPU.** Each connected person costs about 175 KB in napsack (47 MB at 50 sockets, 108 MB at 400), plus Caddy's share for the TLS connection. At 400 the machine was at 86%. Production's cap of 500 live connections (`FADE_MAX_SOCKETS`) is about right for a nano; [mono-scaling.md](../design/mono-scaling.md) step 2 has the fixes (cap journald, a smaller WebSocket read buffer) and the upgrade (t4g.micro).
- **Throughput is far past what napsack needs.** 718 texts a second used about half the machine (napsack itself 36%). Today's production traffic is a few texts a minute. The load generator, on one home machine, was near its own limit at that stage, so the server's real ceiling is higher.
- **CPU credits:** a busy minute like the last stage spends credits (a nano's free baseline is 5% of the machine); at that rate a full bank lasts about six hours, then texts would slow to the baseline. Normal traffic never gets near it.
- Not measured yet: pics (encryption happens on phones, but uploads and disk writes don't), group fan-out to 32 members, and many sign-ins at once (each is a deliberately slow password hash: registering 390 accounts four at a time took a few minutes).
