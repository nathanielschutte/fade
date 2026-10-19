# CLAUDE.md

How we work on napsack. This file is iterative: when we settle a new rule or pattern while working, add it here in the same change. If something here turns out wrong, fix it rather than working around it.

## What this is

napsack is a small private messenger: texts and view-once pictures between friends, end-to-end encrypted. `fade` is the internal name (binary, systemd unit, `FADE_*` env vars, AWS resources); `napsack` is what people see. Never rename the internals just to match.

- `server/`: Rust (axum + SQLite). Serves the API and the web client, which is compiled into the binary.
- `server/static/`: web client. Plain HTML/CSS/ES modules, no build step, no framework. `crypto.js` is the whole encryption scheme.
- `infra/`: Terraform for AWS (one EC2 instance, Caddy, a separate EBS data volume).
- `tests/`: API smoke test, browser tests, pinned crypto vectors. `scripts/`: test, deploy, rollback, ssh.
- `docs/`: [plan.md](docs/plan.md) (task tracker), [RELEASING.md](docs/RELEASING.md) (versioning and compatibility rules), [how-napsack-works.md](docs/how-napsack-works.md) (encryption), [mobile.md](docs/mobile.md) (iOS plan).

The live site is <https://napsack.getattr.com>. The domain will change again: never hardcode it. Scripts read it from `terraform output url`.

## Rule 1: user data is never deleted

Every account, friendship, message, and the data volume that holds them must survive every change we make. No exceptions without the user's explicit, specific approval for that one action.

**In code and migrations**
- Migrations only add: new tables, nullable or defaulted columns, indexes. Never `DROP TABLE`/`COLUMN`, `DELETE FROM`, `RENAME`, `TRUNCATE`, or overwrite existing values. `db::tests::migrations_never_destroy_data` enforces this in CI; don't weaken it to get a change through.
- Removing a feature hides it; it doesn't delete its data.
- Texts live forever. Anything that pages, trims, or caches must never remove rows.
- Migrations are never edited after release. Add a new one.

**In infrastructure**
- Never run `terraform destroy`. Never remove `prevent_destroy` from `aws_ebs_volume.data`.
- Read every `terraform plan` before applying. If `aws_ebs_volume.data` shows anything other than no change, or an update in place you understand, stop and ask. `aws_instance.app` being replaced is normal (new AMI, new boot script, new domain); the data volume being replaced never is.
- Before any apply that replaces the instance or touches storage:
  1. Take a manual snapshot of the data volume and wait for it to complete:
     `aws ec2 create-snapshot --volume-id <id> --description "before <change>"` (find the id with `terraform state show aws_ebs_volume.data`).
  2. Record row counts read-only:
     `scripts/ssh.sh "sudo python3 -c \"import sqlite3; c=sqlite3.connect('file:/var/lib/fade/db/fade.db?mode=ro', uri=True); print([(t, c.execute(f'select count(*) from {t}').fetchone()[0]) for t in ('users','friendships','messages','sessions')])\""`
- After it:
  1. The volume is attached to the new instance and mounted: `scripts/ssh.sh "findmnt /var/lib/fade && ls -la /var/lib/fade/db"`.
  2. Row counts are equal to or higher than before (sessions may expire).
  3. The site serves, and `/api/config` reports the expected build.
  If any of these fail, stop and tell the user before doing anything else. The snapshot is the way back.
- The boot script (`infra/user_data.sh.tftpl`) finds the data volume by serial, formats it **only** if it has no filesystem, and mounts it by UUID. Any change to that logic needs a test against a volume that already has data.

**In production**
- Production database access is read-only (`?mode=ro`) unless the user asks for a specific write.
- Don't create test accounts or test data in production. Functional testing happens locally. If a prod check truly needs an account, ask the user.

## How every change is tested

1. **Unit tests for new logic.** Rust: a `#[cfg(test)] mod tests` in the same file. Anything touching the database uses `db::tests::temp_db()`, a fresh migrated SQLite file. Web crypto: `tests/e2e/test_crypto_vectors.py`. Bug fixes get a test that fails without the fix.
2. **Run everything locally:** `scripts/test.sh`. It builds the server, starts it on a throwaway database, and runs unit tests, the independent crypto vector check, the API smoke test, and the browser tests (Playwright driving real Chrome). `--no-browser` skips the last part.
3. **Look at it.** For anything a person sees, drive the change in a browser against the local server (`tests/e2e/` shows how) and look at screenshots at desktop and phone width (390px). Tests prove behavior; screenshots catch layout.
4. **CI must pass** before anything ships: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `scripts/test.sh`, `terraform fmt -check`, `terraform validate`. Run fmt and clippy locally first.
5. **Keep tests with the code.** New browser tests go in `tests/e2e/test_*.py` using `common.py`. New API behavior gets a check in `tests/smoke_test.py`.

## Shipping

Deploying to production yourself is encouraged for now, as long as you verify afterwards.

- **Server:** the normal path is a `server-v*` tag through GitHub Actions ([RELEASING.md](docs/RELEASING.md)). `scripts/deploy.sh` (run from WSL) is the hotfix path, and builds from uncommitted code show as `<sha>-dirty`. Commit soon after so history matches what's live.
- **Infrastructure:** `terraform plan -out tf.plan`, read it (Rule 1), `terraform apply tf.plan`, `rm tf.plan`. Prefer `-target` when only one resource needs to change. Saved plans hold secrets in plain text; never commit them.
- **After every deploy, check production** without changing data:
  - `curl -s <url>/api/config` reports the new `build`.
  - The pages you changed load, and the assets carry your change (`curl -s <url>/app.js | grep ...`).
  - `scripts/ssh.sh "sudo journalctl -u fade --no-pager -n 30"` shows a clean start and no errors.
  - After infra changes, the data volume checks above.
- Follow the compatibility rules in [RELEASING.md](docs/RELEASING.md): server before clients, the API only grows, new encryption means a new message format (readers before writers), migrations are additive.

## Code standards

- Match the surrounding code: naming, comment density, error style. Comments explain *why*.
- User-facing errors say what happened and what to do, plainly (`AppError::bad("...")`).
- The web client has a strict CSP: no inline scripts or `style` attributes. Set styles through CSSOM (`el.style.height = ...`) and keep CSS in `style.css`. No third-party scripts, fonts, or CDNs.
- Keep the web client build-free. Add a dependency only when it does real work, and say why in the change.
- Encryption: anything in `crypto.js` that changes bytes on the wire is a new message format, never an edit to format 1. The pinned vectors in `tests/vectors/format1.json` are never regenerated. If they fail, the change is wrong. Update [how-napsack-works.md](docs/how-napsack-works.md) when the design changes.
- Never log, print, or commit secrets: tokens, auth keys, invite codes, `terraform.tfvars`, saved plans, or anything decrypted. The server never has plaintext, and logs and the admin panel show counts and events only.

## Environment notes

- Development is on Windows with WSL. Terraform state is the local file in `infra/`, shared by both. Terraform, `scripts/ssh.sh`, and `scripts/rollback.sh` work from Git Bash or WSL. `scripts/deploy.sh` needs WSL, because zig lives there. `scripts/test.sh` runs in either.
- Both machines' SSH keys are listed in `ssh_public_keys` (tfvars), and the boot script authorizes all of them. Add a key there for any new machine. Don't rely on `ssh_public_key_path`, which installs only whichever key is on the machine running terraform.
- From Git Bash, call WSL as `MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- bash -lc '...'`. Without the env var, Git Bash rewrites `/mnt/...` paths, and without `-l`, cargo isn't on PATH. For anything with nested quotes, write a script file and run that.
- `server/target` is shared between Windows and WSL builds: the Windows binary is `fade-server.exe`, the Linux one has no extension.
- `scripts/deploy.sh` needs zig, which lives in the WSL venv: `source server/.venv/bin/activate` first.
- Production shell: `scripts/ssh.sh` (SSH tunneled through SSM; port 22 is closed).
- Git on Windows doesn't record executable bits. A new script needs `git update-index --chmod=+x scripts/<name>.sh`, and CI calls scripts through `bash` anyway.
- Everything is LF (`.gitattributes`). A CRLF boot script would stop the server from starting and mounting its data, so don't override it.
- CI results are public: `https://api.github.com/repos/nathanielschutte/fade/actions/runs`. Check them after a push.

## Working together

- Track work in [docs/plan.md](docs/plan.md): pick from the top of the Tracker, update its status as you go, and add new ideas to an Epic first.
- When a decision is the user's (product wording, privacy trade-offs, anything irreversible), ask rather than guess, and record the answer in the plan or here.
- Commit only when asked. Group commits by change, in plain messages.
