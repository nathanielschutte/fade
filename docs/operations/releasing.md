# Versioning and releases

How napsack's pieces are versioned, how each one ships, and the rules that keep old clients working while new ones roll out. The iOS app's specifics are in [mobile.md](../design/mobile.md).

## The pieces

| Piece | Version lives in | Ships by | Tag |
|---|---|---|---|
| Server (with the web client inside) | `server/Cargo.toml` | GitHub Actions: every push to `main` goes to staging, a tag goes to production. `scripts/deploy.sh` for hotfixes | `server-v1.4.0` |
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

While the web app is the only client, steps 1 to 4 collapse into one release: it's served by the same binary, so the reader and the writer ship together. Tabs still open on the old version see the update banner, and an old tab shown a newer-format pic says "reload to open it" without using it up. That's how format 2 shipped: pics with captions (0.13.0), then texts as a JSON envelope and encrypted reactions (0.15.0). Once the native apps exist (Swift for iOS, later Kotlin for Android; [mobile.md](../design/mobile.md)), follow the steps: each has its own implementation of the formats, and its own release.

**4. Retiring old app versions.** Native apps send `X-Napsack-Client: ios/1.2.0+37`. The server answers any request from an app older than its platform's minimum with `426 Upgrade Required` and a message, and the app shows an update screen. `/api/config` is exempt, so an old app can always find out why. Set minimums in Terraform as `FADE_MIN_CLIENT_VERSIONS=ios=1.2.0` and apply. Raise them only when you need to (a security fix, retiring old API routes, a new message format), and give people time to update first. Requests without the header (the web client, scripts) are never blocked.

**5. Database migrations are additive.** Migrations run automatically when the server starts. Add tables, add nullable or defaulted columns, add indexes. Don't drop or rename anything the previous release still reads; do that in a later release, once nothing uses it. The server ignores migrations it doesn't know, so you can roll back to an older binary after a newer one has migrated the database. Migrations are numbered `NNNN_description.sql` and never edited once released. (`0002_e2e.sql` wiped everything once, on purpose, before there were real users. Don't do that again.)

**6. Open browser tabs catch up on their own.** A deploy restarts the server and drops every live connection. When a tab reconnects and sees a different `build`, it shows a "napsack was updated" banner with a Reload button. Rule 2 means the old tab keeps working until then.

## Releasing the server

Every release goes through staging first, as the exact binary that will reach production.

```
branch + pull request ──▶ CI: tests ──▶ squash-merge to main ──▶ release candidate ──▶ staging
                                                            releases/main/fade-server-<sha>
                                                                                    │ looks good
                     production ◀── backup, fade-update ◀── release ◀── tag server-v<version>
                                                            releases/tags/fade-server-<version>
```

### 1. Develop and test, on a branch

Build the change, with its tests, on a branch (`<name>/<topic>`). Before opening the pull request, run the whole suite: `bash scripts/test.sh` (unit tests, crypto vectors, the API smoke test, every browser test), plus `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` in `server/`. Look at anything a person sees at desktop and phone width (CLAUDE.md, "How every change is tested").

### 2. A pull request, then a release candidate on staging

Push the branch and open a pull request, described by the template (`.github/pull_request_template.md`). The **CI** workflow (`.github/workflows/ci.yml`) runs everything on it (format, lints, all the tests, Terraform validation), and the owner reviews it. The owner squash-merges it into `main`, where CI runs again, and if it passes, its **Release candidate on staging** job:
1. builds the ARM server binary once, stamped with the commit (`build` = the short sha);
2. uploads it as `releases/main/fade-server-<sha>`, and as `releases/main/fade-server`, which is what staging runs;
3. deletes all but the newest ten candidates (releases are kept forever; see below);
4. runs `fade-update` on staging through SSM, and checks `https://staging.napsack.io/api/config` reports that commit.

Pushes to `main` don't cancel each other while running, but GitHub keeps only one waiting run: if three land close together, the middle one is cancelled before it starts and gets no candidate. That commit can't be released (step 2 below refuses it); release the newer one, which includes it. Pushes that change only `ios/` or the docs don't run CI on `main` at all (they'd make no candidate), so they never cause this. A pull request runs the tests only.

### 3. Check staging

<https://staging.napsack.io> now runs the commit: the corner of every page shows `staging · v<version> · <sha> · up …`. Try the change there, on a phone too. For a bigger change, run the browser tests and a load test against it (`scripts/test-staging.sh`, `scripts/load-staging.sh`; [staging.md](staging.md)).

### 4. Tag: the release on production

When staging looks good:
1. Bump `version` in `server/Cargo.toml` (patch for fixes, minor for features, major only alongside an `/api/v2`), usually as part of the feature's pull request, or in a small one of its own (`server 1.4.0`). Once merged, that commit is a candidate too; it's the one you'll release, so let it reach staging.
2. The owner (or a Claude session the owner has allowed to release) tags that commit and pushes the tag: `git tag -a server-v1.4.0 <sha> -m "..." && git push origin server-v1.4.0`. Release tags are protected (Admins only), and the `production` environment accepts deployments only from `server-v*` tags. Tag a commit staging has run (the `build` staging's `/api/config` shows): changes only to `ios/` or the docs skip CI and make no candidate, so a commit like that can't be released, and doesn't need to be (it changes nothing on the server).

The **Release server** workflow (`.github/workflows/release-server.yml`):
1. checks the tag matches `Cargo.toml` and that the commit is on `main`;
2. checks that staging ran that commit: `main`'s CI passed for it and its **Release candidate on staging** job succeeded (`release.sh staging-ran`). Otherwise it stops before anything is built or changed, saying so. Since 0.43.0: 0.42.2 once reached production without staging, when `main`'s CI had failed on a flaky test and the release fell back to building it again;
3. takes the candidate staging ran for that commit, `releases/main/fade-server-<sha>`, byte for byte. Only if it's no longer kept (more than ten pushes ago) does it run the tests and build again;
4. publishes it as `releases/tags/fade-server-<version>`, refusing if that version already exists (a fix is a new version), and as `releases/fade-server`, which is what production runs;
5. backs up production's database (`fade-backup`, the hourly job, run now), so there's a fresh copy before any migration;
6. runs `fade-update` on every production server through SSM, and checks `https://napsack.io/api/config` reports the commit;
7. creates the GitHub Release for the tag, marked latest, its notes the pull requests merged since the previous `server-v*` tag (`release.sh github-release`). Only once production runs it, so a Release on GitHub means it's live.

If you've added required reviewers to the `production` environment in GitHub, it waits for approval first. Then check production as CLAUDE.md's Shipping section says: the new `build` in `/api/config`, the pages you changed, and a clean start in the log.

The release's `build` is the commit's sha, the same as on staging: it's the same binary. The version is in `server_version`.

### Where builds live

In the artifacts bucket (`terraform output artifacts_bucket`):

| Key | What | Kept |
|---|---|---|
| `releases/main/fade-server-<sha>` | Release candidates, one per push to `main` | The newest ten |
| `releases/main/fade-server` | What staging runs (its server pulls it at boot and on `fade-update`) | Replaced each push |
| `releases/tags/fade-server-<version>` | Releases, one per tag | Forever, never replaced |
| `releases/fade-server` | What production runs | Replaced each release |
| `releases/hotfix/fade-server-<version>-<sha>` | Hotfixes from `scripts/deploy.sh` | Forever |

Nothing else belongs under `releases/`. Each candidate and release carries the commit it was built from as S3 metadata (`build`); `aws s3api head-object --bucket <bucket> --key releases/tags/fade-server-0.31.1` shows it. Every version before the pipeline (0.1.0 to 0.31.0, shipped with `deploy.sh`) was moved into `releases/tags/` the same way on 2026-10-23, its build (with `-dirty` where it was built from uncommitted code) kept in the metadata.

Each GitHub job has its own AWS role ([infra/github.tf](../../infra/github.tf)), assumed through GitHub's OIDC, so no AWS keys are stored in GitHub. The staging job's role can write only `releases/main/` and reach only staging's server; the release job's role can't delete anything and reaches only production's servers.

### Hotfix without CI

`scripts/deploy.sh` (the owner's; needs cargo-zigbuild and zig) builds, copies the binary over SSH, restarts, saves the build to S3, and checks the live build. On production it saves `releases/hotfix/fade-server-<version>-<sha>`; with `FADE_STACK=staging`, a candidate in `releases/main/`. A deploy from uncommitted code shows as `<sha>-dirty` everywhere. Afterwards, open a pull request for the same change, merge it, and release a tag the normal way so production runs a tagged release again.

### Rollback

```sh
scripts/rollback.sh                   # list releases, hotfixes, and older builds
scripts/rollback.sh 1.3.2             # a release (releases/tags/)
scripts/rollback.sh 1.3.2-a1b2c3d     # a hotfix (releases/hotfix/)
```

It makes that build what production runs and installs it. Rule 5 is what makes this safe. A rollback can't undo a migration, so a migration that broke something needs a new forward release. Once fixed, release a new version (a higher one; tags are never reused).

## Releasing the iOS app

The details live in [mobile.md](../design/mobile.md). The short version:
- **Native changes** (new native modules, permissions, Expo SDK upgrades): bump `version`, tag `ios-v1.2.0`, and EAS builds it in the cloud, uploads it to TestFlight, and after you test it, you submit it for App Store review.
- **JavaScript-only fixes** go out with EAS Update to installed apps whose native code matches. No review wait, but it's still bound by rules 1-3.

## One-time setup

Done for napsack.io; for a new copy:

1. **Let GitHub deploy.** Apply `infra/github.tf` (part of `terraform apply` in `infra/`), then `terraform output github_actions_variables`.
2. **Set the repository variables** that output lists, in GitHub under Settings → Secrets and variables → Actions → Variables: `AWS_REGION`, `ARTIFACTS_BUCKET`, `APP_NAME`, `APP_URL`, `AWS_DEPLOY_ROLE_ARN`, `STAGING_DEPLOY_ROLE_ARN`, `STAGING_URL`. They can live in the `production` environment (napsack.io's do), except the two `STAGING_` ones, which must be repository variables: the staging job runs in the `staging` environment and can't see production's. It falls back to `us-east-1`, the app name `fade`, and the bucket Terraform names from the account. Without the `STAGING_` ones, CI still tests every push but skips the staging deploy, with a warning.
3. **Environments** (Settings → Environments): `staging` and `production` are created the first time a job uses them. Add yourself as a required reviewer on `production` if you want to approve each release.
4. **Protect `main`**: require the CI checks to pass.
