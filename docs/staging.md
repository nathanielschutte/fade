# Staging

A second, separate napsack at <https://staging.napsack.io>, for running the browser tests against a real deployment (Caddy, TLS, AWS) and for load testing. It shares production's network and nothing else. Plan entry: [I8](plan.md#i8-staging).

## What it is

- **Its own Terraform root**, `infra/staging/`, with its own state file. It never manages a production resource. It only *looks up* production's VPC and subnet (by their `Name` tags), the artifacts bucket, and the Route 53 zone.
- **Its own resources**, all tagged `App=fade-staging`: a t4g.nano (same size as production, so load numbers mean something), an Elastic IP, a security group, a 1 GB data volume, the settings parameter `/fade-staging/env`, an instance role, and the DNS record `staging.napsack.io`.
- **The same boot script as production** (`infra/user_data.sh.tftpl`), with two exact substitutions: the backup timer isn't enabled, and the server comes from `releases/staging/fade-server`. Preconditions on the instance fail the plan if the template changes so that either substitution would miss.
- **Its own accounts.** Its own invite code (in `infra/staging/terraform.tfvars`, gitignored) and admin list (`e2e_admin`, `smoke_admin`, the test accounts). Nobody's real data is on it.
- Cost: about $7.40 a month (instance $3.07, Elastic IP $3.65, volumes $0.72). `terraform -chdir=infra/staging destroy` removes it all (allowed for staging only; it holds no user data). Never run destroy in `infra/`.

## Why production can't be touched from it

| Path | What stops it |
|---|---|
| Production's settings (`/fade/env`, `/fade/admins`) | Staging's role explicitly denies `ssm:GetParameter*` on `/fade` and `/fade/*`, and denies `GetParametersByPath` everywhere. An explicit Deny beats `AmazonSSMManagedInstanceCore`, which would otherwise allow it. Checked from the staging machine: both are AccessDenied. |
| Production's backups and data | Staging's role has no access to the backups bucket and no backup timer. Production's database is on production's volume, which staging can't attach (different Terraform state; `prevent_destroy` in production). |
| Production's releases | Staging can read only `releases/staging/*`. `scripts/deploy.sh` with `FADE_STACK=staging` writes only there (the `release_prefix` output). |
| Production's health monitor | It watches instances tagged `App=fade` only, so it never restarts staging, and staging failures never page anyone. |
| Production's Terraform | Separate state. After every staging apply, `terraform plan` in `infra/` should still say "No changes". |
| Shared network | Separate security group; production's group doesn't allow anything from staging beyond what it allows from the internet. |

## Using it

Every script picks the stack from `FADE_STACK` (empty means production):

```sh
FADE_STACK=staging scripts/deploy.sh      # WSL; builds and deploys to staging only
FADE_STACK=staging scripts/ssh.sh "sudo journalctl -u fade -n 30"
scripts/test-staging.sh                   # smoke test + all browser tests against staging
scripts/test-staging.sh --no-browser      # smoke test only
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

See below; filled in after each run.
