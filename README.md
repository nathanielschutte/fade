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
mobile/          the iOS app (Expo)
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

On this Windows machine, build and test in WSL (Smart App Control blocks freshly built programs); [CLAUDE.md](CLAUDE.md) has the setup. Releases go out with `scripts/deploy.sh` (from WSL) for now; see [RELEASING.md](docs/RELEASING.md).

## Docs

| | |
|---|---|
| [ONBOARDING.md](docs/ONBOARDING.md) | Start here if you're new to the code |
| [CLAUDE.md](CLAUDE.md) | How we work: the rules (data is never deleted), testing, shipping, code standards |
| [plan.md](docs/plan.md) | What's done, what's next |
| [how-napsack-works.md](docs/how-napsack-works.md) | The encryption, pics, notifications, and what the server can and can't see |
| [API.md](docs/API.md) | Every endpoint and socket event |
| [SECURITY.md](docs/SECURITY.md) | Protections, limits, and what to do if something looks wrong |
| [OPERATIONS.md](docs/OPERATIONS.md) | AWS, settings, shell access, domains, cost |
| [RELEASING.md](docs/RELEASING.md) | Versions, compatibility rules, releasing |
| [BACKUPS.md](docs/BACKUPS.md) | Backups and restoring |
| [mobile.md](docs/mobile.md) | The iOS app |
