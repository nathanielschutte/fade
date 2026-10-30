# Onboarding

You know what napsack does. This gets you from there to changing it: how the pieces fit, setting up your machine, where things live, how it runs in production, how we work together, the daily loop, and the handful of rules that matter. Read it once top to bottom, then keep it open while you build your first feature (pick one from the top of the [plan](management/plan.md)'s Tracker).

Two kinds of people work on napsack:
- **The owner** (Nate): an Admin of the app and the repository. Merges pull requests, releases, and runs production (AWS, Terraform, settings).
- **Contributors**: work on branches and open pull requests. Everything you need runs on your own machine; you don't need access to AWS or production.

Most of this doc is for both. Where something is the owner's alone, it says so.

## The picture

```
 phone / browser                        one small AWS server (napsack.io)
┌──────────────────────┐   HTTPS    ┌──────────────────────────────────────────┐
│ web app (app.js)     │ ─────────▶ │ Caddy (TLS)                              │
│  · encrypts/decrypts │   /api/*   │   └▶ fade-server (Rust, axum)            │
│    (crypto.js)       │ ◀───────── │        · REST API + one WebSocket        │
│  · keys in IndexedDB │  WebSocket │        · serves the web app's files      │
│  · service worker    │ ◀═════════ │        └▶ SQLite + pic files (data disk) │
│    (notifications)   │   events   └──────────────────────────────────────────┘
└──────────────────────┘                  ▲ every 5 min: healthy?
                                          │
                              health monitor (AWS Lambda)
```

- **One binary.** The Rust server answers the API, holds every live WebSocket, and serves the web app. The web app's files are compiled into the binary (`include_str!` in `server/src/web.rs`), so a deploy is one file.
- **The browser does the cryptography.** Direct chats and group chats are end-to-end encrypted: the server stores and relays ciphertext it can't read. That's why a lot of logic lives in the client: decrypting, deciding what a message says, showing it. [how-napsack-works.md](how-napsack-works.md) explains the scheme; it's worth reading before you touch anything that sends or shows a message.
- **The WebSocket pushes changes; the API is the truth.** When something changes, the server sends a small event ("friends changed", "new message"), and the app refetches or updates what it shows. After any reconnect the app refetches everything, so a missed event is never a bug.
- **SQLite on its own disk.** One file, backed up every hour. Nothing in it is ever deleted (more below).
- **`fade` and `napsack`.** `fade` is the internal name (the binary, the systemd unit, `FADE_*` settings, AWS resources); `napsack` is what people see. Likewise pictures are **pics** to people and `snap` in code. Never rename one to match the other.

## Your machine

napsack builds and runs on macOS and Linux. On Windows, use WSL (Windows Subsystem for Linux): the scripts are written for a Unix shell, and Windows' Smart App Control can block freshly compiled programs.

**What you need:**

| Tool | For |
|---|---|
| git | the code |
| Rust (stable, through [rustup](https://rustup.rs)) | the server |
| Python 3.12 or newer | the smoke test, browser tests, and vector checks |
| Node.js 24 LTS | the shared crypto's tests (`node --test`) |
| Chromium, through Playwright | the browser tests |
| sqlite3 (optional) | looking inside your local database |
| Xcode (macOS only) | the iOS app ([ios-onboarding.md](ios-onboarding.md)) |

**macOS:**

```sh
xcode-select --install                       # compilers and git
brew install python node sqlite              # with Homebrew (https://brew.sh)
curl https://sh.rustup.rs -sSf | sh          # Rust
```

With Xcode installed, point the command line at it (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`), and keep the separate Command Line Tools current too (System Settings › Software Update): Homebrew refuses to install anything while they trail Xcode, whichever one is selected.

**Linux** (Debian or Ubuntu; other distributions have the same packages under similar names):

```sh
sudo apt-get install -y build-essential git curl python3-venv sqlite3
curl https://sh.rustup.rs -sSf | sh          # Rust
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash && nvm install 24   # Node
```

**Windows:** install WSL with Ubuntu (`wsl --install` in an administrator PowerShell, then restart), open the Ubuntu terminal, and follow the Linux steps there. Keep the code inside WSL's own disk (`~/code/fade`), not under `/mnt/c`: builds and tests are several times faster. VS Code's WSL extension opens it from Windows (`code .` in the Ubuntu terminal), and your Windows browser reaches the local server at `http://127.0.0.1:8080`.

**Then, on any of them:**

```sh
git clone https://github.com/nathanielschutte/fade.git && cd fade
python3 -m venv ~/.venvs/napsack-tests
~/.venvs/napsack-tests/bin/pip install -r tests/requirements.txt
~/.venvs/napsack-tests/bin/python -m playwright install --with-deps chromium
bash scripts/test.sh                         # everything; the first build takes a few minutes
```

`make` lists the everyday commands, each a short name for a script: `make test` (that same run), `make test-fast` (no browser), `make browser T=test_chat.py`, `make smoke`, `make lint` (fmt and clippy, as CI checks), `make run` (the server on port 8080, you as an Admin), and on a Mac `make ios` (the iOS app's tests, live against a fresh server). Nothing in it deploys or touches production.

`scripts/test.sh` finds that test environment (or uses `$PYTHON`) and Playwright's Chromium on its own. If Playwright says it doesn't support your Linux version, set `PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64` before installing and running. Fonts differ between systems, which is why layout checks are made against the same Linux Chromium that CI uses.

**Run it:**

```sh
cd server
FADE_ADMINS=you cargo run          # http://127.0.0.1:8080
```

That makes `server/fade.db` (your local database) and `server/pics/` next to it, both ignored by git. Sign up as `you` and as a second account in a private window, befriend yourself, and you have both ends of a conversation. `FADE_ADMINS=you` makes `you` an Admin, so the **System** button (gear icon) appears and every System tab works, logs included ([Roles](#roles-and-the-system-page) below). To start fresh, stop the server and delete `fade.db` and `pics/`.

**Edit and see it, no rebuild.** While you run with `cargo run`, the server reads the web app's files from disk on every request and the page watches for changes:

- Save `style.css` and the new styles appear in about a second, in place: you keep the chat or dialog you had open. Good for trying colors and spacing.
- Save `app.js`, `index.html`, or another script, and the page reloads by itself (you stay signed in, back on the chat list).
- Change Rust code and restart `cargo run`; the page reloads once the server is back.

This is development only. Release builds serve the copies compiled into the binary and don't have the reload code at all (`server/src/web.rs`); `scripts/deploy.sh` checks that after every deploy.

Things that need AWS (CPU credits and cost on the Metrics tab, health monitor incidents, the admin list in SSM) say so and stay empty locally. Everything else works the same.

## Follow one message

The fastest way to learn the code is to follow a text from one person to another. Open these as you read.

1. **Typing and pressing Enter**: `server/static/app.js`, the `#composer` submit handler (section `conversation`). It gets the chat key (`keyFor`), encrypts with `e2e.encryptText2` from `shared/crypto/crypto.js`, and calls `getJSON("/chats/<friend>/messages", { method: "POST", ... })` with a `client_id`, so a retry after a dropped connection doesn't send it twice.
2. **The route**: `server/src/main.rs`, `fn router`: every URL and the function that answers it. `/chats/{friend_id}/messages` → `chats::send_text`.
3. **The handler**: `server/src/chats.rs`, `send_text`. The shape of every handler: `AuthUser(me)` (who's asking; it rejects anyone not signed in), check the rules (`require_friend`), validate input, one SQL statement, then tell people.
4. **Telling people**: `state.hub.send_both(...)` in `server/src/ws.rs` pushes a `message` event down the WebSocket to both people's open apps, and `push::notify` sends a notification to the friend's devices that don't have napsack on screen.
5. **The other end**: `app.js`, `handleEvent` (section `realtime`), `case "message"`: `upsertMessage` decrypts it (`decrypt`), and `renderMessages` draws the chat.

Almost every feature is this loop: **UI event → API call → handler (rules, SQL) → event → other clients update.** Group chats are the same loop with one more step on each end: the sender encrypts the message once and wraps its key for every member (`groups.rs` checks the member list matches), and each member unwraps only their own copy ([group-encryption.md](implementation/group-encryption.md)).

## Where things live

**Server** (`server/src/`), one file per area:

| File | What's there |
|---|---|
| `main.rs` | Startup, settings (`Config`), shared state (`AppState`), **all routes** (`fn router`), request middleware |
| `auth.rs`, `account.rs` | Sign up/in/out and sessions; password change, recovery keys, admin reset codes |
| `friends.rs`, `invites.rs` | The chat list (`list_chats`), friend requests, unfriending; invite links and QR codes |
| `chats.rs`, `snaps.rs` | Direct texts; direct pics (encrypted files on the data disk until opened) |
| `groups.rs`, `group_pics.rs` | Group chats, members, group pics and group pictures |
| `people.rs`, `profiles.rs`, `birthdays.rs` | Display names, private nicknames, profile pictures; the profile page; birthdays |
| `reactions.rs`, `presence.rs`, `streaks.rs`, `marks.rs` | Reactions; typing and "active now"; pic streaks; favorites, hidden and muted chats |
| `push.rs` | Notifications (Web Push) |
| `ws.rs` | The WebSocket: who's connected (`Hub`), and every event type (`enum Event`) |
| `graph.rs` | The friend map, and the System graph; decides what each person may see |
| `roles.rs` | User, PowerUser, Admin: who's which, and `roles::require` for every System endpoint |
| `admin.rs`, `logs.rs`, `metrics.rs`, `sysinfo.rs` | The System page: overview counts, the log viewer, the Metrics tab and its readings |
| `team.rs`, `occasions.rs` | Team Napsack, napsack's own account, and its scheduled messages (`server/occasions.toml`) |
| `admin_users.rs`, `announcements.rs` | System → Users: accounts turned off and on, signed out, unlocked, and the record of Admin actions; the Admins' announcement banner |
| `health.rs`, `incidents.rs` | `GET /api/health` for the outside monitor; the monitor's incidents on the Metrics tab |
| `aws.rs` | The few AWS calls the server makes (CloudWatch, Cost Explorer, SSM, S3), signed by hand |
| `guard.rs`, `ratelimit.rs`, `text.rs`, `images.rs` | Protection: limits and bans, rate limits, input checks, image cleaning |
| `version.rs`, `web.rs`, `error.rs` | Client version rules; the compiled-in web files; errors as plain user-facing messages |
| `db.rs` | Connecting, shared helpers, and the **guard tests** that enforce the rules below |

The database schema is `server/migrations/`, one numbered file per change, read in order.

**Web app** (`server/static/`):
- `index.html` (every screen and dialog, mostly hidden until used), `style.css`, and `app.js`, one file split into sections marked `// ---------- name ----------` (auth, conversation, groups, profiles, friends, notifications, ...). Search for the section, not the line number. `el(...)` builds elements, `$(...)` finds one, `api`/`getJSON` call the server, `report(...)` sends a diagnostic to the log viewer.
- `admin.html` and `admin.js`: the System page.
- Smaller modules: `keystore.js` (keys in IndexedDB), `draw.js` (drawing on pics), `qr.js` (invite QR codes), `graph-view.js` (drawing the friend map), `sw.js` (the service worker: notifications).

**Shared** (`shared/`): `crypto/crypto.js` is the whole encryption scheme as the web app runs it, and the reference the native apps' own implementations are held to; `vector-checks.js` proves a client gets the pinned bytes right. `graph/graph.js` is the friend map's math (clusters, layout).

**iOS app**: native Swift in `ios/`; setting up Xcode and an iPhone, building, testing, and how it's put together are in [ios-onboarding.md](ios-onboarding.md). An Android app in Kotlin comes later. Plan: [mobile.md](design/mobile.md).

**Infrastructure** (`infra/`): Terraform for everything in AWS ([Production](#production) below). `infra/staging/` is a separate copy for testing.

**Tests** (`tests/`):
- `smoke_test.py` drives the API directly (one `check_*` function per area, including `check_roles`, the full role matrix).
- `e2e/test_*.py` drive real browsers through whole features, several at a time (`e2e/run.py`), with their shared helpers in `e2e/common.py`.
- `vectors/` pin the encryption's exact bytes; they're never regenerated.
- `restart_test.py` (unopened pics survive a restart) and `health_monitor_test.py` (the monitor's decisions, with AWS faked).
- `load_test.py` load tests staging, never production.

**Scripts** (`scripts/`): `test.sh` (everything), `test-one.sh` (one browser test, or `smoke`), `deploy.sh` and `ssh.sh` (production by default; `FADE_STACK=staging` for staging), `rollback.sh` (production's previous release), `check-migrations.sh` and `restore-drill.sh` (backups), `set-admins.sh` and `reload-admins.sh` (who's an Admin), `test-staging.sh` and `load-staging.sh`.

**Docs** (`docs/`), lowercase names, grouped by what they're for:

| Folder | What's in it |
|---|---|
| `docs/` | This file; [how-napsack-works.md](how-napsack-works.md) (the encryption, and what the server can and can't see); [security.md](security.md) (protections, limits, what to do when attacked) |
| `spec/` | [api.md](spec/api.md): every endpoint and socket event |
| `implementation/` | How built features work: [group-encryption](implementation/group-encryption.md), [roles](implementation/roles.md), [admin-users](implementation/admin-users.md), [team-napsack](implementation/team-napsack.md), [friend-graph](implementation/friend-graph.md), [metrics](implementation/metrics.md), [health-monitor](implementation/health-monitor.md), [qr](implementation/qr.md) |
| `operations/` | Running it: [operations](operations/operations.md) (AWS, settings, shell, cost), [releasing](operations/releasing.md), [backups](operations/backups.md), [staging](operations/staging.md), [domain-move](operations/domain-move.md) |
| `design/` | Proposals and plans not built yet: [mobile](design/mobile.md), [mono-scaling](design/mono-scaling.md), [horizontal-scaling](design/horizontal-scaling.md), [email](design/email.md) |
| `management/` | [plan.md](management/plan.md): the task tracker; [plan-ios.md](management/plan-ios.md): the iOS app's tasks |

[CLAUDE.md](../CLAUDE.md), at the top of the repo, is the rulebook. A new doc goes in the folder that fits, with a lowercase, hyphenated name, and links to other docs relatively.

## Roles and the System page

Everyone is a **User**. Two more roles see more of how napsack is doing, never more of anyone's private data ([roles.md](implementation/roles.md)):

| | User | PowerUser | Admin |
|---|---|---|---|
| Their own friend map | yes | yes | yes |
| System → Overview (counts) | – | yes, without the users table | yes, with it (and reset codes) |
| System → Metrics | – | without cost | with cost and the health monitor's incidents |
| System → Graph | – | friends by name, everyone else anonymous | everyone by name |
| System → Roles | – | make a friend a PowerUser | make anyone a PowerUser, or take it away |
| System → Users (turn accounts off, sign out, announcements) | – | – | yes |
| System → Logs | – | – | yes |

- **The server decides, on every request.** Each System endpoint calls `roles::require(&state, &me, Role::...)`, which answers 404 to anyone below that role. The page hides tabs too, but that's only for looks: anything new on the System page states its role, sends nothing that role can't see, and gets a row in `check_roles` in the smoke test.
- **Admins come from settings, never the database**: `FADE_ADMINS` locally, and in production the SSM parameter `/fade/admins` (`scripts/set-admins.sh nate,...`, then `scripts/reload-admins.sh`). PowerUser grants are rows in `user_roles`, marked ended when taken away, never deleted.

## Production

napsack runs at <https://napsack.io> (never hardcode it: scripts read it from `terraform output url`). Everything is in Terraform in `infra/`; [operations.md](operations/operations.md) has the details and costs, about $8 a month.

- **The server.** One EC2 instance (t4g.nano: 2 ARM vCPUs, 0.5 GB), with Caddy in front for HTTPS and the old addresses redirecting. The boot script (`infra/user_data.sh.tftpl`) sets everything up and pulls the newest release from S3. Settings live in SSM Parameter Store (`/fade/env`), fetched into memory on every start. You get a shell with `scripts/ssh.sh`, tunneled through SSM (port 22 is closed).
- **The data.** A separate encrypted disk (`aws_ebs_volume.data`, with `prevent_destroy`) holds the database and unopened pics. It survives the instance being replaced. The database is backed up to S3 every hour, kept forever; the disk is snapshotted daily, kept 30 days ([backups.md](operations/backups.md)).
- **Releases.** A release is one binary, built by GitHub Actions. Every push to `main` that passes CI becomes a release candidate in S3 and goes to staging; when staging looks good, a `server-v<version>` tag sends that same binary to production, after a backup. Releases are kept forever (the newest ten candidates too), so `scripts/rollback.sh` can go back. `scripts/deploy.sh` is the owner's hotfix path ([releasing.md](operations/releasing.md)).
- **The health monitor.** A Lambda (`infra/health/monitor.py`) checks `https://napsack.io/api/health` every 5 minutes ([health-monitor.md](implementation/health-monitor.md)):
  - One failure is noted; two in a row open an **incident**.
  - It then tries one repair step per run, gently first: restart the app (through SSM), reboot, then stop and start (which moves it to new hardware). If none of that works, it stops and calls for a person.
  - Every step, with the evidence (the health answer, EC2's status checks, the SSM agent, the serial console), is written to `s3://<artifacts bucket>/health/incidents/`, and each one is announced on the SNS topic `fade-health`.
  - Admins see the last 7 days of incidents on the Metrics tab and can mark one resolved. The monitor can act only on instances tagged `App=fade`, and it can't delete anything.
- **The Metrics tab** shows how the machine and the server are doing (CPU, memory, disks, CPU credits, response times, errors, what it costs), with a status at the top: all good, worth watching, or in the red ([metrics.md](implementation/metrics.md)).
- **Staging.** <https://staging.napsack.io> is a separate copy with its own Terraform state (`infra/staging/`), its own disk and settings, and no backups. It can't read production's settings, data, or releases. Run the browser tests against it with `scripts/test-staging.sh` and load test it with `scripts/load-staging.sh` ([staging.md](operations/staging.md)). On the same size machine it handled 400 people online and 718 texts a second.

## Working together

Several people (and their Claude sessions) can be working at once, so everyone works in the open:

1. **Before you start, look at what's in flight.** Open pull requests (`gh pr list`, or the repository's Pull requests page) and the [plan](management/plan.md)'s Tracker (its **Who** column). If someone's already on it, talk to them first.
2. **Claim it in the plan.** Every piece of work has a row in the Tracker, linked to its entry in an Epic: put your name in **Who** and set **Status** to In progress. A new idea goes into an Epic first, then into the Tracker. Keep the row current as you go, and include the plan change in your pull request. The Tracker is live work only, numbered in priority order (refer to a task by its Epic id, like `X38`, since numbers shift); when it ships, the row moves to the Done table with its version and your name as author.
3. **Work on a branch.** Name it after you and the work: `yourname/short-topic`. Never push to `main` directly; it's protected. (The owner may push changes that are only docs.)
4. **Open a pull request early,** as a draft if it isn't done, so others can see it. Its description follows the template (`.github/pull_request_template.md`): what changed and why, how it's tested (the commands you ran; screenshots at desktop and phone width for anything people see), the risk (a migration? an API change? a new message format?), and which docs and plan rows it updates.
5. **Checks and review.** CI runs every test on the pull request. The owner reviews it (`.github/CODEOWNERS`), and approval must come after your latest push. Fix what's asked on the same branch.
6. **Merging.** The owner squash-merges it: one commit on `main`, with the pull request's title and description. Merging to `main` puts a release candidate on staging.
7. **Releasing** is the owner's ([releasing.md](operations/releasing.md)): check staging, bump the version, and tag `server-v<version>`; only Admins can create release tags, and production deploys only from them.

## The rules that matter

[CLAUDE.md](../CLAUDE.md) has all of them. These will come up in your first features:

1. **Nothing in the database is ever deleted.** Not by a migration, not by app code. When something ends, mark it (`ended_at`, `revoked_at`), or add a newer row that supersedes the old one. Tests in `db.rs` fail the build on `DELETE FROM` in the code or anything destructive in a migration. The same goes for infrastructure: never `terraform destroy`, and read every plan.
2. **Migrations only add.** New tables, new nullable or defaulted columns, indexes. Once a migration has shipped, it's never edited; you add another.
3. **SQL values are always bound** (`?` plus `.bind(...)`), never pasted into the SQL string. A test enforces this too.
4. **The API only grows.** Old clients (soon, the iOS app) keep working: add fields and endpoints; don't rename or remove them. New encryption is a new message format, never a change to an old one.
5. **User text is shown as text.** Clients set `textContent`, never `innerHTML`, and the server checks stored text for invisible and direction-changing characters (`text.rs`).
6. **Roles are checked by the server** (above), and **nothing private is logged**: no message content, ciphertext, keys, tokens, or passwords, ever.
7. **Every change is tested**, and every endpoint is in [api.md](spec/api.md).

## Your loop

1. **Read** what's nearby: the closest existing feature is your template. (Nicknames are a good model for "a private, per-person setting".)
2. **Schema**: a new file in `server/migrations/`, next number.
3. **Server**: a handler (in the closest file, or a new one registered with `mod` in `main.rs`), a route in `fn router`, and a unit test in the file's `mod tests` if there's logic worth testing (`db::tests::temp_db()` gives you a fresh database).
4. **Smoke test**: a `check_*` function in `tests/smoke_test.py` that proves the API's rules (including the ones that should say no). Anything on the System page also gets rows in `check_roles`.
5. **Web app**: HTML in `index.html`, behavior in `app.js`, style in `style.css` (no inline `style="..."`; the page's security policy forbids it).
6. **Browser test**: a `tests/e2e/test_*.py` that does it the way a person would, for what only a browser can show (the smoke test has already proved the rules). Copy the shape of `test_profile.py`, and use `common.py`'s helpers (`sign_up`, `befriend`, ...) rather than writing your own.
7. **Run it**: `bash scripts/test-one.sh test_yours.py` while working; `bash scripts/test.sh` before you're done (also checks formatting: run `cargo fmt` and `cargo clippy --all-targets -- -D warnings` in `server/`).
8. **Look at it**: open it yourself, at phone width (390 px) too. Tests print where their screenshots went.
9. **Docs**: [api.md](spec/api.md) for any API change, the feature's doc if it has one, and your row in [plan.md](management/plan.md).
10. **Pull request** ([Working together](#working-together)): push your branch and open one with a real description. Once it's merged, the owner checks it on staging (the corner shows the build) and releases it: a `server-v<version>` tag sends the same binary to production, after a backup, and `/api/config` and the server's log are checked afterwards.

## When it doesn't work

- **The server says why.** Errors come back as `{"error": "..."}` and show in the app; the details are in the terminal running `cargo run`.
- **The browser console** shows everything the app reports as `[napsack] ...`, and the Network tab shows each API call and its answer.
- **System → Logs** (`/admin#logs`, Admins) collects both, searchable, with a live tail. In production it holds the last 20,000 entries since the server started; older history is in the journal: `scripts/ssh.sh "sudo journalctl -u fade --since '1 hour ago'"`.
- **Is production all right?** `curl https://napsack.io/api/health`; the Metrics tab's status and incidents; the `fade-health` SNS topic.
- **Look at the database**: `sqlite3 server/fade.db` (`.tables`, then plain SQL). Read-only habits are good habits: production is always read-only (`?mode=ro`).
- **A browser test fails**: it prints the failing check and the server's warnings, and leaves screenshots. Playwright refuses selectors that match more than one element, so be specific (`#friends-dialog [data-close]`, not `[data-close]`).

## Gotchas

- Changed `server/static/` and nothing happened: make sure you're on `cargo run` (a debug build). `cargo run --release` behaves like production and serves the compiled-in copies.
- A brand-new file in `server/static/` needs a line in `server/src/web.rs` (and a restart) before it's served.
- A new migration file isn't picked up: `touch server/src/db.rs`, then build (the migrations are compiled in).
- Emoji show as boxes in test screenshots: the test machine has no emoji font. Real devices are fine.
- The browser tests run four at a time, each file printing its output when it finishes. To follow one as it runs, use `scripts/test-one.sh`, or `E2E_JOBS=1 bash scripts/test.sh`.
- On a Mac, the Metrics tab's CPU, memory, and network charts stay empty locally: those readings come from Linux's `/proc`, and every deployed server is Linux. The tests expect only what each system can measure.
- Notifications need HTTPS and a real device (or the browser test's stand-in); `localhost` won't get real pushes.
- Terraform has two roots: `infra/` (production) and `infra/staging/`. Run plans in the one you mean (the owner's; contributors don't need Terraform).
- A new script needs its executable bit recorded (`git update-index --chmod=+x scripts/<name>.sh`) if your system doesn't keep it, and CI calls scripts through `bash` anyway.
- Everything is LF line endings (`.gitattributes`). A CRLF boot script would stop the server from starting, so don't override it.
