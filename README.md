# napsack

A small private messenger for close friends: texts and view-once pics, end-to-end encrypted, plus group chats (not end-to-end encrypted yet, and the app says so). It runs as one Rust server that also serves the web app, on one small AWS instance, and installs on a phone's Home Screen with notifications. An iOS app is on the way.

`fade` is the internal name (binary, service, `FADE_*` settings, AWS resources); people only ever see napsack.

## What's where

```
server/          Rust (axum + SQLite): the API, and the web app compiled into one binary
  src/           one file per area: chats.rs, groups.rs, people.rs, push.rs, guard.rs, ...
  static/        the web app: plain HTML, CSS, and JavaScript modules, no build step
  migrations/    the database schema, one numbered file per change
shared/crypto/   the end-to-end encryption, shared by the web app and the iOS app
ios/             the iOS app (Swift, Xcode)
tests/           API smoke test, browser tests (Playwright), pinned crypto vectors
infra/           Terraform for AWS
scripts/         test, deploy, rollback, ssh
docs/            everything else (below)
```

## Run it

```sh
cd server && cargo run          # http://127.0.0.1:8080; saving a web app file updates the page live
bash scripts/test.sh            # everything CI runs; --no-browser skips the browser tests
```

Setting up a machine (macOS, Linux, or Windows through WSL), how to contribute through pull requests, and how releases work: [onboarding.md](docs/onboarding.md) and [releasing.md](docs/operations/releasing.md).

## Docs

| | |
|---|---|
| [onboarding.md](docs/onboarding.md) | Start here if you're new to the code |
| [CLAUDE.md](CLAUDE.md) | How we work: the rules (data is never deleted), testing, shipping, code standards |
| [plan.md](docs/management/plan.md) | What's done, what's next |
| [how-napsack-works.md](docs/how-napsack-works.md) | The encryption, pics, notifications, and what the server can and can't see |
| [api.md](docs/spec/api.md) | Every endpoint and socket event |
| [security.md](docs/security.md) | Protections, limits, and what to do if something looks wrong |
| [operations.md](docs/operations/operations.md) | AWS, settings, shell access, domains, cost |
| [releasing.md](docs/operations/releasing.md) | Versions, compatibility rules, releasing |
| [backups.md](docs/operations/backups.md) | Backups and restoring |
| [staging.md](docs/operations/staging.md) | The staging copy, browser tests against it, and load test results |
| [health-monitor.md](docs/implementation/health-monitor.md) | The outside monitor that checks and repairs the server |
| [roles.md](docs/implementation/roles.md) | User, PowerUser, Admin, and the System page |
| [admin-users.md](docs/implementation/admin-users.md) | Admin tools for accounts: turning one off (nothing deleted), sign-in locks, announcements |
| [mobile.md](docs/design/mobile.md) | The iOS app: the plan |
| [ios-onboarding.md](docs/ios-onboarding.md) | The iOS app: setting up Xcode and an iPhone, building, testing |

Docs are grouped by purpose: `docs/spec/` (the API), `docs/implementation/` (how built features work), `docs/operations/` (running it), `docs/design/` (proposals), `docs/management/` (the plan). Names are lowercase.
