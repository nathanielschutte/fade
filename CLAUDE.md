# CLAUDE.md

How we work on napsack. This file is iterative: when we settle a new rule or pattern while working, add it here in the same change. If something here turns out wrong, fix it rather than working around it.

## What this is

napsack is a small private messenger: texts and view-once pictures between friends, end-to-end encrypted. `fade` is the internal name (binary, systemd unit, `FADE_*` env vars, AWS resources); `napsack` is what people see. Never rename the internals just to match.

Same for pictures: people see **pic** ("Tap to view pic", "Pics sent"); the code, API, database, and encryption strings say `snap` (`snap_state`, `/api/snaps`, `napsack/v1/snap/...`). Never show "snap" in the UI (`tests/e2e/test_chat.py` checks), and never rename the internal `snap` identifiers.

- `server/`: Rust (axum + SQLite). Serves the API and the web client, which is compiled into the binary.
- `server/static/`: web client. Plain HTML/CSS/ES modules, no build step, no framework.
- `shared/crypto/crypto.js`: the whole encryption scheme, as the web client runs it (the server serves it as `/crypto.js`), and the reference every other implementation is held to. Nothing platform-specific goes in it (key storage lives with each client).
- `ios/`: the iOS app, native Swift (SwiftUI, Xcode), being started; it implements the same formats with CryptoKit, held to the pinned vectors. An Android app in Kotlin comes later (`android/`). `mobile/` is the retired Expo prototype, removed once `ios/` passes every vector. Plan: [mobile.md](docs/design/mobile.md).
- `infra/`: Terraform for AWS (one EC2 instance, Caddy, a separate EBS data volume).
- `infra/staging/`: a separate copy at staging.napsack.io with its own state and no user data, for browser and load tests against a real deployment ([staging.md](docs/operations/staging.md)).
- `tests/`: API smoke test, browser tests, pinned crypto vectors. `scripts/`: test, deploy, rollback, ssh.
- `docs/`: file names are lowercase (hyphens between words), grouped into folders by what they're for, and docs link to each other with relative paths. New docs follow the same pattern. Docs, the plan, and code comments describe napsack on its own terms: never name other apps as the model for a feature. Start with [onboarding.md](docs/onboarding.md), which also sets up a development machine (macOS, Linux, or Windows through WSL).
  - `docs/` itself: [onboarding.md](docs/onboarding.md) (start here), [how-napsack-works.md](docs/how-napsack-works.md) (encryption, and what the server can and can't see), [security.md](docs/security.md) (protections, limits, what to do when attacked).
  - `docs/spec/`: [api.md](docs/spec/api.md) (every endpoint and socket event; update it with any API change).
  - `docs/implementation/`: how built features work: [group-encryption.md](docs/implementation/group-encryption.md), [roles.md](docs/implementation/roles.md) (User, PowerUser, Admin), [admin-users.md](docs/implementation/admin-users.md) (System → Users: turning accounts off, announcements), [team-napsack.md](docs/implementation/team-napsack.md) (napsack's own account and its scheduled messages, `server/occasions.toml`), [friend-graph.md](docs/implementation/friend-graph.md), [metrics.md](docs/implementation/metrics.md) (the Metrics tab), [health-monitor.md](docs/implementation/health-monitor.md), [qr.md](docs/implementation/qr.md).
  - `docs/operations/`: running it: [operations.md](docs/operations/operations.md) (AWS, settings, shell), [releasing.md](docs/operations/releasing.md) (versioning and compatibility rules), [backups.md](docs/operations/backups.md), [staging.md](docs/operations/staging.md), [domain-move.md](docs/operations/domain-move.md).
  - `docs/design/`: proposals and plans not built yet: [mobile.md](docs/design/mobile.md) (iOS plan), [mono-scaling.md](docs/design/mono-scaling.md) (growing the single server), [horizontal-scaling.md](docs/design/horizontal-scaling.md) (two or more servers), [email.md](docs/design/email.md).
  - `docs/management/`: [plan.md](docs/management/plan.md) (the task tracker).

The live site is <https://napsack.io> (the old napsack.getattr.com redirects; docs/operations/domain-move.md). The domain may change again: never hardcode it. Scripts read it from `terraform output url`.

## Rule 1: user data is never deleted

Every account, friendship, message, and the data volume that holds them must survive every change we make. No exceptions without the user's explicit, specific approval for that one action.

**In code and migrations**
- Migrations only add: new tables, nullable or defaulted columns, indexes. Never `DROP TABLE`/`COLUMN`, `DELETE FROM`, `RENAME`, `TRUNCATE`, or overwrite existing values. `db::tests::migrations_never_destroy_data` enforces this in CI; don't weaken it to get a change through.
- Application code never deletes rows either. When something ends, mark it: `friendships.ended_at`, `friend_requests.resolved_at`, `sessions.revoked_at`, a turned-off account's row in `deactivations` (admin_users.rs), and append to `friend_events` (history that's never updated). Every query that means "current" filters on those columns. `db::tests::code_never_deletes_rows` fails CI on any `DELETE FROM` in `server/src`. Encrypted pic files are the one designed exception: view-once means each file is discarded when opened or expired (30 days), and they aren't database rows. Unopened pics must survive restarts (they wait on the data volume; `tests/restart_test.py` checks). `metrics.db` (the admin Metrics tab, `metrics.rs`) is not user data and not the app database: it's a fixed ring of per-minute readings that overwrites itself, so it never grows.
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
- Any change to the boot script (`infra/user_data.sh.tftpl`), even a comment, replaces the production instance (and staging's, which renders the same file). Leave it out of bulk edits such as search-and-replace, and change it only when the instance should be replaced.
- The boot script (`infra/user_data.sh.tftpl`) finds the data volume by serial, formats it **only** if it has no filesystem, and mounts it by UUID. Any change to that logic needs a test against a volume that already has data.

**In production**
- Production database access is read-only (`?mode=ro`) unless the user asks for a specific write.
- Don't create test accounts or test data in production. Functional testing happens locally. If a prod check truly needs an account, ask the user.

## How every change is tested

1. **Unit tests for new logic.** Rust: a `#[cfg(test)] mod tests` in the same file. Anything touching the database uses `db::tests::temp_db()`, a fresh migrated SQLite file. Web crypto: `tests/e2e/test_crypto_vectors.py`. Bug fixes get a test that fails without the fix.
2. **Run everything locally:** `bash scripts/test.sh`. It builds the server, starts it on a throwaway database, and runs unit tests, the independent crypto vector check, the API smoke test, and the browser tests (Playwright driving Chromium). `--no-browser` skips the last part. Setup for each system is in [onboarding.md](docs/onboarding.md); on Windows it runs in WSL.
3. **Look at it.** For anything a person sees, drive the change in a browser against the local server (`tests/e2e/` shows how) and look at screenshots at desktop and phone width (390px). Tests prove behavior; screenshots catch layout.
4. **CI must pass** before anything ships: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `scripts/test.sh`, `terraform fmt -check`, `terraform validate`. Run fmt and clippy locally first.
5. **Keep tests with the code.** New browser tests go in `tests/e2e/test_*.py` using `common.py`. New API behavior gets a check in `tests/smoke_test.py`.
6. **Loading states end.** Anything that shows a placeholder while it loads ("Loading…", skeleton rows) replaces it with what arrives, never adds beside it. Its browser test calls `no_placeholders(page, scope)` (`common.py`) after checking the loaded data, so a placeholder left on screen fails the test.

## Shipping

Every change reaches `main` through a pull request, the owner's included. The full workflow, for contributors, is in [onboarding.md](docs/onboarding.md) (Working together).

- **Pull requests.** Work on a branch (`<name>/<topic>`); open a pull request with a description that follows `.github/pull_request_template.md` (what and why, how it's tested, risk, docs and plan). CI must pass on it, and the owner (CODEOWNERS) approves the latest push. The owner squash-merges, so `main` gets one commit per pull request, titled and described as the pull request was. Admins can bypass the branch rules; don't, except for a production emergency, and then open a pull request for the same change straight after.
- **Server releases are the owner's** ([releasing.md](docs/operations/releasing.md)). Merging to `main` makes a release candidate (`releases/main/fade-server-<sha>`) and puts it on staging. After checking staging, the version bump goes in through a pull request, and the owner tags it `server-v<version>`: the same binary goes to production as `releases/tags/fade-server-<version>`, after a backup. Release tags are protected (Admins only), and the production environment deploys only from `server-v*` tags; staging only from `main`. `scripts/deploy.sh` is the owner's hotfix path; builds from uncommitted code show as `<sha>-dirty`, so follow a hotfix with a pull request and a tag soon after so a tagged release is live again.
- **Staging:** runs the newest build of `main` (CI deploys it); `FADE_STACK=staging scripts/deploy.sh` puts a local build there instead. `scripts/test-staging.sh` runs the smoke and browser tests against it, and `scripts/load-staging.sh` load tests it. Staging must never be able to reach production's settings, data, backups, or releases ([staging.md](docs/operations/staging.md) lists how); after a staging apply, `terraform plan` in `infra/` still says "No changes". `FADE_EXEMPT_ADDRESSES` is for staging only; never set it in production.
- **Infrastructure** (the owner's): `terraform plan -out tf.plan`, read it (Rule 1), `terraform apply tf.plan`, `rm tf.plan`. Prefer `-target` when only one resource needs to change. Saved plans hold secrets in plain text; never commit them.
- **After every deploy, check production** without changing data:
  - `curl -s <url>/api/config` reports the new `build`.
  - The pages you changed load, and the assets carry your change (`curl -s <url>/app.js | grep ...`).
  - `scripts/ssh.sh "sudo journalctl -u fade --no-pager -n 30"` shows a clean start and no errors.
  - After infra changes, the data volume checks above.
- Follow the compatibility rules in [releasing.md](docs/operations/releasing.md): server before clients, the API only grows, new encryption means a new message format (readers before writers), migrations are additive.

## Code standards

- Match the surrounding code: naming, comment density, error style. Comments explain *why*.
- User-facing errors say what happened and what to do, plainly (`AppError::bad("...")`).
- Non-production copies are marked on top of the design: `FADE_ENVIRONMENT` (staging sets `staging`), `server/static/env.js`, and the "non-production copies" section of `style.css`, keyed on `<html data-env>`. Design work never accounts for it, and production never sets it.
- The web client has a strict CSP: no inline scripts or `style` attributes. Set styles through CSSOM (`el.style.height = ...`) and keep CSS in `style.css`. No third-party scripts, fonts, or CDNs.
- Keep the web client build-free. Add a dependency only when it does real work, and say why in the change.
- Encryption: anything that changes bytes on the wire is a new message format, never an edit to an existing one, and it lands in every implementation (`shared/crypto/crypto.js` first, then the Swift and later Kotlin ports). The pinned vectors in `tests/vectors/` are never regenerated: a new format gets a new vector file, generated once, with an independent Python check (`tests/vectors/check_*.py`). The web crypto runs `shared/crypto/vector-checks.js` against them (Node, in `scripts/test.sh`); each native app runs the same checks in its own test suite. If they fail, the change is wrong. Update [how-napsack-works.md](docs/how-napsack-works.md) when the design changes.
- Never log, print, or commit secrets: tokens, auth keys, invite codes, `terraform.tfvars`, saved plans, or anything decrypted. The server never has plaintext, and logs and the admin panel show counts and events only.

## Security

**All human input is hostile until proven otherwise:** every field, header, file, and byte. Each rule below has a test that enforces it.

- **SQL is always parameterized.** Values are bound with `?`, never spliced into SQL. The only SQL built with `format!` splices UPPERCASE constants (shared column lists and subqueries). `db::tests::sql_only_interpolates_constants` fails the build otherwise. No `LIKE` on user input without escaping `%`/`_`.
- **Images the server can see are rebuilt, not passed along.** Group pictures, profile pictures, and old (format 0) group pics go through `images::clean`: they must be JPEG, PNG, or WebP; they're decoded by memory-safe Rust decoders with size and memory limits (no decompression bombs); and they're re-encoded as a fresh JPEG. Only that new file is stored or served, so hidden scripts, polyglots, malformed data, and EXIF/GPS never reach anyone. Image responses carry a sandboxing CSP and `nosniff`. Direct-chat pics and format 3 group pics are end-to-end encrypted, so the server only ever handles them as opaque bytes, and the receiving client decodes them. Any new image path the server can see must use `images::clean`.
- **Text is validated, then displayed as text.** Usernames are `[A-Za-z0-9_.]` only. Plaintext the server stores for others (group names, old format 0 group messages and captions, display names, nicknames, birthdays) rejects control characters and invisible or direction-changing characters (`text.rs`). Clients render user text with `textContent`, never `innerHTML`; `test_groups.py` sends an XSS payload and checks that nothing renders as HTML or runs.
- **Logs can't be forged.** User-typed strings are logged with `?` (Debug, escaped), never `%`.
- **Floods are capped, and caps are hard** (`guard.rs`; the full table is in [security.md](docs/security.md)): 100 accounts, 4 devices per person, a request budget per address, writes per address and per session, requests in flight, live sockets, friend requests and groups per day, and uploads and writes stop before the data disk fills. Scanners are refused and probing addresses banned. Anything new that's expensive or unbounded gets a limit, a test, and a row in that table.
- **Nothing sensitive is servable.** The server only serves files compiled into the binary (`web.rs`), never the file system, so the database, config, and source can't be reached by URL. Never add a file-serving route. (The one exception is development live reload: debug builds read the same fixed list of web app files from disk, never a path from a request, and it's compiled out of release builds; `scripts/deploy.sh` checks production doesn't answer `/dev/changes`.) API responses never include `auth_hash`/`token_hash`/passwords; session tokens and `wrapped_private_key` appear only in sign-up/sign-in responses. `tests/smoke_test.py` probes ~25 sensitive paths and sweeps every JSON response for these fields; add a probe or field when you add something sensitive.
- **Headers:** every response gets `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, COOP/CORP `same-origin`, and a restrictive `Permissions-Policy` (pages that need the camera set their own). Every API response is `Cache-Control: no-store`. Pages have a strict CSP.
- **Rate limits** (`ratelimit.rs`, in memory): sign-in and sign-up, 30 per address per 10 minutes; failed sign-ins, 10 per username per 15 minutes (checked before the slow password check, and applied to nonexistent usernames too so it reveals nothing); client logs, 300 per user per minute. Anything new that's expensive or guessable gets a limit.
- **Who's calling:** the real client address comes from Caddy's `X-Forwarded-For`, trusted only from a loopback peer (`ClientInfo`). Every request is logged with `ip`, `ua`, and `host`; search the log viewer for `ip=...` to see what an address did. Local un-proxied requests are exempt from per-address limits (tests and development).
- Errors returned to clients are plain user-facing text; internal details stay in the logs.
- **The server only calls addresses fixed in its code:** push services it knows, and AWS for the System pages (`aws.rs`: instance metadata, CloudWatch, Cost Explorer, SSM for the admin list, and S3 for the health monitor's incident records; read-only except adding a resolution; credentials never logged). S3 keys are built in the code; an incident id from a request must match the monitor's format first. Never let a request choose where the server connects.
- **The server only sends to push services it knows** (`push.rs`, `PUSH_HOSTS`). A push subscription's endpoint comes from the browser, so it's untrusted: anything else would let a request make the server call arbitrary addresses, including AWS's internal ones. Notifications say who, never what.
- **Roles are checked by the server on every request** (`roles.rs`, [roles.md](docs/implementation/roles.md)): User, PowerUser, Admin. PowerUser is for curiosity, never more private data or acting on others: no users table, reset codes, logs, or cost, and on the graph everyone they aren't friends with is anonymous (no id, no username, per-viewer aliases). Admins come from settings (the `/fade/admins` SSM parameter), never the database. Anything new on the System pages states its role, sends nothing the role can't see (hiding in the page isn't enough), and gets a row in `check_roles`.
- **The friend map shows only what you already know, plus anonymous structure** (`graph.rs`, [friend-graph.md](docs/implementation/friend-graph.md)): your friends and who among them knows who, and a `?` for each friend of a friend, with no id, name, or picture, in shuffled order. Only ever your own map; the admin graph (usernames) is admins-only. `check_graph` in the smoke test.
- **Team Napsack is the one account the server writes for** (`team.rs`, [team-napsack.md](docs/implementation/team-napsack.md)): its messages are end-to-end encrypted to each recipient like a friend's, so the server knows only what it wrote itself. It can't sign in, be found, be messaged, or be acted on by Admins. Its key is never replaced. New system accounts go in `system_accounts`, never by special-casing a username.
- **Profiles are friends-only, enforced by the server.** Display names and profile pictures go to friends and no one else; a nickname goes only to whoever set it. They aren't end-to-end encrypted. The username is the identity: clients show `@username` wherever a name differs, and safety codes and key warnings use the username, so a display name can't impersonate anyone.
- **Group messages and pics are end-to-end encrypted (format 3, [group-encryption.md](docs/implementation/group-encryption.md)); a group's name and picture, and group reactions, aren't.** Every client says so in each group (Nate: the unencrypted picture especially). The server checks a sealed message's member list against the group (409 if it changed) and hands each member only their own key. Messages from before a group switched stay format 0, readable by the server: never log group message bodies of any format. Clients pin group members' keys like friends' and refuse to send to a group when one changes. History starts when you join: a group message, new or updated (reactions, "opened by"), goes only to members whose history includes it (`groups::audience`; `check_late_joiner` in the smoke test).

## Logging and debugging

- When something's wrong, start at `/admin#logs` (search, level filter, live tail). It holds the last 20,000 entries since the server started. Older history: `scripts/ssh.sh "sudo journalctl -u fade --since '1 hour ago'"`.
- Log with `tracing` and structured fields: `tracing::info!(user_id = me.id, friend_id, "friend request accepted")`. Short lowercase messages, and ids as fields so they're searchable (`user_id=7`).
- Levels: `error` for something broken that needs fixing, `warn` for something degraded (pool full), `info` for meaningful events (sign-ups, sign-ins, friendships, pics, rejected requests), `debug` for routine detail (each request, texts, sockets). The journal gets info and up; the viewer gets debug and up.
- Problems the apps report (warn and error) also go to the journal (target `napsack_client`), so they outlive restarts.
- Never log message content, ciphertext, keys, tokens, invite codes, passwords, or request bodies and query strings. `tests/e2e/test_admin.py` checks the logs for these.
- New features log their important events, and a user-visible failure always leaves a log line explaining it.
- Clients report too. In the web app, call `report(level, message, fields)` (it batches to `POST /api/logs`); the iOS app will do the same. These show in the viewer as "web app" / "ios app" (Source filter). The same never-log list applies, and the server redacts fields named like content or secrets as a backstop. Don't rely on that.

## Environment notes

Setting up a machine (macOS, Linux, or Windows through WSL) is in [onboarding.md](docs/onboarding.md). These notes apply on any of them:

- `scripts/test.sh` finds the test environment in `~/.venvs/napsack-tests` (or `$PYTHON`) and Playwright's Chromium on its own. Non-interactive shells may not load nvm; the script loads `~/.nvm/nvm.sh` itself when `node` isn't on the path. Layout checks are made with Linux Chromium, as in CI, because fonts differ between systems.
- `scripts/test-one.sh <test_file.py>` runs one browser test (or `smoke`) against a fresh server; set `PORT` to run two at once.
- The owner's tools: Terraform (state is a local file in `infra/`, on the owner's machine), the AWS CLI (use AWS's official build: some distribution-packaged builds fail on `aws s3api` and `aws ssm` with "badly formed help string"), and for hotfix deploys, cargo-zigbuild with zig (`pip install ziglang`). Every machine that runs Terraform or `scripts/ssh.sh` needs its public key in `ssh_public_keys` (tfvars); the boot script authorizes all of them.
- Production shell: `scripts/ssh.sh` (SSH tunneled through SSM; port 22 is closed).
- iOS work needs a Mac with Xcode. Look up Apple's current documentation for the Xcode and iOS versions in use before writing platform code.
- A new script needs its executable bit recorded (`git update-index --chmod=+x scripts/<name>.sh`) where the file system doesn't keep it; CI calls scripts through `bash` anyway.
- Everything is LF (`.gitattributes`). A CRLF boot script would stop the server from starting and mounting its data, so don't override it.
- CI results are public: `https://api.github.com/repos/nathanielschutte/fade/actions/runs`. Check them after a push.

## Working together

More than one person works on napsack: the owner (Nate: the app's Admin and the repository's, who merges, releases, and runs production) and contributors (branches and pull requests). Each may have a Claude session, so:

- **Before starting anything, look at what's in flight:** open pull requests (`gh pr list`; if `gh` isn't installed, the GitHub API at `https://api.github.com/repos/nathanielschutte/fade/pulls` or the repository's page) and the Tracker in [plan.md](docs/management/plan.md), especially its **Who** column. If the work overlaps something open, say so and ask before going on. Look again before opening a pull request.
- **Track every piece of work in [plan.md](docs/management/plan.md),** in its format: a Tracker row (with **Who** set to the person you're working for, e.g. "Claude for Nate") linked to an entry in an Epic, with the status kept current as you go and the plan change included in the same pull request. New ideas go into an Epic first. Pick from the top of the Tracker.
- When a decision is the owner's (product wording, privacy trade-offs, anything irreversible, anything that changes production), ask rather than guess, and record the answer in the plan or here.
- Commit and open pull requests when the person you're working for asks; Nate has asked for ongoing shipping. Group commits by change, in plain messages; the pull request's description says what and why.
