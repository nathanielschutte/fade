# Versioning and releases

How napsack's pieces are versioned, how each one ships, and the rules that keep old clients working while new ones roll out. The iOS app's specifics are in [mobile.md](../design/mobile.md).

## The pieces

| Piece | Version lives in | Ships by | Tag |
|---|---|---|---|
| Server (with the web client inside) | `server/Cargo.toml` | GitHub Actions on tag, or `scripts/deploy.sh` | `server-v1.4.0` |
| iOS app, native build | `mobile/app.config.ts` `version`; build number managed by EAS | EAS Build → TestFlight → App Store | `ios-v1.2.0` |
| iOS app, JavaScript-only fix | same version, new update ID | EAS Update (over the air) | none |
| Infrastructure | git history | `terraform apply` by hand | none |

The web client is compiled into the server binary, so it always matches the server. Every running server reports what it is at `GET /api/config`: `server_version`, `build` (git short sha, `-dirty` if built from uncommitted code), `api_version`, `message_formats`, and `min_client_versions`. The admin panel shows the same.

## Compatibility rules

Phones update on their own schedule, and App Store review adds days. So the server has to keep serving every app version it hasn't explicitly retired. These rules make that hold.

**1. Server first.** Anything a client needs from the server ships in a server release before the client release that uses it. The server is always the newest piece.

**2. The API only grows.** Within `api_version` 1:
- New endpoints and new response fields are fine. Clients ignore fields they don't know.
- New request fields must be optional, with a default that matches old behavior (see `format` in `chats.rs` and `snaps.rs`).
- Never rename or remove a field, change its type, or change what an existing value means.

A change that can't follow these rules is a new API version: new routes under `/api/v2/...` next to the old ones, with `API_VERSION` bumped in `server/src/version.rs`. The old routes stay until no supported client uses them (rule 4).

**3. Encryption changes get a new message format.** Every message stores a `format` (1 today, described in [how-napsack-works.md](../how-napsack-works.md)). A new scheme is format 2, and old messages stay format 1 forever, so clients keep the old decryption code. Readers have to exist before writers:
1. Release clients that can read format 2 but still send format 1.
2. Once those are installed widely, raise the minimum client version (rule 4) to them.
3. Add 2 to `MESSAGE_FORMATS` in `server/src/version.rs` and release the server.
4. Release clients that send format 2.

The server refuses formats not in `MESSAGE_FORMATS`, so a client can't jump ahead of step 3 by accident.

While the web app is the only client, steps 1 to 4 collapse into one release: it's served by the same binary, so the reader and the writer ship together. Tabs still open on the old version see the update banner, and an old tab shown a newer-format pic says "reload to open it" without using it up. That's how format 2 shipped: pics with captions (0.13.0), then texts as a JSON envelope and encrypted reactions (0.15.0). Once the iOS app exists, follow the steps.

**4. Retiring old app versions.** Native apps send `X-Napsack-Client: ios/1.2.0+37`. The server answers any request from an app older than its platform's minimum with `426 Upgrade Required` and a message, and the app shows an update screen. `/api/config` is exempt, so an old app can always find out why. Set minimums in Terraform as `FADE_MIN_CLIENT_VERSIONS=ios=1.2.0` and apply. Raise them only when you need to (a security fix, retiring old API routes, a new message format), and give people time to update first. Requests without the header (the web client, scripts) are never blocked.

**5. Database migrations are additive.** Migrations run automatically when the server starts. Add tables, add nullable or defaulted columns, add indexes. Don't drop or rename anything the previous release still reads; do that in a later release, once nothing uses it. The server ignores migrations it doesn't know, so you can roll back to an older binary after a newer one has migrated the database. Migrations are numbered `NNNN_description.sql` and never edited once released. (`0002_e2e.sql` wiped everything once, on purpose, before there were real users. Don't do that again.)

**6. Open browser tabs catch up on their own.** A deploy restarts the server and drops every live connection. When a tab reconnects and sees a different `build`, it shows a "napsack was updated" banner with a Reload button. Rule 2 means the old tab keeps working until then.

## Releasing the server

1. Merge to `main` with CI green (format, lints, unit tests, API smoke test, browser tests, Terraform validation).
2. Bump `version` in `server/Cargo.toml`: patch for fixes, minor for features, major only alongside an `/api/v2`. Commit it as `server 1.4.0`.
3. Tag and push: `git tag server-v1.4.0 && git push origin server-v1.4.0`.
4. The **Release server** workflow checks the tag matches `Cargo.toml`, runs the tests, builds the ARM binary, uploads it to S3 (as `fade-server-1.4.0-<sha>` and as the current release), installs it through SSM, and confirms `/api/config` reports the new build. If you've added reviewers to the `production` environment, it waits for approval first.

Test locally any time with `scripts/test.sh` (or `scripts/test.sh --no-browser`).

### Hotfix without CI

`scripts/deploy.sh` (from WSL) builds, copies the binary over SSH, restarts, saves the build to S3, and checks the live build. A deploy from uncommitted code shows as `<sha>-dirty` everywhere. Commit and tag it afterwards so the history matches what's running.

### Rollback

```sh
scripts/rollback.sh                 # list kept builds
scripts/rollback.sh 1.3.2-a1b2c3d   # make that build current and restart
```

Rule 5 is what makes this safe. A rollback can't undo a migration, so a migration that broke something needs a new forward release.

## Releasing the iOS app

The details live in [mobile.md](../design/mobile.md). The short version:
- **Native changes** (new native modules, permissions, Expo SDK upgrades): bump `version`, tag `ios-v1.2.0`, and EAS builds it in the cloud, uploads it to TestFlight, and after you test it, you submit it for App Store review.
- **JavaScript-only fixes** go out with EAS Update to installed apps whose native code matches. No review wait, but it's still bound by rules 1-3.

## One-time setup

1. **Let GitHub deploy.** Review and apply the IAM role in `infra/github.tf`:
   ```sh
   cd infra
   terraform plan -target=aws_iam_role_policy.github_deploy -out tf.plan   # 3 new IAM resources
   terraform apply tf.plan && rm tf.plan
   terraform output github_actions_variables
   ```
2. **Set the repository variables** that output lists, in GitHub under Settings → Secrets and variables → Actions → Variables.
3. **Create the `production` environment** under Settings → Environments. Add yourself as a required reviewer if you want to approve each deploy.
4. **Protect `main`**: require pull requests and the CI checks to pass.
