# CLAUDE.md

How we work on napsack. This file is iterative: when we settle a new rule or pattern while working, add it here in the same change. If something here turns out wrong, fix it rather than working around it.

## What this is

napsack is a small private messenger: texts and view-once pictures between friends, end-to-end encrypted. `fade` is the internal name (binary, systemd unit, `FADE_*` env vars, AWS resources); `napsack` is what people see. Never rename the internals just to match.

Same for pictures: people see **pic** ("Tap to view pic", "Pics sent"); the code, API, database, and encryption strings say `snap` (`snap_state`, `/api/snaps`, `napsack/v1/snap/...`). Never show "snap" in the UI (`tests/e2e/test_chat.py` checks), and never rename the internal `snap` identifiers.

- `server/`: Rust (axum + SQLite). Serves the API and the web client, which is compiled into the binary.
- `server/static/`: web client. Plain HTML/CSS/ES modules, no build step, no framework.
- `shared/crypto/crypto.js`: the whole encryption scheme, used by every client. The server serves it to the web as `/crypto.js`; the iOS app bundles it. Nothing platform-specific goes in it (key storage lives with each client).
- `mobile/`: the iOS app (Expo, React Native, TypeScript). Plan and setup: [mobile.md](docs/mobile.md).
- `infra/`: Terraform for AWS (one EC2 instance, Caddy, a separate EBS data volume).
- `tests/`: API smoke test, browser tests, pinned crypto vectors. `scripts/`: test, deploy, rollback, ssh.
- `docs/`: [ONBOARDING.md](docs/ONBOARDING.md) (start here), [plan.md](docs/plan.md) (task tracker), [API.md](docs/API.md) (every endpoint and socket event; update it with any API change), [OPERATIONS.md](docs/OPERATIONS.md) (AWS, settings, shell), [SECURITY.md](docs/SECURITY.md) (protections, limits, what to do when attacked), [RELEASING.md](docs/RELEASING.md) (versioning and compatibility rules), [how-napsack-works.md](docs/how-napsack-works.md) (encryption), [group-encryption.md](docs/group-encryption.md) (how group chats are encrypted), [mobile.md](docs/mobile.md) (iOS plan).

The live site is <https://napsack.getattr.com>. The domain will change again: never hardcode it. Scripts read it from `terraform output url`.

## Rule 1: user data is never deleted

Every account, friendship, message, and the data volume that holds them must survive every change we make. No exceptions without the user's explicit, specific approval for that one action.

**In code and migrations**
- Migrations only add: new tables, nullable or defaulted columns, indexes. Never `DROP TABLE`/`COLUMN`, `DELETE FROM`, `RENAME`, `TRUNCATE`, or overwrite existing values. `db::tests::migrations_never_destroy_data` enforces this in CI; don't weaken it to get a change through.
- Application code never deletes rows either. When something ends, mark it: `friendships.ended_at`, `friend_requests.resolved_at`, `sessions.revoked_at`, and append to `friend_events` (history that's never updated). Every query that means "current" filters on those columns. `db::tests::code_never_deletes_rows` fails CI on any `DELETE FROM` in `server/src`. Encrypted pic files are the one designed exception: view-once means each file is discarded when opened or expired (30 days), and they aren't database rows. Unopened pics must survive restarts (they wait on the data volume; `tests/restart_test.py` checks).
- Removing a feature hides it; it doesn't delete its data.
- Credentials are replaced, never lost: anything that changes a password, key, or recovery key first copies the old values into `credential_history` (account.rs).
- Texts live forever. Anything that pages, trims, or caches must never remove rows.
- Migrations are never edited after release. Add a new one.
- Before releasing a new migration: `bash scripts/check-migrations.sh` (runs it against a copy of the newest production backup and checks no rows were lost), then take a fresh backup right before deploying: `scripts/ssh.sh "sudo systemctl start fade-backup"`.

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
2. **Run everything locally:** `bash scripts/test.sh` **in WSL**. It builds the server, starts it on a throwaway database, and runs unit tests, the independent crypto vector check, the API smoke test, and the browser tests (Playwright driving Chromium). `--no-browser` skips the last part. It can't run natively on Windows here; see Environment notes.
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
- Encryption: anything in `shared/crypto/crypto.js` that changes bytes on the wire is a new message format, never an edit to an existing one. The pinned vectors in `tests/vectors/` are never regenerated. Every client runs `shared/crypto/vector-checks.js` against them (Node in `scripts/test.sh`, the iPhone from the app). If they fail, the change is wrong. Update [how-napsack-works.md](docs/how-napsack-works.md) when the design changes.
- Never log, print, or commit secrets: tokens, auth keys, invite codes, `terraform.tfvars`, saved plans, or anything decrypted. The server never has plaintext, and logs and the admin panel show counts and events only.

## Security

**All human input is hostile until proven otherwise:** every field, header, file, and byte. Each rule below has a test that enforces it.

- **SQL is always parameterized.** Values are bound with `?`, never spliced into SQL. The only SQL built with `format!` splices UPPERCASE constants (shared column lists and subqueries). `db::tests::sql_only_interpolates_constants` fails the build otherwise. No `LIKE` on user input without escaping `%`/`_`.
- **Images the server can see are rebuilt, not passed along.** Group pictures, profile pictures, and old (format 0) group pics go through `images::clean`: they must be JPEG, PNG, or WebP; they're decoded by memory-safe Rust decoders with size and memory limits (no decompression bombs); and they're re-encoded as a fresh JPEG. Only that new file is stored or served, so hidden scripts, polyglots, malformed data, and EXIF/GPS never reach anyone. Image responses carry a sandboxing CSP and `nosniff`. Direct-chat pics and format 3 group pics are end-to-end encrypted, so the server only ever handles them as opaque bytes, and the receiving client decodes them. Any new image path the server can see must use `images::clean`.
- **Text is validated, then displayed as text.** Usernames are `[A-Za-z0-9_.]` only. Plaintext the server stores for others (group names, old format 0 group messages and captions, display names, nicknames, birthdays) rejects control characters and invisible or direction-changing characters (`text.rs`). Clients render user text with `textContent`, never `innerHTML`; `test_groups.py` sends an XSS payload and checks that nothing renders as HTML or runs.
- **Logs can't be forged.** User-typed strings are logged with `?` (Debug, escaped), never `%`.
- **Floods are capped, and caps are hard** (`guard.rs`; the full table is in [SECURITY.md](docs/SECURITY.md)): 100 accounts, 4 devices per person, a request budget per address, writes per address and per session, requests in flight, live sockets, friend requests and groups per day, and uploads and writes stop before the data disk fills. Scanners are refused and probing addresses banned. Anything new that's expensive or unbounded gets a limit, a test, and a row in that table.
- **Nothing sensitive is servable.** The server only serves files compiled into the binary (`web.rs`), never the file system, so the database, config, and source can't be reached by URL. Never add a file-serving route. (The one exception is development live reload: debug builds read the same fixed list of web app files from disk, never a path from a request, and it's compiled out of release builds; `scripts/deploy.sh` checks production doesn't answer `/dev/changes`.) API responses never include `auth_hash`/`token_hash`/passwords; session tokens and `wrapped_private_key` appear only in sign-up/sign-in responses. `tests/smoke_test.py` probes ~25 sensitive paths and sweeps every JSON response for these fields; add a probe or field when you add something sensitive.
- **Headers:** every response gets `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, COOP/CORP `same-origin`, and a restrictive `Permissions-Policy` (pages that need the camera set their own). Every API response is `Cache-Control: no-store`. Pages have a strict CSP.
- **Rate limits** (`ratelimit.rs`, in memory): sign-in and sign-up, 30 per address per 10 minutes; failed sign-ins, 10 per username per 15 minutes (checked before the slow password check, and applied to nonexistent usernames too so it reveals nothing); client logs, 300 per user per minute. Anything new that's expensive or guessable gets a limit.
- **Who's calling:** the real client address comes from Caddy's `X-Forwarded-For`, trusted only from a loopback peer (`ClientInfo`). Every request is logged with `ip`, `ua`, and `host`; search the log viewer for `ip=...` to see what an address did. Local un-proxied requests are exempt from per-address limits (tests and development).
- Errors returned to clients are plain user-facing text; internal details stay in the logs.
- **The server only sends to push services it knows** (`push.rs`, `PUSH_HOSTS`). A push subscription's endpoint comes from the browser, so it's untrusted: anything else would let a request make the server call arbitrary addresses, including AWS's internal ones. Notifications say who, never what.
- **Profiles are friends-only, enforced by the server.** Display names and profile pictures go to friends and no one else; a nickname goes only to whoever set it. They aren't end-to-end encrypted. The username is the identity: clients show `@username` wherever a name differs, and safety codes and key warnings use the username, so a display name can't impersonate anyone.
- **Group messages and pics are end-to-end encrypted (format 3, [group-encryption.md](docs/group-encryption.md)); a group's name and picture, and group reactions, aren't.** Every client says so in each group (Nate: the unencrypted picture especially). The server checks a sealed message's member list against the group (409 if it changed) and hands each member only their own key. Messages from before a group switched stay format 0, readable by the server: never log group message bodies of any format. Clients pin group members' keys like friends' and refuse to send to a group when one changes.

## Logging and debugging

- When something's wrong, start at `/admin#logs` (search, level filter, live tail). It holds the last 20,000 entries since the server started. Older history: `scripts/ssh.sh "sudo journalctl -u fade --since '1 hour ago'"`.
- Log with `tracing` and structured fields: `tracing::info!(user_id = me.id, friend_id, "friend request accepted")`. Short lowercase messages, and ids as fields so they're searchable (`user_id=7`).
- Levels: `error` for something broken that needs fixing, `warn` for something degraded (pool full), `info` for meaningful events (sign-ups, sign-ins, friendships, pics, rejected requests), `debug` for routine detail (each request, texts, sockets). The journal gets info and up; the viewer gets debug and up.
- Problems the apps report (warn and error) also go to the journal (target `napsack_client`), so they outlive restarts.
- Never log message content, ciphertext, keys, tokens, invite codes, passwords, or request bodies and query strings. `tests/e2e/test_admin.py` checks the logs for these.
- New features log their important events, and a user-visible failure always leaves a log line explaining it.
- Clients report too. In the web app, call `report(level, message, fields)` (it batches to `POST /api/logs`); the iOS app will do the same. These show in the viewer as "web app" / "ios app" (Source filter). The same never-log list applies, and the server redacts fields named like content or secrets as a backstop. Don't rely on that.

## Environment notes

- **Build and test in WSL.** Windows Smart App Control is on and blocks freshly compiled executables, so `cargo`, the local server, and `bash scripts/test.sh` run in WSL (`MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- bash -lc 'cd /mnt/c/Users/nates/Documents/code/fade && bash scripts/test.sh'`). Leave Smart App Control on; it can't be re-enabled without reinstalling Windows.
- **WSL test setup** (done; for a new machine): `python3 -m venv ~/.venvs/napsack-tests && ~/.venvs/napsack-tests/bin/pip install -r tests/requirements.txt && PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 ~/.venvs/napsack-tests/bin/python -m playwright install chromium`, plus `sudo apt-get install -y libnspr4 libnss3 libasound2t64`. `scripts/test.sh` finds the venv and Chromium on its own. Linux Chromium has different fonts than Windows Chrome, which is why layout checks run here.
- Development is on Windows with WSL. Terraform state is the local file in `infra/`, shared by both. Terraform, `scripts/ssh.sh`, and `scripts/rollback.sh` work from Git Bash or WSL. `scripts/deploy.sh` needs WSL, because zig lives there. `scripts/test.sh` runs in either.
- Both machines' SSH keys are listed in `ssh_public_keys` (tfvars), and the boot script authorizes all of them. Add a key there for any new machine. Don't rely on `ssh_public_key_path`, which installs only whichever key is on the machine running terraform.
- From Git Bash, call WSL as `MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- bash -lc '...'`. Without the env var, Git Bash rewrites `/mnt/...` paths, and without `-l`, cargo isn't on PATH. For anything with nested quotes, write a script file and run that.
- `server/target` is shared between Windows and WSL builds: the Windows binary is `fade-server.exe`, the Linux one has no extension.
- `scripts/deploy.sh` needs zig, which lives in the WSL venv: `source server/.venv/bin/activate` first.
- **Node lives in WSL too** (nvm, Node 24 LTS), for the shared crypto test and the iOS app. Non-interactive shells need `. ~/.nvm/nvm.sh`. Expo docs change every SDK: check the versioned docs for the SDK in `mobile/package.json` before writing Expo or EAS code (`mobile/AGENTS.md`).
- `wsl.exe` swallows `$VARIABLES` in commands passed from Git Bash. Put anything with variables in a script file and run `wsl.exe -d Ubuntu -- bash /mnt/c/.../script.sh`.
- Production shell: `scripts/ssh.sh` (SSH tunneled through SSM; port 22 is closed).
- Git on Windows doesn't record executable bits. A new script needs `git update-index --chmod=+x scripts/<name>.sh`, and CI calls scripts through `bash` anyway.
- Everything is LF (`.gitattributes`). A CRLF boot script would stop the server from starting and mounting its data, so don't override it.
- CI results are public: `https://api.github.com/repos/nathanielschutte/fade/actions/runs`. Check them after a push.

## Working together

- Track work in [docs/plan.md](docs/plan.md): pick from the top of the Tracker, update its status as you go, and add new ideas to an Epic first.
- When a decision is the user's (product wording, privacy trade-offs, anything irreversible), ask rather than guess, and record the answer in the plan or here.
- Commit only when asked. Group commits by change, in plain messages.
