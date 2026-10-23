# Onboarding

You know what napsack does. This gets you from there to changing it: how the pieces fit, where things live, the daily loop, and the handful of rules that matter. Read it once top to bottom, then keep it open while you build your first feature ([stories/favorites.md](stories/favorites.md)).

## The picture

```
 phone / browser                        one small AWS server
┌──────────────────────┐   HTTPS    ┌──────────────────────────────────────────┐
│ web app (app.js)     │ ─────────▶ │ Caddy (TLS)                              │
│  · encrypts/decrypts │   /api/*   │   └▶ fade-server (Rust, axum)            │
│    (crypto.js)       │ ◀───────── │        · REST API + one WebSocket        │
│  · keys in IndexedDB │  WebSocket │        · serves the web app's files      │
│  · service worker    │ ◀═════════ │        └▶ SQLite + pic files (data disk) │
│    (notifications)   │   events   └──────────────────────────────────────────┘
└──────────────────────┘
```

- **One binary.** The Rust server answers the API, holds every live WebSocket, and serves the web app. The web app's files are compiled into the binary (`include_str!` in `server/src/web.rs`), so a deploy is one file.
- **The browser does the cryptography.** For direct chats the server stores and relays ciphertext it can't read. That's why a lot of logic lives in the client: decrypting, deciding what a message says, showing it.
- **The WebSocket pushes changes; the API is the truth.** When something changes, the server sends a small event ("friends changed", "new message"), and the app refetches or updates what it shows. After any reconnect the app refetches everything, so a missed event is never a bug.
- **SQLite on its own disk.** One file, backed up hourly. Nothing in it is ever deleted (more below).

## Your machine

Everything builds and runs in **WSL** (Ubuntu). Windows' Smart App Control blocks freshly compiled programs, so Rust and the tests can't run on the Windows side. The setup is done; for a new machine it's in [CLAUDE.md](../CLAUDE.md) (Environment notes).

Open an Ubuntu terminal and:

```sh
cd /mnt/c/Users/nates/Documents/code/fade/server
FADE_ADMINS=you cargo run          # http://127.0.0.1:8080, open it in your Windows browser
```

That makes `server/fade.db` (your local database) and `server/pics/` next to it, both ignored by git. Sign up as `you` (admin, so `/admin` and its log viewer work) and as a second account in a private window, befriend yourself, and you have both ends of a conversation. To start fresh, stop the server and delete `fade.db` and `pics/`.

**Edit and see it, no rebuild.** While you run with `cargo run`, the server reads the web app's files from disk on every request and the page watches for changes:

- Save `style.css` and the new styles appear in about a second, in place: you keep the chat or dialog you had open. Good for trying colors and spacing.
- Save `app.js`, `index.html`, or another script, and the page reloads by itself (you stay signed in, back on the chat list).
- Change Rust code and restart `cargo run`; the page reloads once the server is back.

This is development only. Release builds serve the copies compiled into the binary and don't have the reload code at all (`server/src/web.rs`); `scripts/deploy.sh` checks that after every deploy.

## Follow one message

The fastest way to learn the code is to follow a text from one person to another. Open these as you read.

1. **Typing and pressing Enter** — `server/static/app.js`, the `#composer` submit handler (section `conversation`). It gets the chat key (`keyFor`), encrypts with `e2e.encryptText2` from `shared/crypto/crypto.js`, and calls `getJSON("/chats/<friend>/messages", { method: "POST", ... })`.
2. **The route** — `server/src/main.rs`, `fn router`: every URL and the function that answers it. `/chats/{friend_id}/messages` → `chats::send_text`.
3. **The handler** — `server/src/chats.rs`, `send_text`. The shape of every handler: `AuthUser(me)` (who's asking; it rejects anyone not signed in), check the rules (`require_friend`), validate input, one SQL statement, then tell people.
4. **Telling people** — `state.hub.send_both(...)` in `server/src/ws.rs` pushes a `message` event down the WebSocket to both people's open apps, and `push::notify` sends a notification to the friend's devices that don't have napsack on screen.
5. **The other end** — `app.js`, `handleEvent` (section `realtime`), `case "message"`: `upsertMessage` decrypts it (`decrypt`), and `renderMessages` draws the chat.

Almost every feature is this loop: **UI event → API call → handler (rules, SQL) → event → other clients update.**

## Where things live

**Server** (`server/src/`), one file per area:

| File | What's there |
|---|---|
| `main.rs` | Startup, settings (`Config`), shared state (`AppState`), **all routes** (`fn router`), request middleware |
| `auth.rs`, `account.rs` | Sign up/in/out and sessions; password change, recovery keys, admin reset codes |
| `friends.rs` | The chat list (`list_chats`), friend requests, unfriending |
| `chats.rs`, `snaps.rs` | Direct texts; direct pics (stored as encrypted files until opened) |
| `groups.rs`, `group_pics.rs` | Group chats, members, group pics and pictures |
| `people.rs`, `profiles.rs` | Display names, private nicknames, profile pictures; the profile page |
| `reactions.rs`, `presence.rs` | Reactions; typing and "active now" |
| `push.rs`, `invites.rs` | Notifications; invite links |
| `ws.rs` | The WebSocket: who's connected (`Hub`), and every event type (`enum Event`) |
| `guard.rs`, `ratelimit.rs`, `text.rs`, `images.rs` | Protection: limits and bans, input checks, image cleaning |
| `db.rs` | Connecting, shared helpers, and the **guard tests** that enforce the rules below |
| `admin.rs`, `logs.rs` | The admin panel and its log viewer |

The database schema is `server/migrations/`, one numbered file per change, read in order.

**Web app** (`server/static/`): `index.html` (every screen and dialog, mostly hidden until used), `style.css`, and `app.js`, one file split into sections marked `// ---------- name ----------` (auth, conversation, groups, profiles, friends, notifications, ...). Search for the section, not the line number. `el(...)` builds elements, `$(...)` finds one, `api`/`getJSON` call the server, `report(...)` sends a diagnostic to the admin log viewer.

**Tests** (`tests/`): `smoke_test.py` drives the API directly (one `check_*` function per area); `e2e/test_*.py` drive real browsers through whole features; `vectors/` pin the encryption's exact bytes.

**Docs**: [API.md](API.md) lists every endpoint and event. [how-napsack-works.md](how-napsack-works.md) explains the encryption. [plan.md](plan.md) is the to-do list. [CLAUDE.md](../CLAUDE.md) is the rulebook.

## The rules that matter

[CLAUDE.md](../CLAUDE.md) has all of them. These five will come up in your first feature:

1. **Nothing in the database is ever deleted.** Not by a migration, not by app code. When something ends, mark it (`ended_at`, `revoked_at`), or add a newer row that supersedes the old one. Tests in `db.rs` fail the build on `DELETE FROM` in the code or anything destructive in a migration.
2. **Migrations only add.** New tables, new nullable or defaulted columns, indexes. And once a migration has shipped, it's never edited; you add another.
3. **SQL values are always bound** (`?` plus `.bind(...)`), never pasted into the SQL string. A test enforces this too.
4. **The API only grows.** Old clients (soon, the iOS app) keep working: add fields and endpoints; don't rename or remove them.
5. **Every change is tested**, and every endpoint is in [API.md](API.md).

## Your loop

1. **Read** what's nearby: the closest existing feature is your template. (Nicknames are a good model for "a private, per-person setting".)
2. **Schema**: a new file in `server/migrations/`, next number.
3. **Server**: a handler (in the closest file, or a new one registered with `mod` in `main.rs`), a route in `fn router`, and a unit test in the file's `mod tests` if there's logic worth testing.
4. **Smoke test**: a `check_*` function in `tests/smoke_test.py` that proves the API's rules (including the ones that should say no).
5. **Web app**: HTML in `index.html`, behavior in `app.js`, style in `style.css` (no inline `style="..."`; the page's security policy forbids it).
6. **Browser test**: a `tests/e2e/test_*.py` that does it the way a person would. Copy the shape of `test_profile.py`.
7. **Run it**: `bash scripts/test-one.sh test_yours.py` while working; `bash scripts/test.sh` before you're done (also checks formatting: run `cargo fmt` and `cargo clippy --all-targets -- -D warnings` in `server/`).
8. **Look at it**: open it yourself, at phone width too. Tests print where their screenshots went.
9. **Docs**: [API.md](API.md), and mark it done in [plan.md](plan.md).
10. **Ship**: [RELEASING.md](RELEASING.md) and the Shipping section of [CLAUDE.md](../CLAUDE.md) (backup first when there's a migration).

## When it doesn't work

- **The server says why.** Errors come back as `{"error": "..."}` and show in the app; the details are in the terminal running `cargo run`.
- **The browser console** shows everything the app reports as `[napsack] ...`, and the Network tab shows each API call and its answer.
- **`/admin#logs`** (signed in as an admin) collects both, searchable.
- **Look at the database**: `sqlite3 server/fade.db` (`.tables`, then plain SQL; install it once with `sudo apt-get install -y sqlite3`). Read-only habits are good habits: production is always read-only.
- **A browser test fails**: it prints the failing check and the server's warnings, and leaves screenshots. Playwright refuses selectors that match more than one element, so be specific (`#friends-dialog [data-close]`, not `[data-close]`).

## Gotchas

- Changed `server/static/` and nothing happened: make sure you're on `cargo run` (a debug build). `cargo run --release` behaves like production and serves the compiled-in copies.
- A brand-new file in `server/static/` needs a line in `server/src/web.rs` (and a restart) before it's served.
- A new migration file isn't picked up: `touch server/src/db.rs`, then build (the migrations are compiled in).
- From Git Bash, `wsl.exe` swallows `$VARIABLES` in a command; use the Ubuntu terminal directly, or a script file.
- Emoji show as boxes in test screenshots: the test machine has no emoji font. Real devices are fine.
- Notifications need HTTPS and a real device (or the browser test's stand-in); `localhost` won't get real pushes.
