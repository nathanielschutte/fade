
# Plan

Central task tracking doc for napsack, for everyone who works on it (and their Claude sessions). Divides into categories ("Epics"), and a Tracker at the top: the tasks from the Epics that are being worked on or are next, and who has them.

## How to use it

- **Before starting:** read the Tracker (who's on what) and the open pull requests (`gh pr list`). Don't start something someone else has; talk to them.
- **Claim a task:** put your name in **Who** and set **Status** to In progress, in your branch's first commit, and open a draft pull request so others can see it. **Who** and **Author** are always a person's name ("Nate"); a Claude session writes the person it works for, never itself (its part is in the commits, as co-author).
- **A new idea** goes into an Epic first (an entry with a short id, like `X38`: what was asked, by whom and when, and the decisions), then into the Tracker by priority.
- **As you go:** keep your row's Status current, and add "Built (version): ..." notes to the Epic entry when it ships. The plan changes travel in the same pull request as the work.
- **The iOS app** is one Tracker row with its own task list, [plan-ios.md](plan-ios.md), which follows the same rules.
- **When it ships:** the row leaves the Tracker for the bottom of the Done table, with the version it shipped in (or `infra`, `process`) and its author, and the Tracker is renumbered.

## Tracker

Live work only, top to bottom: what's being worked on, then what's next. Each row links to its entry in the Epics below, which holds the details and design notes. **#** is a row's place in line, renumbered (1, 2, 3, ...) whenever a row is added, finished, or moved, so a task is named by its Epic id (`X38`), never its number.

Status: **In progress** · **Up next** · **Planned** · **Needs decision** (blocked on a choice, noted in the epic) · **On hold**

**Who**: the person working on it, or – if it's free to pick up.

| # | Task | Epic | Who | Status | Why it's here |
|---|---|---|---|---|---|
| 1 | [iOS app](plan-ios.md): its own task list | Features | Nate | In progress | Native Swift (decided 2026-10-29), on a Mac; the Simulator and a free Apple ID until the Developer Program comes through |
| 2 | [PowerXtreme: a role above PowerUser](#s4-powerxtreme) | Security | Nate | In progress | Nate (2026-10-29); built for 0.43.0 |
| 3 | [Group names cut short in the chat header](#x38-group-names-cut-short-in-the-chat-header) | Experience | Nate | In progress | Fixed for 0.43.0 |
| 4 | [Group chats: encrypt reactions; refuse plain text](../implementation/group-encryption.md#built) | Features | – | Planned | Phase 1 shipped in 0.21.0; these finish it |
| 5 | [A GitHub Release for every server release](#p7-a-github-release-for-every-server-release) | Process | Nate | In progress | Built for 0.43.0 (the first release that makes one) |
| 6 | [A release refuses a commit staging never ran](#p8-a-release-refuses-a-commit-staging-never-ran) | Process | Nate | In progress | Nate (2026-10-30): fix it, for security. Built; it guards 0.43.0's release |
| 7 | [A tap on the shutter could count as a hold](#d11-a-tap-on-the-shutter-could-count-as-a-hold-when-the-page-was-busy-fixed-in-0430) | Debug | Nate | In progress | Fixed for 0.43.0 (#28) with D12, iPhone videos |
| 8 | [Better video quality](#f20-better-video-quality) | Features | – | Needs decision | Nate (2026-10-29): options listed; which to try |
| 9 | [api.napsack.io: a stable address for the apps](#i10-apinapsackio-a-stable-address-for-the-apps) | Infrastructure | Nate | Needs decision | Nate (2026-10-29); designed in api-host.md. Applying it replaces the instance: when |
| 10 | [Scale out: two servers across zones](../design/horizontal-scaling.md) | Infrastructure | – | Needs decision | Design and cost in horizontal-scaling.md; Nate reviews before anything is built |
| 11 | [Email on napsack.io](#i9-email-on-napsackio) | Infrastructure | – | On hold | Planned in email.md (iCloud+ custom domain recommended); on the back burner (Nate, 2026-10-23) |

**Done**

Oldest first; newly shipped rows go at the bottom.

| Task | Shipped | Author |
|---|---|---|
| [Logging pass and admin log viewer](#d1-log-viewer) | 0.2.0 | Nate |
| [Rename "snap" to "pic"](#x1-rename-snap) | 0.3.0 | Nate |
| [Profile page](#f4-profile-page) | 0.4.0 | Nate |
| [Chat pagination](#f3-chat-pagination) | 0.5.0 | Nate |
| [Client debug logs](#d2-client-debug-logs) | 0.6.0 | Nate |
| [Backups you can restore](#i2-backups-you-can-restore): hourly to S3, kept forever, drill passed | infra | Nate |
| Backup status in the admin panel (part of [backups](#i2-backups-you-can-restore)) | 0.7.0 | Nate |
| [Mark inactive instead of deleting](#p4-mark-inactive-instead-of-deleting) | 0.8.0 | Nate |
| [Request auditing and security hardening](#s1-request-auditing-and-security-hardening) | 0.9.0, 0.9.1 | Nate |
| [Group chats](#f7-group-chats) (texts; not end-to-end encrypted yet) | 0.10.0 | Nate |
| [Account bar on the main screen](#x2-account-buttons-on-the-main-screen), favicon | 0.11.0 | Nate |
| Pics and group pictures in group chats (not end-to-end encrypted yet; view-once, 30 days), shorter list previews, server resources in admin | 0.12.0 | Nate |
| Hostile-input hardening: images rebuilt server-side, SQL guard test, text validation, write and socket caps (see CLAUDE.md, Security) | 0.12.0 | Nate |
| [Profile pics and nicknames](#f5-profile-pic-and-nicknames): display names, private nicknames, profile pictures | 0.13.0 | Nate |
| [Pics last 30 days](#f9-pics-last-30-days): unopened pics wait on disk and survive restarts | 0.13.0 | Nate |
| [Captions on pictures](#f6-captions-on-pictures): message format 2 for direct pics; plain captions in groups | 0.13.0 | Nate |
| [Password reset and recovery](#f2-password-reset-and-recovery): recovery keys, change password, admin reset codes, accepting a friend's new key | 0.14.0 | Nate |
| [Account safety basics](#f8-account-safety-basics): sign out other devices (sign-in limits shipped in 0.9) | 0.14.0 | Nate |
| [Install as an app, with notifications](#f10-install-as-an-app-with-notifications) | 0.15.0 | Nate |
| [Reactions and replies](#f11-reactions-and-replies): text format 2, encrypted reactions | 0.15.0 | Nate |
| [Typing and "active now"](#f12-typing-and-active-now) | 0.15.0 | Nate |
| Abuse protection: account and device caps, request budgets, scanner refusal and probe bans, load shedding, disk floors ([security.md](../security.md)); Home Screen app clears the iPhone status bar | 0.16.0 | Nate |
| [Invite links and QR codes](#f14-invite-links-and-qr-codes) | 0.17.0 | Nate |
| Push refusals log the push service's reason; an unchanged subscription no longer adds a row | 0.17.3 | Nate |
| [Pics back to back](#x4-open-pics-back-to-back), [message box grows to 4 lines](#x5-composer-grows-to-4-lines), [keyboard stays up after Send](#x6-keyboard-stays-up-after-send), [pull to refresh](#x7-pull-to-refresh-the-chat-list), [group "seen by"](#f17-group-chats-seen-by-then-end-to-end); admin tabs no longer jump between Overview and Logs | 0.18.0 | Nate |
| [Chat list header](#x8-chat-list-header-buttons): Friends and a + for starting things, together on the right | 0.18.1 | Nate |
| iPhone notifications from some friends were refused by Apple ("BadWebPushTopic"): push topics are now valid base64url, and keyed so the push service can't tell who sent them | 0.18.2 | Nate |
| [Favorites](plan.md#x3-chat-list-tools-pin-mute-search) and [hiding chats](#x3-chat-list-tools-pin-mute-search): swipe (phone) or hover (computer) a chat for Favorite, Hide, or Leave | 0.19.0 | Nate |
| [Admin "Online now"](#d3-admin-online-now-count) counts whoever is looking at the admin page; [removing people from groups](#x9-removing-people-from-groups) says who can, and takes two taps; [birthdays](#f19-birthday-and-more-profile-fields) on profiles, with a 🎂 on the day | 0.20.0 | Nate |
| **[End-to-end encrypted group chats](../implementation/group-encryption.md)** (format 3): messages and pics; the group's name and picture, and reactions, still visible to the server, and every group says so | 0.21.0 | Nate |
| [Draw on pics](#f13-draw-on-pics): a pen, stickers, and undo, flattened into the photo before it's encrypted | 0.22.0 | Nate |
| [Streaks](#f15-streaks): 🔥 and a count when you've both sent pics every day, ⌛ when it's about to end | 0.23.0 | Nate |
| [Mute and search](#x3-chat-list-tools-pin-mute-search): mute a chat for 8 hours, a week, or always; search chats by name and messages by text (in the browser) | 0.24.0 | Nate |
| [Befriend people from a group](#x10-befriend-people-from-a-group): Add friend / Requested / Accept in a group's member list | 0.24.1 | Nate |
| [Bad connections](#x11-bad-connections): pics count as opened only once shown; texts and pics resend safely; heartbeat and offline note | 0.25.0 | Nate |
| [Double tap a chat to send a pic](#x12-double-tap-a-chat-to-send-a-pic); [double tap the camera to switch it](#x13-double-tap-the-camera-to-switch-it) | 0.25.1 | Nate |
| [Phone double tap waits a beat](#x12-double-tap-a-chat-to-send-a-pic); [group badge in the list](#x14-tell-groups-from-direct-chats-in-the-list) | 0.25.2 | Nate |
| [Friend map](#x15-friend-map): your own map (friends, who knows who, ? for friends of friends) and the admin graph (everyone or chosen people, depth 1–2) | 0.27.0 | Nate |
| [Roles](#s2-roles): User, PowerUser, Admin; System pages scoped by role; admins from SSM | 0.28.0 | Nate |
| [Health monitor](#i6-health-monitor): /api/health, a Lambda every 5 minutes that restarts, reboots, or moves the server, incidents in S3, SNS notices | 0.29.0 | Nate |
| [napsack.io](#i7-napsackio): the production address; napsack.getattr.com, fade.getattr.com and www redirect (301) | infra, 2026-10-23 | Nate |
| [Metrics tab](#i4-metrics-how-is-the-infrastructure-doing): machine and server readings, status, cost (see operations.md) | 0.26.0 | Nate |
| [The release pipeline](#p2-turn-on-cicd): main → release candidate on staging, `server-v*` tag → the same binary on production; releases kept forever, the newest ten candidates ([releasing.md](../operations/releasing.md)) | 0.31.1 | Nate |
| [Admin tools for accounts](#x21-admin-tools-for-accounts): System → Users (turn accounts off and on, sign out everywhere, clear a sign-in lock, reset codes, admin activity), announcements | 0.32.0 | Nate |
| [Team Napsack](#x22-team-napsack-messages-from-napsack-itself): napsack's own account, scheduled messages for birthdays and holidays (`server/occasions.toml`) | 0.33.0 | Nate |
| [Staging](#i8-staging): staging.napsack.io, isolated from production; all browser tests pass against it; load tested: 400 online and 718 texts/s on a nano, no errors ([results](../operations/staging.md#results)) | infra, 0.30.1 | Nate |
| [Group chats on the friend map](#x16-group-chats-on-the-friend-map) (a switch; names only for members), [rounded-square group pictures](#x17-a-better-group-badge-in-the-chat-list) instead of the badge, [incidents on Metrics](#x18-incidents-on-the-metrics-page) (Admins; mark resolved), [low CPU credits a warning](#x19-low-cpu-credits-is-a-warning-not-an-alarm), [long captions wrap](#x20-long-pic-captions-are-cut-off) | 0.30.0 | Nate |
| Move to napsack.getattr.com (old domain redirects) | infra | Nate |
| Development standard ([CLAUDE.md](../../CLAUDE.md)), CI green on GitHub | process | Nate |
| [Loading and slow-network states](#x23-clear-loading-and-slow-network-states), [bigger profile pictures](#x24-tap-a-picture-to-see-it-bigger), [add friends by QR](#x25-adding-friends-a-personal-qr-and-link) | 0.34.0 | Nate |
| [Tabs, a camera tab, and send to many](#x26-tabs-a-camera-tab-and-send-to-many) | 0.35.0 | Nate |
| [Camera zoom](#x27-camera-zoom), [short videos](#x28-short-videos), with [X35](#x35-the-installed-app-keeps-asking-for-the-camera) in part | 0.36.0 | Nate |
| [Edit sent texts](#x29-edit-sent-texts) | 0.37.0 | Nate |
| [Change your username](#x30-change-your-username) | 0.38.0 | Nate |
| [Load in pieces; cache encrypted data](#x31-load-in-pieces-and-keep-encrypted-data-on-the-device) | 0.39.0 | Nate |
| [Captions anywhere on a pic](#x33-captions-anywhere-on-a-pic), [add recipients from a chat](#x34-add-recipients-from-inside-a-chat) | 0.40.0 | Nate |
| [Opening a notification reads the message](#x36-opening-a-notification-goes-there-and-reads-it); [video: a cleaner ring, flip while recording, mute](#x37-video-a-cleaner-ring-flip-while-recording-mute) | 0.41.0 | Nate |
| [Work through pull requests; contributor docs](#p5-pull-requests-and-repository-protection) | process | Nate |
| [Group formats in `/api/config`](#f1-ios-app) (for the iOS app; the first release made from the Mac) | 0.42.0 | Nate |
| [Faster tests, same coverage](#p4-faster-test-runs-same-coverage): four at a time, shared helpers, no waiting out timeouts; sockets answer a close; Metrics tips go with a redraw | 0.42.1 | Nate |
| [Development on a Mac](#p6-development-on-a-mac): tests on macOS, Terraform state in S3, the Mac's SSH key on both servers | infra, 2026-10-29 | Nate |

| Signing out left the last account's chat list on screen for the next one; now sign-out (and an ended session) deletes everything kept in the browser but the pinned keys, then reloads ([S3](#s3-signing-out-leaves-nothing-behind)) | 0.42.2 | Nate |

## Epics

### Process

#### P1. Development standard
- [CLAUDE.md](../../CLAUDE.md): data durability rules, how every change is tested and shipped, prod verification. Grows as we go.

#### P6. Development on a Mac
- Nate (2026-10-29): development moves from the Windows machine to a MacBook Pro, which will mostly build the native iOS app. Confirm from the Mac that everything the owner does works: the test suite, Terraform, SSH to the servers, pull requests and merging, release tags, and GitHub Actions deploying staging and production. Test the pipeline with a change nobody sees ([group formats in `/api/config`](#f1-ios-app)).
- **The tests assumed Linux.** The Metrics tab reads CPU, memory, and network from `/proc`, so a server run on a Mac has none of them, and the smoke test and `test_metrics.py` failed there. They now expect only what the system can measure; every deployed server is Linux. Homebrew also refuses to install anything while the Command Line Tools trail the installed Xcode (selecting Xcode isn't enough), so onboarding.md says to keep them current.
- **Terraform state was only on the Windows machine** (`infra/` and `infra/staging/`, and staging's tfvars). **Decided (Nate):** copy it over, then move both roots' state to an S3 backend with locking, so it doesn't live on one laptop. Done (2026-10-29): `fade-tfstate-<account>-us-east-1` (versioned, encrypted, HTTPS-only, lock file), both roots migrated and planning as before ([operations.md](../operations/operations.md)); the local copies are kept off the repo on the Mac.
- **The Mac's SSH key** is in `ssh_public_keys`, which the boot script writes, so adding it replaces the instance. **Decided (Nate):** staging now, through Terraform; production at a quiet time, with the data-volume checklist (CLAUDE.md, Rule 1). Staging done (2026-10-29): new instance, `scripts/ssh.sh` from the Mac works, data volume mounted, clean start. Production's apply is still to do; it also opens port 22 to Nate's address (`ssh_allowed_cidrs`, new in tfvars) and re-uploads the health monitor (the same code, zipped on a Mac).
- **Done (2026-10-29):** the suite passes on macOS; both roots' state is in S3; the pipeline worked end to end from the Mac (pull requests, merges, staging, `server-v0.42.0` and `server-v0.42.1`). Production's instance was replaced for the Mac's key after 0.42.1 shipped: snapshot `snap-0df71556136ac32c3` first, row counts the same before and after (27 users, 48 friendships, 588 messages, 90 sessions), the data volume mounted, `scripts/ssh.sh` in from the Mac, port 22 open to Nate's address only. Both roots plan "No changes".
- Staging follows the newest Amazon Linux image (production pins its AMI), so its plan shows a replacement whenever AWS publishes one; applying it is harmless (no user data), and was done the same day.


#### P5. Pull requests and repository protection
- Nate (2026-10-28): branch protection is on: other collaborators reach `main` only through pull requests, reviewed by the code owner (Nate) on the latest push; release tags are protected, need the staging deploy to have succeeded, and only repository admins create them. Admins can bypass all of it.
- Proposal to weigh: work on a branch per release, open a pull request with a real description, let the checks pass on it, then squash-merge, so the history matches what collaborators will do. Also: a review of whether the protection is enough for outside collaborators. Comes last, after the queued features.
- Review (2026-10-29):
  - **One gap that matters: deployments trust the environment name, not the branch.** The AWS roles trust GitHub's OIDC subject `...:environment:staging` and `...:environment:production`. Branch protection guards `main`, but anyone with write access can push another branch whose workflow names `environment: staging` (or `production`) and get those credentials. Close it in GitHub → Settings → Environments: **staging** deploys from `main` only; **production** from tags matching `server-v*` only (tags are already protected, admins-only). Optionally, required reviewers on production. (Nate's to change; it's in GitHub's settings, not the repo.)
  - The rest is sound for outside collaborators: pull requests run `ci.yml` on `pull_request` (not `pull_request_target`), so a fork's code runs without secrets or credentials; CODEOWNERS (`*`) with review on the latest push means nothing merges without Nate seeing the final version; release tags are admins-only. Worth adding: make the CI jobs (`server`, `infra`) required status checks on `main`, with "branches up to date before merging".
  - **Adopted (Nate, 2026-10-29)**, with the environment rules set (staging from `main`, production from `server-v*` tags). Contributor docs: [onboarding.md](../onboarding.md) (Your machine; Working together), `.github/pull_request_template.md`, CLAUDE.md (Shipping; Working together).
  - **Pull requests for our own releases: yes.** A branch per release, a PR whose description is the release notes, checks passing before it reaches `main` (today `main` can briefly be red), then squash-merge: one commit per release on `main`, and the same path collaborators take. The cost is CI running twice (on the PR, then on `main` for the staging candidate), about 15 more minutes per release. Hotfixes go the same way, as their own small PRs. Ready to switch whenever Nate says.

#### P4. Faster test runs, same coverage
- Asked (2026-10-28): can local test runs be trimmed or reorganized without losing any coverage or feedback?
- Already in place: while building, only the affected test runs (one browser test, the unit tests); the full suite runs once per release, and releases group related features (2026-10-28: nine features in seven releases).
- Opportunity, no coverage lost: run the browser tests a few at a time instead of one after another (`scripts/test.sh` runs 25 files in sequence; each uses its own accounts). Tests that change things every page sees (announcements in `test_admin_users.py`, Team Napsack in `test_team.py`, metrics and roles) would still run alone, before or after the rest. Expected: several minutes less per run. Watch for timing flakes under load before adopting it.
- Not recommended: dropping overlapping checks between the smoke test and browser tests. They test different layers (the API directly, and the app as a person uses it), and the overlap is what catches a client and server drifting apart.
- **Nate (2026-10-29):** the browser tests take too long, locally and in GitHub's billed minutes. Find the bottleneck; share what's expensive or repeated (helpers in a common file); keep every bit of coverage. Also: run unit and API tests in CI (they always have been: `scripts/test.sh` runs all of it), and lean on them before browser tests. Print how long each part of `scripts/test.sh` takes, and the total.
- **Measured first** (CI's timestamped log, and sampling where each test waited): CI's test job took 11.4 minutes. Starting Playwright and a browser costs under a second per file, so sharing one browser saves little. The time went to waiting:
  - **The smoke test's sockets** (20s): two never closed until a 10-second timeout, because the client had stopped reading once 16 unread events piled up. And the server never answered a close frame at all (clients saw an abnormal closure, 1006); it does now (0.42.1).
  - **Sign in, else sign up** (15s each time): six copies of a helper waited out a 15-second timeout whenever the account didn't exist yet (`test_admin` 46s → 7s).
  - **Chrome on macOS** takes 20s to quit after each test; on a Mac the tests now use Playwright's own headless browser (also: no Chrome window popping up), and only the video test (Chrome's codecs) uses Chrome.
  - **One file at a time**, on a 4-core machine.
- **Built (0.42.1):** the browser tests run four at a time (`tests/e2e/run.py`), each file in its own process. Files that change what every page sees set `RUNS_ALONE` and run first, by themselves (the announcement, live reload, the exact online count); files sharing the admin account take turns. The helpers 30 files had copied (`sign_up` in 13 versions, `befriend` 18 times) are in `common.py`, 650 lines fewer. `scripts/test.sh` and `test-one.sh` share their setup (`scripts/test-env.sh`), and `test.sh` prints each part's time and the total. Locally: 9.5 minutes → 2.75 (browser tests 467s → 110s, smoke test 74s → 45s).
- **On CI** (0.42.1): the test job takes 4 to 6.5 minutes, depending on the runner (11.4 before). `test_marks` takes ~75s there against ~15s on a Mac, evenly slower through every step (run.py stamps each line), so the runner, not one wait; worth a look if it grows.
- **Next, worth doing:** go through the browser tests for checks that are really API rules (who may, what's refused) and make sure the smoke test owns them, leaving the browser test to show the person sees it. CLAUDE.md now says to test each rule at the lowest layer that proves it.

#### P3. Testing in WSL (and moving the repo there)
- **Dropped (2026-10-29):** the project no longer assumes anyone's machine; [onboarding.md](../onboarding.md) sets up macOS, Linux, or Windows through WSL (keeping the code on WSL's own disk). The notes below are kept as history.
- **Recommendation: move the repo into WSL** (`~/code/fade`), after moving Terraform state into an encrypted, versioned S3 bucket.
  - Why: builds and tests on `/mnt/c` go through a slow bridge to the Windows disk; inside WSL they're several times faster. Smart App Control stops mattering, file modes and line endings are native Linux, and there's one environment for build, test, deploy, and Terraform.
  - What changes for you: open the project with VS Code's WSL extension (`code .` from WSL). Windows still sees the files at `\\wsl$\Ubuntu\home\nate\code\fade`.
  - The careful part: `infra/terraform.tfstate` and `terraform.tfvars` aren't in git and exist only on this laptop. Moving state into S3 first takes the laptop out of the picture (encryption, versioning, locking), and the folder's location stops mattering. Then clone fresh in WSL, copy `terraform.tfvars`, confirm `terraform plan` says "No changes", and keep the old Windows folder as an archive rather than deleting it.
- Windows Smart App Control (on, enforcing) blocks every freshly compiled program, so `cargo build`/`cargo test` and the local server only run in WSL. Unit and API tests already run there (`bash scripts/test.sh --no-browser`).
- The browser tests need three system libraries in WSL: `sudo apt-get install -y libnspr4 libnss3 libasound2t64`. Until then they run from Windows against a WSL-built server (CLAUDE.md, Environment notes).
- Done: libraries installed; `bash scripts/test.sh` runs the whole suite in WSL, browser tests included. It caught a phone layout bug (admin header) that the Windows runs missed.

#### P4. Mark inactive instead of deleting
- Done (0.8.0). Decided: the database never loses a row. Unfriending, declining or cancelling a friend request, and signing out mark the row (`ended_at`, `resolved_at`, `revoked_at`) instead of deleting it, and every friendship change is also written to an append-only history.

#### S1. Request auditing and security hardening
- Requested: log the source IP and other useful request details, to see who's probing the endpoints.
- Requested: a hardening pass so nothing sensitive can ever be served.
- Built (0.9.0): every request logged with client address (from Caddy's `X-Forwarded-For`, trusted only from loopback), user agent, and host; sign-in/sign-up rate limits (per address and per username, before the slow password check); `no-store` on all API responses; X-Frame-Options, COOP/CORP, and a default Permissions-Policy on everything; smoke-test probes for ~25 sensitive paths and a sweep of every API response for secret fields.
- Possible follow-ups: an admin view of the noisiest addresses (rejected requests per IP), and moving Terraform state off the laptop into an encrypted, versioned S3 bucket (it holds the invite code in plain text).

#### P2. Turn on CI/CD
- [x] Commit the admin panel, versioning, tests, and docs (`6f0519f`).
- [ ] Commit this round: CLAUDE.md, plan, unit tests, crypto vectors, domain redirect, SSH keys, CI fixes.
- [x] Apply the GitHub deploy role (`infra/github.tf`). Done with the domain apply.
- [ ] Set the repo variables (`terraform output github_actions_variables`), create the `production` environment, protect `main` ([releasing.md](../operations/releasing.md#one-time-setup)).
- [x] Repo variables set. CI green on GitHub.
- [ ] Create the `production` environment, then ship a tagged release through the workflow. Until then, releases use `scripts/deploy.sh` with the version bumped in `server/Cargo.toml`.
- [x] Get CI green. The first run (`6f0519f`) failed with exit 126: scripts weren't executable in git. Fixed (mode bits, `bash scripts/test.sh`); confirm on the next push.
- [ ] Bump to 0.2.0 and ship `server-v0.2.0` through the release workflow. Production is running the same code today as build `6f0519f-dirty`.
- [x] The release pipeline (2026-10-23, [releasing.md](../operations/releasing.md#releasing-the-server)): every push to `main` is tested, built once as a release candidate (`releases/main/fade-server-<sha>`, newest ten kept) and put on staging; a `server-v*` tag promotes that same binary to `releases/tags/fade-server-<version>` (kept forever) and production, after a backup. One AWS role per GitHub environment (`infra/github.tf`); the old tag workflow's file was invalid YAML (a stray line), which is why it "failed" on every push.
- [x] Staging variables set; the first release through the pipeline, `server-v0.31.1` (2026-10-23): main → candidate `548ec6a` on staging → tag → the same binary on production, backed up first. The deploy roles had to accept GitHub's id-based OIDC subject (`repo:owner@id/name@id:...`). The bucket was then cleaned to the new layout: 46 older builds moved to `releases/tags/` with their commit as metadata.

#### P7. A GitHub Release for every server release
- Nate (2026-10-29): the release pipeline also creates a GitHub Release for the new `server-v<version>` tag, with release notes generated automatically, marked as the latest release.
- Built: `release.sh github-release`, the workflow's last step (needs `contents: write`), with notes from the previous `server-v*` tag (`--notes-start-tag`), so iOS tags won't mix in.
- Notes: GitHub's generated notes list the pull requests merged since the previous tag, which now covers every change (they all arrive through pull requests). Create it in `release-server.yml` after production is updated, so a Release means it's live; the job needs `contents: write` for it. Open: when iOS releases (`ios-v*`) start, which one is "latest" (probably the server's, with the app's as its own Releases).

#### P8. A release refuses a commit staging never ran
- Found 2026-10-29: 0.42.2 (`99c0b7c`) reached production without staging ever running it. Main's CI for that commit failed (D11, a flaky browser test), so it made no candidate, and staging stayed on 0.42.1. The release then found no candidate and fell back to "built too long ago": it tested without the browser tests, built, and shipped. The code was fine (the browser tests had passed on its pull request, production checked out clean, and the job was rerun green afterwards), but the rule "tag a commit staging has run" was only a habit.
- Proposal: `release-server.yml` asks GitHub whether main's CI passed for the tagged commit, and refuses the release when it didn't (or never ran), saying so. Rebuilding stays for candidates that aged out. Also: `releasing.md` and the release checklist say to check staging's `/api/config` build before tagging.
- Nate (2026-10-30): yes, fix it ("it would be good to fix this for security"). Built: `release.sh staging-ran` asks GitHub for main's CI run on the tagged commit and its **Release candidate on staging** job, and the release stops unless both passed; rebuilding stays only for candidates that aged out. Tried on real history: refuses `99c0b7c` (0.42.2, main's CI failed) and an iOS-only commit (no candidate), allows `1fd2a25`.

### Features

#### F1. iOS app
- iOS app. This is the big one.
- Plan and milestones: [mobile.md](../design/mobile.md). Push notifications are part of it. **The task list: [plan-ios.md](plan-ios.md).**
- **Decided (Nate, 2026-10-29): native Swift**, in Xcode, instead of React Native and Expo; Android later as its own Kotlin port. The encryption is ported to each language and held to the pinned vectors. First milestone: the Swift crypto passing every vector.
- Needs: a Mac with Xcode (no paid account to start: the Simulator, and a free Apple ID's Personal Team on Nate's iPhone); the Apple Developer Program for push notifications and TestFlight (waiting on Apple).
- Getting it to early users: TestFlight (internal testers first, then an external group by public link, which needs a short Beta App Review).
- Built (0.42.0): `/api/config` lists `group_message_formats` (0, 3, 5, 7) beside `message_formats`, so the app learns every format a history can hold from the call it makes at launch.
- **Set up (2026-10-29):** `ios/Napsack.xcodeproj` (SwiftUI; settings in `ios/Config/*.xcconfig`, the signing team per machine) and `ios/NapsackCrypto` (a Swift package; format 1 passes its vectors, read straight from `tests/vectors/`). The app is one development screen: a server's `/api/config` with the `X-Napsack-Client` header and the minimum-version check, and the key derivation timed on the phone. Built and tested on the Simulator; Nate runs it on his iPhone 16 Pro with a free Apple ID (`.dev` bundle id, so `com.getattr.napsack` stays free for the paid team). [ios-onboarding.md](../ios-onboarding.md) explains it all for someone new to Xcode.
- **How iOS work goes (Nate, 2026-10-29):** a working branch and a pull request, checked locally (`swift test`, the app's tests, the phone); no server CI, staging, or release tag unless the server changes too (`ci.yml` skips pull requests that change only `ios/` and the docs). The app's CI (`ios.yml`) runs the same checks on GitHub (on since 2026-10-29, #16).
- **Every format in Swift (2026-10-29):** `NapsackCryptoChecks` is `vector-checks.js` in Swift; all 64 checks pass on the Mac and in the app (a screen, and ⌘U on the phone), and keys and messages made in Swift open in the web client.
- Earlier (2026-10-19): crypto moved to `shared/crypto/` and checked in Node and Chromium; `mobile/` became an Expo app whose one screen ran every vector check on a phone. Retired with the move to Swift; `mobile/` goes once `ios/` passes every vector.

#### F2. Password reset and recovery
- Password reset flow - email?  Admin recovery key for support.
- **Design catch:** the password is also the key to message history. A reset (by email or by an admin) can give someone their account back, but their old messages become unreadable, because nobody else holds the key. An admin recovery key that *could* restore history would mean the admin can read everyone's messages, which ends end-to-end encryption.
- **Recommendation:** a personal recovery key shown once at sign-up (saved by the user) restores everything. An admin-assisted reset restores access to the account and friends, with history lost. Email is optional; we don't collect emails today.
- **Decided:** a recovery key held by the user (restores everything) plus admin-assisted reset (restores the account, history is lost). No admin key that can read history. Email collection is still open; only needed for self-serve resets.
- **Decided (2026-10-19):** after a reset, friends verify the new key by safety code, with an "accept without checking" button for those who want it.
- Done (0.14.0): recovery key shown once at sign-up (existing accounts get a prompt); change password; admin reset codes (one-time, 24 hours, hashed); friends' warning explains a reset and offers both choices; old keys kept locally to read history. Every replaced credential goes to `credential_history`. Pinned vectors: `tests/vectors/recovery.json`. The iOS app has to implement the same.

#### F3. Chat pagination
- Text chat pagination. We DO want texts to live forever. Make sure the clients use pagination for when chat history grows extensively.
- The server already pages (`?before=&limit=`). The web client loads the newest 100 and never asks for more. Add load-on-scroll-up, and keep the chat list query fast as tables grow (check indexes).
- Done (0.5.0): chats open on the newest 50; scrolling up loads 50 more at a time without jumping; short histories fill the screen; the top says where the chat began; reconnecting merges new messages without dropping loaded history. The iOS app should page the same way (`?before=<oldest id>&limit=50`).

#### F4. Profile page
- User profile page.  View your list of friends and some stats that belong to you. Friends can view each other's profiles.
- Done (0.4.0): your profile (friends list, texts/pics sent and received, how many of your pics were opened) from the Friends sheet; a friend's profile (friends since, what you've exchanged, their friend count, friends you share) from the chat title. A friend's full friend list isn't shown, only mutual friends, so friends can't map each other's social graph. Easy to change.

#### F5. Profile pic and nicknames
- Profile pic. Nicknames settable by own user.
- **Decided:** visible to friends only, enforced by the server (not end-to-end encrypted). Same for nicknames.
- **Decided (2026-10-19):** people set their own display name, and anyone can also give a friend a nickname only they see.
- Done (0.13.0): display name and picture from your profile; a nickname from a friend's profile. Shown as nickname, else display name, else username, with `@username` alongside wherever they differ. Every name and picture is kept (append-only tables, migration 0008). Pictures rebuilt by `images::clean`. Group members who aren't your friends show by username.

#### F6. Captions on pictures
- Write text caption on a picture before you send it.
- The encrypted picture is just JPEG bytes today, so a caption needs a new message format (an envelope holding picture + caption). That follows the readers-before-writers order in [releasing.md](../operations/releasing.md#compatibility-rules). If the iOS app can already read format 2 when it launches, this gets simpler.
- Done (0.13.0): format 2 seals the caption in with the photo (pinned vectors in `tests/vectors/format2.json`). Every direct pic is format 2 now; format 1 pics still open. Group pics carry a plain caption (they aren't end-to-end encrypted), revealed when opened. Captions show across the photo in the viewer.

#### F9. Pics last 30 days
- Requested: unopened pics shouldn't expire for a while, around 30 days.
- **Why it isn't a setting change:** unopened pics live only in server memory, so every restart (each deploy) loses them, and the memory pool is 128 MB.
- **Proposal:** keep each unopened pic's ciphertext in a file on the data volume until it's opened or 30 days pass. It's end-to-end encrypted, so the server still can't see it. View-once stays: the file is removed when opened or expired, which is the feature, not a data loss. Restarts no longer lose pics, and the server expires them by age from the database. A disk cap of about 256 MB (~1,500 pending pics) fits the 1 GB volume; growing the volume later is a safe, in-place change.
- **Trade-off to accept:** a pic's ciphertext now sits on disk while it waits, and can linger in the daily disk snapshots for up to 30 days after it's opened. Still unreadable without the recipient's keys, but no longer "only ever in RAM". The docs and the "never written to disk" wording change accordingly.
- Done (0.13.0), as proposed: files under `<pic dir>/direct/`, 256 MB cap, 30-day lifetime. `tests/restart_test.py` restarts the server between sending and opening. Pics held in memory by 0.12.0 at the moment of the upgrade were lost one last time.

#### F7. Group chats
- Group chats (encryption design implication)
- Every pair of friends shares a key today. Groups need either per-member encryption (simple, fine for small groups) or a group key handed out to members (scales better, harder when someone leaves). Design doc first.
- Done (0.10.0): create groups with your friends; any member adds their own friends and renames; the owner removes people; anyone leaves (two taps); the owner role passes to the longest-standing member. Members see history from when they joined, by message id. Joins, leaves, removals, and renames appear in the chat. Unread counts, paging, live updates. Nothing is deleted (memberships are marked ended). Up to 32 people.
- Next for groups: end-to-end encryption (group key per membership change), pics in groups (after encryption, so the server never sees photos), and "seen by".
- **Decided (2026-10-20):** ship groups now without end-to-end encryption, and add it later. Group messages are stored readable by the server (TLS in transit, encrypted disk), and the app says so clearly in every group. Direct chats keep end-to-end encryption. Group encryption later becomes a new message format, following the readers-before-writers rule.

#### F8. Account safety basics
- Rate-limit sign-in attempts per username and per IP.
- List signed-in devices with "sign out everywhere".
- Done: sign-in limits (0.9); "sign out other devices" with a count of other sessions (0.14.0), which also closes their live connections. A per-device list (names, last used) would need sessions to record a device label; not yet.

#### F10. Install as an app, with notifications
- Make the web app installable (a Progressive Web App) and send push notifications for new messages, pics, and friend requests.
- **Why now:** today nobody hears about a message unless napsack is open in a tab. iPhones support web push for apps added to the home screen (iOS 16.4+), so friends get a real-feeling app with notifications before the native app ships, and the server side (subscriptions, sending, preferences) is reused by the iOS app's push later.
- **Pieces:**
  - `manifest.webmanifest` (name, icons, theme, `display: standalone`) and a small service worker, served from the binary like everything else. The service worker only handles push and notification clicks; it doesn't cache the app, so updates stay instant and the "napsack was updated" banner keeps working.
  - "Turn on notifications" in the account bar/profile; an "Add to Home Screen" hint on iPhone, where push only works once installed.
  - Server: VAPID keys (in SSM, like the invite code), a `push_subscriptions` table (marked ended on sign-out or when the push service says it's gone; never deleted), and sending with the Web Push protocol (payloads encrypted to each browser, RFC 8291).
  - What a notification says: **who, never what**. "Ana sent you a pic", "New message from Ben", "Cal wants to be friends". The server can't read direct messages anyway; for group chats (readable by the server today) it still shows only "New message in Road trip", so turning on encryption later changes nothing.
  - No notification when you're looking at that chat; per-chat mute comes with X3.
- **Tests:** a fake push endpoint in the smoke test (receives and checks the encrypted payload's shape); browser test with a real service worker in Chromium.
- **Decisions:** none blocking. Rule 1: subscriptions are marked ended, not deleted.
- Done (0.15.0): manifest, icons, a push-only service worker; VAPID key made once and kept in the database; RFC 8291 encryption checked against the RFC's worked example and decrypted independently in the tests; endpoints limited to known push services; no push while on screen; notifications for texts, pics, reactions, group messages, friend requests. Not yet: per-chat mute (X3).

#### F11. Reactions and replies
- Tap-and-hold a message to react (a small fixed set: ❤️ 😂 😮 😢 👍 👎), or swipe/tap to reply to it with a quote.
- **Design:** both are end-to-end encrypted in direct chats. This introduces **text format 2**: the encrypted plaintext becomes a small JSON envelope (`{"t": "hi", "re": <message id>}`) instead of bare text, so future fields (replies, mentions, edits) don't each need a new format. Reactions are their own message kind (`reaction`), encrypted, pointing at the message they react to (the server sees which message got a reaction and when, not which emoji).
- Readers before writers ([releasing.md](../operations/releasing.md#compatibility-rules)): the web app ships both at once; the iOS app should read text format 2 from its first release. New pinned vectors (`tests/vectors/format2_text.json` or similar).
- Group chats get the same (plaintext for now, like the rest of group messages).
- A reaction can be changed or removed: a new row that supersedes the old (Rule 1), never an update that loses history.
- Done (0.15.0) as designed. Tap a message for the reaction row and Reply; quotes link back to the original.

#### F12. Typing and "active now"
- "Ana is typing…" in an open chat; a green dot and "Active now" / "Active 5m ago" on friends.
- Typing travels over the WebSocket only (throttled, a few seconds' lifetime), never stored. "Active" comes from `last_seen_at`, which already exists, plus who has a socket open.
- Privacy setting: "Show when I'm active" (default on), and if you hide yours you don't see others'. Friends only, like everything else.
- Groups: typing shows names ("Ana and Ben are typing…").
- Done (0.15.0), including groups.

#### F13. Draw on pics
- After taking a pic, draw on it with a finger or mouse (a few colors and sizes, undo), and drop emoji stickers you can move and resize. Captions (F6) already exist.
- Entirely in the browser: the drawing is flattened into the JPEG before it's compressed and encrypted, so there's no server change and no new format. Works for group pics too.
- Pointer events, so touch, pen, and mouse all work; the canvas respects the mirrored front camera.
- Done (0.22.0): `server/static/draw.js`. After taking or choosing a pic: a pen (six colors, thin or thick), emoji stickers you drag, resize (+/−, the mouse wheel, or a pinch), and undo for all of it. The drawing is kept relative to the photo, then flattened into it and compressed again before it's encrypted, for direct and group pics alike. `tests/e2e/test_draw.py` reads the received photo's pixels.

#### F14. Invite links and QR codes
- Today everyone signs up with one shared invite code from Terraform, then types usernames to add friends.
- **Invite links:** each person can make a link (`/i/<token>`) that signs a new person up and makes them friends with the inviter in one step. Limited uses and an expiry; the inviter sees who joined through it. Admins can still turn sign-ups off entirely. The shared code keeps working until it's retired.
- **QR codes:** your profile shows a QR code of a friend link; scanning it with a phone camera opens napsack with "Add Ana?" ready. Generated in the browser (a small QR encoder, written here rather than a third-party script, per the no-CDN rule).
- Tokens are random, stored hashed, marked used/revoked (never deleted), and rate-limited like sign-in.
- Done (0.17.0): one link does both (sign up with no code, or add if signed in); 10 uses, 7 days, turn off any time; the Friends sheet shows a QR code and who joined. The QR encoder is our own (`server/static/qr.js`), checked module for module against Python's `qrcode` and pixel by pixel on screen.

#### F15. Streaks
- A 🔥 and a count next to a friend when you've both sent each other a pic every day for 3+ days, and an ⌛ when today's streak is about to run out.
- Computed on the server from message metadata it already has (who sent a pic to whom, and when), in each person's own time zone (the client sends its offset). No content involved.
- Also: your longest streak on your profile, and on a friend's profile, your streak together.
- Done (0.23.0): `streaks.rs`. A day counts when both of you sent the other at least one direct pic that day, in the viewer's own time zone (`?tz=`). 🔥 and the count by a friend's name from 3 days; ⌛ when it stands through yesterday, today hasn't counted, and less than 6 hours are left. A friend's profile shows the streak and the longest; yours shows your longest with anyone. One query per list load, from when pics were sent (no content).

#### F16. Voice notes
- Hold the mic button to record (up to 2 minutes), release to send. Plays in the chat with a waveform; can be replayed (not view-once).
- End-to-end encrypted in direct chats like pics: recorded with `MediaRecorder` (Opus/AAC), encrypted in the browser, stored as a file on the data volume (they're kept, like texts; Rule 1), a new message kind `voice` with its own format number and vectors. Group voice notes are plain for now, like group pics.
- Disk: about 15 KB per 10 seconds; a cap per user and a total cap, shown in the admin panel.

#### F17. Group chats: "seen by", then end-to-end
- **"Seen by":** under the latest group message, "Seen by Ana, Ben" (read positions are already stored per member). Done (0.18.0): `GET /groups/{id}/reads` and a live `group_read` event; "Seen by everyone" once all of 3+ others have read it.
- **End-to-end encryption for groups:** the one part of napsack the server can read. Nate (2026-10-21): "a key point of interest... design it thoroughly and document the approach in the repo."
- **Decided (2026-10-21), Nate:** build Approach D from the design; existing groups switch automatically, no one asked; group names and pictures stay server-visible, but the app must say clearly that group pictures (and names) aren't encrypted; Phase 2 (authenticated member list) later, and never at the cost of easy invites (growing the app and keeping it approachable comes first while sign-up is invite-only); forward secrecy out of scope. Status: Phase 1 built and shipped (0.21.0): see [group-encryption.md, Built](../implementation/group-encryption.md#built). Still to do: encrypt group reactions; refuse new plain-text group messages; Phase 2 later.
- **Design written (2026-10-21): [group-encryption.md](../implementation/group-encryption.md).** Recommends a fresh key per message, wrapped for each member with the pair key they already share with the sender (rather than a shared group key): sender authenticity among members, no key rotation when someone leaves, only primitives we already use. Format 3, readers before writers, then Phase 2 (an authenticated member list). Five open decisions listed at the end of the doc; nothing gets built until Nate answers them.

#### F19. Birthday and more profile fields
- Requested (2026-10-21): "more profile field entries like a birthday (optional)."
- Friends-only like the rest of the profile (server-visible, not end-to-end encrypted). Birthday as month and day, with the year optional; friends see it on your profile, and maybe a small 🎂 on the day. Other candidates to offer: pronouns, a short "about" line. Stored append-only like display names (Rule 1), validated like other text (`text.rs`).
- Done (0.20.0): birthday on your profile (month and day; year optional, 1900 to now; real dates only, Feb 29 fine without a year), shown to friends on your profile, and a 🎂 by your name in friends' chat lists on the day (their own time zone). `user_birthdays` (migration 0013), append-only. **Still to offer:** pronouns, a short "about" line.

#### F18. Disappearing texts
- Per-chat setting: texts disappear 24 hours after they're read.
- **Needs a decision:** this conflicts with Rule 1 ("data in our DB can never be deleted"). Options:
  1. **Hidden, not deleted:** the server keeps the ciphertext forever but stops serving it after the timer. Honest about it in the UI ("hidden from the chat; napsack keeps an encrypted copy"). The server still can't read it.
  2. **Real deletion for these only:** an explicit, narrow exception to Rule 1 for ciphertext the sender asked to disappear, like pic files today. Needs the user's sign-off on the rule change.
  3. **Skip it.**

#### F20. Better video quality
- Nate (2026-10-29): the video quality is pretty low. Fine for now; list the options (formats, resolutions, sizes). Metadata is always stripped from videos, as from pictures.
- Today (0.36.0, X28): drawn through a canvas at 30 frames a second, longest edge 1280 px, 1.5 Mbit/s of video and 64 kbit/s of sound; H.264 (Baseline) and AAC in MP4 where the browser records it (Safari, newer Chrome), otherwise VP8 and Opus in WebM. At most 4 MB and 10 seconds (`FADE_VIDEO_MAX_KB`, `FADE_VIDEO_MAX_SECONDS`).
- Metadata: re-recording on the device means a video carries nothing from the camera's own file (no location, device, or time). The server can't strip anything, since videos are end-to-end encrypted, so every option below keeps the re-encode on the device.
- Options, cheapest first:
  1. **More bits, same cap:** 10 seconds in 4 MB allows about 3.2 Mbit/s in all, so 2.5 to 3 Mbit/s of video, nearly twice today's. One number; no format change.
  2. **A better H.264 profile** (Main or High instead of Baseline) where the recorder offers it: better at the same size, and still plays wherever MP4 does.
  3. **Record the camera directly** when there's no zoom or mirroring, instead of through the canvas: sharper, and fewer dropped frames on slow phones. Zoom and the front camera's mirroring still need the canvas.
  4. **Higher resolution** (1920 px edge): only together with more bits, or it looks worse.
  5. **VP9 or AV1** (WebM): better for the size, but some iPhones don't play WebM, so it needs a fallback.
  6. **A larger cap** (say 8 MB): longer or sharper videos, against the disk budget and upload time on a poor connection (`guard.rs`, security.md).
  7. **The iOS app** ([F1](#f1-ios-app)) records with AVFoundation (HEVC or H.264, at settings it chooses), which is where iPhones gain most.
- Whatever is chosen: compare on real phones (an iPhone and an Android), and check sizes stay under the cap.

### Debug

#### D13. "Database is locked" under load (fixed)
- Found 2026-10-29 by the iOS app's tests (sending to a group while other tests ran): a 500, "database is locked". A transaction that reads before it writes (most of ours) can't wait for SQLite's write lock if another write landed in between, and fails at once despite the 5-second busy timeout. Rare at production's size, but it loses a send.
- Fixed: every transaction begins `IMMEDIATE` (`db::write_tx`), taking the write lock first and waiting its turn; `db::tests::transactions_take_the_write_lock` keeps it that way, and `concurrent_writers_wait_their_turn` fails without it.

#### D12. iPhone videos came out black, and the ring stuck (fixed in 0.43.0)
- Reported (Nate, 2026-10-29), in the installed web app on an iPhone, not every time: the video was black, stayed black after recording, and the recording ring stayed where it was. Likely cause: 0.41.0 (X37) records a silent copy alongside each video so "send without sound" carries none, and WebKit (Safari and every iPhone browser) doesn't reliably run two recorders at once; when the main one never says it stopped, nothing finished the video.
- Fixed: on WebKit, one recorder only, as before 0.41.0 (no "send without sound" there for now). Everywhere, a recorder that hasn't finished 3 seconds after stopping is finished with what it recorded, or says to try again, and the app reports "video recorder never stopped" (with its type and how much it had) to the log viewer, so another case shows up there. `test_video.py` covers both.
- Also (Nate, 2026-10-29): zoom now returns to 1× for each new pic or video (it stayed where the last video had zoomed to).
- Open: if it happens again, the log viewer has the details. Nate: the web app's camera on phones may just be less reliable; the iOS app's camera (AVFoundation) is the long-term answer.

#### D11. A tap on the shutter could count as a hold when the page was busy (fixed in 0.43.0)
- `test_chat.py` failed once on main (2026-10-29, CI for `99c0b7c`): after the shutter tap, Send never appeared. Likely cause: the shutter starts a video when its hold timer (`HOLD_MS`) fires before the pointer is let go. On a busy page the timer can run before the queued `pointerup`, so a quick tap becomes a short video and no photo. A slow phone could do the same to a person.
- Fixed (0.43.0): tap or hold is decided by the events' own times (`pointerup.timeStamp - pointerdown.timeStamp`), not by which callback ran first; a recording the timer started too soon is discarded and the click takes the photo. `test_video.py` handles a quick tap only after the hold timer ran, and fails without the fix.

#### D10. 0.39.0's fix for D9 cut the bottom off (undone in 0.41.1)
- Reported (Nate, 2026-10-29), on an iPhone 16 Pro and a friend's phone, both from the Home Screen: the composer and tab bar were half off the bottom, and a chat couldn't scroll to its newest messages (pics there couldn't be tapped). 0.39.0 sized the app to the screen's height as the phone reported it, which was taller than what's visible. Undone: the app is pinned to the visible edges again (0.36.0 to 0.38.0), which may leave a gap under the tabs but never hides anything. Nate: a gap is acceptable; nothing may be cut off. The gap needs a real iPhone to diagnose, not a guess (D9 stays open).

#### D9. The installed app's tabs sat above the bottom edge (fixed in 0.39.0)
- Reported (Nate, 2026-10-29), after 0.36.0 pinned the app with `position: fixed; inset: 0`: on the Home Screen, a sizeable gap stayed under the tabs. With a black-translucent status bar and viewport-fit=cover, Safari can lay the page out as the screen minus the status bar while drawing it from the top, so anything pinned to the bottom stops short. Now, when installed on an iPhone (`navigator.standalone`) and full screen, app.js measures the screen and the app, camera, viewer, and Profile tab are sized from the top by that height; the page itself can't scroll while the app shows. `test_installed.py` checks the app takes the screen's height even when the page is laid out 59 px short. Chromium can't reproduce Safari's mistake, so check it on a phone after release.

#### D8. Send to… looked empty on iPhones (fixed in 0.36.0)
- Reported (Nate, 2026-10-29): the picker showed no friends or groups, and searching showed nothing either, not even "Nobody by that name". Safari gave the list (`flex: 1` in a column) no height when the sheet's height wasn't fixed, which Chromium handles, so the tests passed. The picker is plain blocks now and the list sets its own height; `test_tabs.py` checks the list has room for its rows and isn't flex-sized. Chromium can't show Safari's mistake, so check it on a phone after release. Also: sliding up while recording zooms about half as fast (Nate: a bit too sensitive).

#### D7. Three layout bugs from 0.35.0 (fixed in 0.36.0)
- Reported (Nate, 2026-10-29). **System button at the foot of the profile:** a link styled as a button stayed inline, so its words sat high, and took the visited-link purple; `a.button` now centers like a button, in the button's colors (`test_roles.py` compares it with Sign out). **System tabs on a phone:** the header kept a fixed height when its tabs took a second row, so they spilled onto the page; it grows now (`test_admin.py`). **Tabs on the installed iPhone app:** the bar sat above the bottom edge until the page was scrolled, and again after coming back from System: the app was sized with `100dvh`, which an installed iPhone app works out wrong when a page opens. The app and the camera are now pinned to the screen's edges (`position: fixed; inset: 0`); `test_installed.py` checks the tabs sit on the bottom edge, though Chromium can't reproduce the iPhone's own mistake, so check it on a phone after release.

#### D6. "Loading…" stayed above a loaded profile (fixed in 0.35.0)
- Reported (Nate, 2026-10-29), in production: the profile's stats showed "Loading…" in the first row after everything had loaded, pushing the grid out of line. 0.34.0 (X23) put the placeholder in, and the loaded stats were added after it instead of replacing it. Fixed, and `common.no_placeholders` now checks after every load in `test_profile.py`, `test_loading.py`, and `test_invites.py`; CLAUDE.md asks the same of any new loading state.

#### D5. "Seen" sometimes never showed (fixed in 0.35.0)
- Found from a CI failure in `test_chat.py` (2026-10-28): when a friend read a text before the sender's own copy came back from the server, the "read" event found nothing to mark, and the copy arrived unread. Now the app remembers how far each friend has read and applies it to copies that arrive later. `test_resilience.py` holds the response back to force that order.

#### D4. Notifications stayed after opening napsack (fixed in 0.34.0)
- Reported (2026-10-28): "Notis don't clear after you open the app?" Confirmed: only a tapped notification closed itself (`sw.js`); opening napsack any other way left the rest on the lock screen. Now napsack closes its notifications when it opens or comes back on screen, and on sign-out. `test_live.py` delivers a push and checks it's gone after opening.

#### D1. Log viewer
- Log viewer (also for admins only). Central view of server logs with search features. Along with this, take a pass at the server code and improve logging. Debug logging can be verbose.
- Logs never include message content (the server doesn't have it), keys, tokens, or invite codes.
- Done (0.2.0): structured logging across auth, friends, texts, pics, sockets, and every request; viewer at `/admin#logs` with search, level filter, live tail, and paging. Entries live in memory (last 20,000 since the server started), so a restart clears them; the journal keeps older history.
- Possible follow-up: persist logs across restarts, in a separate log store with rotation (never in the user database).

#### D2. Client debug logs
- Client side debug logs. Browser/iOS client debug logs should be viewable in the admin log viewer as well (see above)
- Same rule: nothing decrypted leaves the device, so clients log events and errors, never text or pictures.
- Done (0.6.0): `POST /api/logs` (signed in or not, 50 entries per request, 300 per user per minute, fields bounded and content-looking names redacted). The web app reports uncaught errors, failed loads and sends, decryption failures, key changes, socket connects, pic compression, and sign-in results. The viewer's Source filter splits server from apps.

#### D3. Admin "Online now" count
- Requested (2026-10-21): the admin overview's "Online now" / "open connections" doesn't always look right; Nate saw 0 while he was online looking at it.
- Found: the count itself was right (people with at least one live connection, and the connections), but the admin page held no connection of its own. Looking at /admin without the app open elsewhere (and on the Home Screen app, Admin replaces the app page) meant you weren't counted: 0 while plainly online. A phone app in the background also drops its connection (iOS suspends it), so it isn't counted until it's opened again; that part is expected.
- Done (0.20.0): the admin page keeps its own live connection while it's showing, so looking at it counts as being online, and the tiles refresh once it's connected. It never claims to be on screen, so notifications still arrive. `test_admin.py` checks the tile reads 1 with only the admin page open (it read 0 before).

### Experience/visual

#### X1. Rename "snap"
- Remove the word 'snap', let's refer to pictures as something else
- **Decided:** *pic*. The UI changes; the API, database, and code keep `snap` internally, the same way `fade` stays the internal name.

#### X2. Account buttons on the main screen
- Requested: move profile and the other account buttons (admin, sign out) out of the Friends sheet to a better spot on the main screen.
- Proposal: an account bar at the bottom of the chat list, with your avatar and name (opens your profile), an Admin link for admins, and Sign out. It's visible on phones too, since the chat list is the home screen there. The Friends sheet goes back to just friends and requests.

#### X3. Chat list tools: pin, mute, search
- **Favorites** first, from Nate's story (since folded into this entry). Taken over on 2026-10-21 and shipped with hiding (below), since both are marks on a chat row.
- **Decided (2026-10-21), favorites:** direct chats and groups both; up to 10; they sit in a "Favorites" section at the top, newest message first (choosing the order by hand can come later); kept on the server so they follow you, private to you. Unfriending or leaving keeps the mark but frees the slot, and it's a favorite again if the chat comes back.
- **Decided (2026-10-21), hiding** (Nate: "swipe and clear a convo... just hide it and remove any local client data... group chats you would just leave"): a direct chat can be hidden from your list; its messages stay on the server, and the browser drops what it had loaded (the friend's pinned key stays, so a changed safety code is still caught). A new message from either side brings it back, as does opening it from "Hidden chats". Groups get Leave instead (two taps).
- Done (0.19.0): one append-only table, `chat_marks` (newest row per user, chat, and kind wins, like nicknames). `PUT /chats/{id}/favorite`, `PUT /groups/{id}/favorite`, `PUT /chats/{id}/hidden`; `favorite`/`hidden` on the lists; other devices update through `friends_changed`/`groups_changed`. A phone swipes a row left for its actions; a computer shows them on hover. "Hid your chat with Maya. Undo". Tests: `marks.rs`, `check_marks` in the smoke test, `tests/e2e/test_marks.py`.
- **Pin** is covered by favorites.
- Done (0.24.0), **mute**: a row action (swipe or hover) with 8 hours, a week, or until turned back on. Muted chats send no notifications (the server checks before each push) and show no unread dot or count, with a 🔕 by the name. `chat_mutes` (migration 0015), append-only and private, on every device.
- Done (0.24.0), **search**: a box at the top of the chat list. Chat names match as you type (hidden chats too); from two letters, messages are searched in the browser over each chat's latest 200 (fetched and decrypted at most once a minute), since the server can't read them. A result opens the chat at that message. Searching further back is a follow-up.
- **Search:** find a chat by name, and search message text. Messages (direct and, since 0.21.0, group) are end-to-end encrypted, so search runs in the browser over decrypted history.
- Pin/mute/archive are stored per person on the server (append-only state, Rule 1) so they follow you to new devices.

#### X4. Open pics back to back
- Requested (2026-10-21): when a chat has several unopened pics, tapping the first one closed goes straight to the next, until none are left.
- Oldest first, within the chat you're in (direct or group). Each pic is still view-once: it's marked opened as it's shown, the same as today, so closing the app halfway leaves the rest unopened.
- The viewer says where you are ("1 of 3") so the next one isn't a surprise; tapping the last one closed returns to the chat.
- Client only: the web app already knows every pending pic in the open chat. The iOS app should behave the same.
- Done (0.18.0): tap a pic, then each tap (or the timer) opens the next; "1 of 3" in the corner; the hint says "Tap for the next pic" until the last. Escape stops. Direct and group chats.

#### X5. Composer grows to 4 lines
- Requested (2026-10-21): the message box is one fixed line. While typing, it should grow to show 3–4 lines of the message, wrapped to the screen width (especially on phones), and scroll inside only after that.
- The `<input>` becomes an auto-growing `<textarea>` (height follows the content, capped at about 4 lines). The pill shape becomes a rounded rectangle once it's taller than one line.
- Enter: on a computer, Enter sends and Shift+Enter starts a new line. On a phone, Return starts a new line and the Send button sends. Messages already keep their line breaks when shown.
- Applies to group chats too. Browser test: type a long message, check the box grows to 4 lines and stops, and that sending shrinks it back.
- Done (0.18.0) as described (`tests/e2e/test_composer.py`).

#### X6. Keyboard stays up after Send
- Requested (2026-10-21): after Send, the message box keeps focus, so on a phone the keyboard stays up and the next message can be typed right away.
- Web: tapping Send moves focus to the button, which closes the iPhone keyboard. Keep focus in the box (the Send button doesn't take focus on press) and refocus after sending.
- **Drag to dismiss:** dragging the chat down toward the keyboard should pull it down. The web can only approximate this (close the keyboard on a downward drag of the messages); it can't follow the finger like native apps. The iOS app gets it for free (`keyboardDismissMode="interactive"` on the message list). **Decided (2026-10-21):** fine to leave the drag gesture to the iOS app if the web version feels off.
- Done (0.18.0): Send keeps focus (and the keyboard); dragging the messages down about 50px closes the keyboard.

#### X7. Pull to refresh the chat list
- Requested (2026-10-21): on the chat list, pulling down past the top refetches the chats, like most phone apps.
- Live updates already arrive over the WebSocket, so this is mostly reassurance, but it does a real, light refresh: refetch the chat list (and friend requests), and reconnect the socket if it has dropped. Nothing else on screen changes; rows update in place without flashing.
- A small spinner or arc appears under the bar while pulling, past a threshold it lets go and refreshes, then tucks away. Touch only (on a computer the list just scrolls). Respects reduced motion. Throttled so pulling repeatedly can't hammer the server (the request budget already caps it).
- In the Home Screen app iOS Safari has no native pull-to-refresh, so this is ours to draw; in a browser tab it must not fight the browser's own reload gesture (`overscroll-behavior` on the list). The iOS app gets `RefreshControl`.
- Done (0.18.0): a sage arc that turns as you pull and spins while refreshing; refetches at most every 3 seconds.

#### X8. Chat list header buttons
- Requested (2026-10-21): the New group button floats in the middle of the chat list bar and doesn't say "new group". It should sit next to Friends, read clearly as "create a group", and the two should be distinct. Friends could use a "plus" too.
- **Decided (2026-10-21):** Friends keeps its icon and sheet (adding, invites, requests). Next to it, a **+** for everything else you can start. With one thing to start (New group), + goes straight to it; once there's a second, + becomes a short menu. Options were on the design canvas's Proposals page.
- Done (0.18.1): wordmark left; Friends then + on the right; + is a soft filled circle labeled "New group". `test_groups.py` checks the placement at desktop and phone width.

#### X9. Removing people from groups
- Requested (2026-10-21): "I want to be able to remove people from groups."
- Today the group's owner can already remove members (group info sheet: tap the group's name, then Remove next to a member); nobody else can. To decide while building: is the request about finding it (make it easier to reach, e.g. from the member list), or about who may remove (anyone who added that person, or any member)? Default unless Nate says otherwise: keep owner-only removal, make it easier to find, and say in the sheet who can remove.
- Done (0.20.0), the default: the member list says who can remove people ("You're the owner, so you can remove people" / "Only Ana can remove people"), and Remove takes two taps like Leave. **Open:** if Nate wants other members to remove people too (for example whoever added them), that's a server rule change in `groups::remove_member`.

#### X10. Befriend people from a group
- Requested (2026-10-22): a new friend of Nate's was added to a group with four of Nate's other friends he didn't know, and needed an easy way to add them.
- Done (0.24.1): in a group's member list, anyone who isn't your friend yet has **Add friend** (an ordinary friend request, with its usual limits), then **Requested**; if they asked you, **Accept**. The sheet updates live when the other person accepts. `test_groups.py` covers it.

#### X15. Friend map
- Requested (2026-10-23): a page graphing friend relationships that shows distinct groups clearly. Build the graph tech as a module; two views: every person's own map (themselves, their friends, and a **?** for each friend of a friend they don't know), and an admin view with a switch between chosen people (default: yourself; one or more; depth 1–2) and everyone.
- Design: [friend-graph.md](../implementation/friend-graph.md). Server decides scope and privacy (`graph.rs`); clusters and layout in a shared, platform-neutral module (`shared/graph/graph.js`, usable by iOS later); an SVG renderer shared by both pages.
- Done (0.27.0): Friends → **See your friend map**; admin → **Graph** tab. Groups found by Louvain modularity, outlined and lettered; three colors at most (validated for every pair), names on every node. Tests: Rust (scope, privacy), Node (clusters, layout, hull), smoke (`check_graph`), browser (`test_graph.py`).

#### X38. Group names cut short in the chat header
- Nate (2026-10-29), bug: in a group chat, the name at the top is cut off early, seemingly always the last three characters, even when there's room: "Rats" shows as "R...", "Gayboiz" as "Gayb...", "Dusty Relics" as "Dusty Rel...". Direct chats, titled with the person's name, aren't affected.
- Where to look: the header title (`#chat-title`, filled for groups in `app.js` where a group opens; its ellipsis is in `style.css`, `.chat-title`). Something in the group header takes room the title needs, or the title's width is fixed before the name is in. Reproduce in a browser test at phone and desktop widths; the fix's test checks a short group name shows in full.
- Fixed (0.43.0): the header's heading was only as wide as its content, and the title button's `max-width: 100%` resolved against that width less the title's own padding, so it came out a few pixels short of the name, whatever its length (the last two or three letters went to the ellipsis). The heading now takes the bar's free space. `test_group_title.py`: short names in full on a phone and a desktop, a long one still ends in an ellipsis without spilling off the screen. Direct chats had room only because their lock button sits beside the heading. The iOS app's title is the system's own and isn't affected.

### Security

#### S2. Roles
- Requested (2026-10-23): proper roles. **User** (everyone invited), **Admin** (a fixed list), and **PowerUser** in between, for people interested in how the app is doing, never for more access to private data or to act on other people.
- PowerUser sees the System pages (the admin panel renamed, with a gear) scoped: Overview without the users table (the reset-password tool is Admin only); Metrics without cost; the Graph with every feature, but people they aren't friends with are anonymous. Logs are Admin only.
- Admins and PowerUsers can make someone a PowerUser in the UI (PowerUsers only their friends); only Admins can take it away.
- The admin list moves out of source control into its own SSM parameter, reloadable without a deploy.
- Design: [roles.md](../implementation/roles.md).
- Done (0.28.0). Production's admin list moved to `/fade/admins` (`scripts/set-admins.sh`, `scripts/reload-admins.sh`); `admin_usernames` in Terraform is no longer used.

#### S4. PowerXtreme
- Nate (2026-10-29): a role between PowerUser and Admin, called PowerXtreme. Only Admins grant it and take it away, and only to people who are PowerUsers already. For now it's identical to PowerUser ("to appease my sister who wants to be more than a PowerUser"); more interesting things can come later.
- Built (0.43.0): `user_role_upgrades`, `POST`/`DELETE /admin/roles/{id}/powerxtreme`, the Roles page (Make PowerXtreme, Back to PowerUser), its badge, and the iOS app treats it as a PowerUser ([roles.md](../implementation/roles.md)).
- Ideas for later (Nate to pick; none of them may show private data or act on anyone, as for PowerUsers):
  - **Looks:** a PowerXtreme badge beside their name for friends (opt-in), an app icon of their own on iOS (alternate icons), a theme or accent only they can choose, a sparkle on their chat bubbles' send animation.
  - **Early access:** new features reach PowerXtremes first, behind a flag ("try it before everyone"), with a feedback button that goes to the log viewer.
  - **Fun data, their own:** a yearly "napsack wrapped" (their messages sent, pics, streak records, busiest hour), computed on the phone from what's already decrypted there, never on the server.
  - **The System pages, a little more:** the friend map's history (how the graph grew month by month, still anonymous beyond their friends), or naming the anonymous clusters on their own graph (kept on their phone).
  - **Bragging rights:** a longer streak grace period, or extra stickers for pics.
  - **Say hello to the team:** a direct line to Team Napsack (a chat that reaches the Admins), with notes back.

#### S3. Signing out leaves nothing behind
- Nate (2026-10-29), bug: signing out and back in as another account (same server, a desktop browser) showed the previous account's chat list. Signing out must clear all local data: storage, IndexedDB, everything.
- Cause: `signOutLocally` reset a list of state by hand and missed the chat list itself, which the next account's screen drew until its own arrived.
- **Fixed (0.42.2):** sign-out, and any session the server ends, deletes everything the browser keeps (localStorage, sessionStorage, the cache, the keystore but its pins, the push subscription), then reloads the page, so no state can be missed. **Decided (Nate):** the pinned keys stay: friends' public keys, which can't open anything, kept per account so a key swapped while signed out is still caught and old messages from before a friend's reset stay readable. `test_sign_out.py` holds the next account's chat list back and checks the last one's never shows (it fails on the old code).

### Infrastructure

- **Next boot script change:** its comment still says `docs/BACKUPS.md`; make it `docs/operations/backups.md`. (Left alone in the docs move on 2026-10-23: any edit to `infra/user_data.sh.tftpl` replaces the production instance, which a comment isn't worth.)

#### X11. Bad connections

Asked for after pics "opened" without showing up. The cause: the server counted a pic as opened when it sent it, so a dropped download, a slow decode, or a tap before the pic appeared lost it (the logs showed pics opened 1-2 seconds apart while tapping through). Shipped in 0.25.0:

- **Pics open only once shown.** Fetching doesn't open a pic; the app confirms (`POST .../opened`) once it's on screen. Unconfirmed fetches count as opened after 15 minutes, so fetching isn't a way around view-once. The viewer says "Opening…" while it loads and explains a failure; the pic stays unopened. Taps in the first 600ms after a pic appears are ignored.
- **Sends are safe to retry.** Texts and pics carry a `client_id`; a resend returns what's stored instead of a copy (groups already had one). Texts go through an outbox: shown at once as "Sending…", retried, then "Not sent" with Try again / Remove, and sent by themselves when back online. Unsent texts live only in the page (never written to the device unencrypted).
- **Reads retry, everything times out.** GETs retry twice on network errors and 502/503/504; requests give up after 20s (90s for pics).
- **The live connection is checked.** A ping every 25s while on screen (and on coming back to the app); no pong in 10s means reconnect. Offline shows a note; back online reconnects and flushes the outbox.
- Tests: `tests/e2e/test_resilience.py` (lost responses, offline, failing downloads), `check_resend` in the smoke test.

Not yet: the iOS app needs the same (it will share the approach when it's built).

#### X12. Double tap a chat to send a pic
- Requested (2026-10-22): double-tapping a chat in the list opens it with the camera already up, to answer with a pic.
- Done (0.25.1): the first tap opens the chat at once (no delay waiting for a second); a second tap within 350ms on the same spot (40px), wherever it lands, opens the camera instead; a quick tap somewhere else is just a tap.
- Changed (0.25.2, Nate): on a phone, where the chat covers the list, a tap now waits 250ms before opening the chat (the row lights up at once), so the second tap of a double tap reliably lands on the row. Computers keep opening at once.
- Changed (0.26.5, Nate: the wait made the app feel laggy): the wait is 150ms, enough for a quick double tap's second tap to land on the row. A slower second tap (up to 350ms after the first) lands on the opened chat and is still caught there, on the finger lifting, without doing anything else. Nothing else waits. Works for groups too; does nothing if the camera isn't available (a changed key). Keyboard Enter doesn't count.

#### X13. Double tap the camera to switch it
- Requested (2026-10-22): double-tapping the live camera view switches between front and back, like the switch button.
- Done (0.25.1): only while the camera is live (not on a taken pic, where taps draw). Double-tap zoom is off app-wide so the browser doesn't take the gesture; pinch zoom still works.

#### X14. Tell groups from direct chats in the list
- Requested (2026-10-22): a very small indicator that a chat is a group.
- Done (0.25.2): a small two-people badge on the group's picture, in the corner where a friend's online dot sits (groups never show that dot); screen readers hear "Group:" before the name.

#### X16. Group chats on the friend map
- Requested (2026-10-23), queued after the current projects: show the group chats around friends on the friend map, as a toggle. Off, the map is exactly as now; on, groups are drawn over it (for example a tinted outline per group chat linking its members you know) without changing how friends are clustered.
- Privacy to settle in the design: a person should only see group chats they're in, and members they don't know stay anonymous, as ?s do.

#### X17. A better group badge in the chat list
- Requested (2026-10-23), queued: the badge's position on the group picture is right, the two-people icon isn't. Try other icons, and a subtle difference in how a group's row is drawn, so groups are distinct at a glance without being loud. Show options for Nate to pick.
- Options shown (seven, on the real list at phone width): badges with two people, speech bubbles, three dots, or the member count; rounded-square pictures with or without a badge; the count by the name. **Nate picked F**: a group's picture is a rounded square (everywhere, not just the list), and there's no badge. The green online dot stays the only mark on a friend's picture.

#### X18. Incidents on the Metrics page
- Requested (2026-10-23), queued: the health monitor's S3 incident records (`health/incidents/`, [health-monitor.md](../implementation/health-monitor.md)) are the source of truth. The Metrics tab shows the last 7 days of incident events to Admins only (not PowerUsers): what failed, the evidence, each repair step, and how it ended. Incidents that resolved in the last 7 days show too, marked resolved, and an Admin can mark an open one resolved (written back to its record, never deleting it).

#### X19. Low CPU credits is a warning, not an alarm
- Requested (2026-10-23), queued: the Metrics tab shows low CPU credits in red, as urgent. It should be a warning (amber). A new or replaced instance starts with few credits and builds them up while idle, so a low balance soon after boot is expected. Red only if credits are near zero *and* the CPU is pinned at its baseline (actually throttled); check the AWS rule for launch credits on t4g standard and say "building up after a restart" when the instance is young.

#### X21. Admin tools for accounts
- Requested (2026-10-24): delete users from an admin page (turning the account off, never deleting data), and other useful admin features.
- Built (0.32.0): System → **Users**, Admins only ([admin-users.md](../implementation/admin-users.md)). People with search and status; one account at a glance (counts and dates only); turn an account off and back on (a row in `deactivations`, nothing deleted: signed out, can't sign in, friends keep the chat but can't send to it, out of the account cap); sign out everywhere; clear a sign-in lock; the reset code, moved here; an append-only record of every Admin action; and announcements, a banner everyone signed in sees live.

#### X23. Clear loading and slow-network states
- Requested (2026-10-28): before data arrives, the chat list says "No friends yet" and chats look empty, which isn't true. Show that things are loading (placeholders shaped like what's coming), say plainly when the connection is very slow or down, and never show an empty state until the server has answered.
- Covers the chat list, a chat's messages, groups, the friends sheet, and profiles. A slow-network notice after a few seconds without an answer; an offline notice when requests fail.
- Built (0.34.0): placeholder rows in the chat list and in chats until the server answers; "Slow connection: still loading…" after 4 seconds; "Can't reach napsack right now" and a **Try again** when requests fail. `tests/e2e/test_loading.py`.

#### X24. Tap a picture to see it bigger
- Requested (2026-10-28): tapping a profile picture (a friend's profile) or a group's picture (group info) shows it large in the middle of the screen, in the same circle or rounded square, over the page. Tap outside it or the × to close.
- Built (0.34.0): `#picture-viewer`; Escape closes it too. Checked in `test_profile.py` and `test_groups.py`.

#### X25. Adding friends: a personal QR and link
- Requested (2026-10-28): keep adding by username, and make it obvious how else to add someone. Decided (Nate): each person gets one long-lived "add me" link and QR, unlimited uses, until they reset it (the old one then stops working). Someone with an account who opens it adds them in one tap; someone new can sign up with it, like an invite. It builds on invite links (`invites.rs`, `qr.js`); the 10-use, 7-day invite links stay for inviting new people.
- The Friends sheet leads with the three ways: show my QR, share my link, add by username.
- Built (0.34.0): `GET /api/friend-link`, `POST /api/friend-link/reset` (migration 0020 marks the invite row `personal`). The token is derived from a server key, so it can be shown again while only its hash is stored. One-time links and reset are under "More" in the Friends sheet. `test_invites.py`, smoke `check_invites`.

#### X26. Tabs, a camera tab, and send to many
- Requested (2026-10-28): on phones, tabs along the bottom: **Chats · Camera · Profile**. The profile and settings move out of the bottom-left button into their own tab (they're growing). Decided (Nate): phones only; computers keep the side-by-side layout, with Camera and Profile buttons in the list pane.
- The camera tab has no chat to send to, so after taking a pic its button is **Send to…**: a list of chats (friends and groups) to pick one or more. Each recipient gets their own end-to-end encrypted copy (format 2 per friend; format 3 per group). The camera button inside a chat stays as it is.
- Built (0.35.0): `#tabs` (phones only); the Profile tab is the profile sheet shown in place of the list (not modal, so the tabs stay usable), with Sign out and System at its foot. Computers get a camera button in the list's bar. Send to… lists every chat a pic can go to (not changed keys, turned-off accounts, or Team Napsack; hidden chats when searched for), newest first. Sending goes to each in turn; if some fail, the message says who got it, and Send again sends only to the rest, with the same ids and sealed copies, so nobody gets two. No server change. `test_tabs.py`.

#### X27. Camera zoom
- Requested (2026-10-28): zoom while taking a pic, with the back camera, on phones (pinch, and a zoom control). Desktop doesn't matter. Uses the camera's own zoom where the browser offers it, else a crop of the frame.
- Built (0.36.0): pinch the camera view, or tap the 1× button (1×, 2×, then up to 5×). Where the camera reports a zoom range, napsack asks the camera (up to 10×); otherwise the preview enlarges its middle and the photo is cropped to match (up to 3×, past which a crop looks poor). Every camera opens at 1×. `test_camera_zoom.py`.

#### X28. Short videos
- Requested (2026-10-28): press and hold the shutter to record, up to 10 seconds (a setting); while recording, sliding the finger up zooms in. Decided (Nate): with sound (asks for the microphone the first time), view-once like pics, in direct chats and groups, end-to-end encrypted.
- A new message format for the envelope (the media type with the bytes; readers before writers), a size cap and disk budget for videos (`guard.rs`, security.md), and the same open-once confirmation as pics.
- Built (0.36.0): formats 4 (direct) and 5 (group), a media envelope with a JSON header (room for later fields, such as X33's caption position), described in how-napsack-works.md; pinned vectors `tests/vectors/media4.json` with an independent check. Recorded through a canvas, so zoom crops and mirroring come out as previewed, at about 1.5 Mbit/s; MP4 where the browser can, WebM otherwise. `FADE_VIDEO_MAX_KB` (4 MB) and `FADE_VIDEO_MAX_SECONDS` (10). Drawing and stickers stay photo-only. `test_video.py`.
- The format number tells the server a video from a pic (as the size would anyway); recorded in how-napsack-works.md.

#### X29. Edit sent texts
- Requested (2026-10-28): tap your own text for an **Edit** option. Later, on the phone app: tap and hold shows the reaction row and a menu below it (Edit, Copy, Reply, ...).
- Decided (Nate): within 15 minutes of sending; recipients see "Edited" and can tap to see earlier versions. Direct and group texts. Every version is kept (Rule 1): an edit is a new encrypted row that supersedes the shown text, never an overwrite.
- Built (0.37.0): tap a text for Reply, Copy, and (your own, for 15 minutes) Edit; the composer says "Editing your message". `edits.rs`, migration 0021 (`message_edits`, `group_message_edits`, `group_edit_keys`); an edit's associated data names the message, so it can't be moved; group edits are sealed for the text's own recipients. 20 edits per text. Pinned vectors `tests/vectors/edits2.json`. `test_edits.py`, smoke `check_edits`. The phone app's tap-and-hold menu comes with the iOS app.

#### X30. Change your username
- Requested (2026-10-28): change your username itself, so it seems completely changed: you're found by the new one, and everything shows it.
- Decided (Nate): old usernames are **reserved forever**: they keep leading to the person ("now @newname", noted as a past username) and nobody else can take them, so no one can be mistaken for a friend under their old name. Renames at most **once every 7 days** (Admins exempt); friends see a note in the chat.
- Encryption: the username salts the password (PBKDF2), so a rename asks for the password and re-locks the private key under the new name, like a password change (old credentials kept in `credential_history`). Safety codes and message encryption use keys and ids, not usernames, so nothing else changes.
- Built (0.38.0): Profile → Username → Change username (with the password). `POST /api/me/username`, migration 0022 (`past_usernames`, unique: reserved forever), `usernames.rs`. Sign-up with an old name says taken; sign-in with one says it changed (not to what); friend requests and Team Napsack's occasions find the owner; an Admin listed by an old name stays an Admin. Friends see "was @old" under the name and a note in the chat for 30 days; profiles list past usernames. Sessions stay signed in. `test_username.py`, smoke `check_rename`.

#### X31. Load in pieces, and keep encrypted data on the device
- Requested (2026-10-28): as more people join, load more incrementally, suited to bad connections, possibly adapting to the connection.
- Decided (Nate): keep the server's responses on the device as they arrive, still encrypted, and decrypt on open, so the chat list and recent messages show at once and refresh in the background. Cleared on sign-out. No readable text is stored beyond what the device already holds (the key).
- Plus smaller first loads (the newest messages first, the rest as you scroll; pictures on demand), sized to the connection when it's slow.
- Built (0.39.0): `cache.js` keeps the server's answers in their own IndexedDB database, as sent (a copy taken before decrypting): the chat list, groups, each opened chat's newest page, who you are, and the settings. The app opens from them while the server answers (the settings wait 1.5 s at most), then the server's answers take over; an ended session still signs out when the server says so. Presence isn't kept. Pages are 20 messages instead of 50 when the browser says the connection is slow or saving data. Signing out clears it. `test_cache.py` holds every request back, and checks no message text is kept.

#### X32. Small things from the production logs (2026-10-28)
- Someone signed in with an email address as their username: say "username, not email" when the field holds an `@`. Done (0.34.0): the sign-in and sign-up forms say so before trying.
- Favorites are capped at 10 (Nate hit it): consider raising it.

#### X33. Captions anywhere on a pic
- Requested (2026-10-28): tap anywhere on a pic or video (not just a strip at the bottom) and a caption line appears there to type into. Enter, or tapping elsewhere on the picture, finishes typing and leaves you looking at the pic with its caption; it never sends. Drag the caption up and down to place it. Only **Send to…** / **Send to <name>** sends.
- The caption's height goes with the pic (inside the encrypted envelope, as a fraction of the height) so the receiver sees it where it was put. Older clients that don't know the field show it in the default place.
- Built (0.40.0): photos are sent in the media envelope as formats 6 (direct) and 7 (group), with `y`; videos carry `y` too (same formats; readers ignore unknown keys). Format 2 pics still open. "Tap the picture to add a caption" shows until there is one; a tap on the photo while drawing or with a sticker picked puts that down first. Pinned vectors `tests/vectors/media6.json`. `test_captions.py`.

#### X35. The installed app keeps asking for the camera
- Reported (Nate, 2026-10-28): napsack on the Home Screen asks for camera permission again and again; the answer isn't remembered. With video (X28) it would ask for the microphone too.
- Findings (2026-10-28): a known WebKit limit, not fixed as of the last reports. An installed web app doesn't keep camera answers across launches (Safari tabs do); within a launch, iOS can ask again after the page's address changes (WebKit bug 215884: hash changes in standalone mode), and napsack changes the hash when links open chats. Each camera open also starts a fresh stream.
- Plan, done with X27 and X28 (same code): stop changing the address while the app runs where it isn't needed; ask for camera and microphone together once for video; consider keeping the stream briefly after the camera closes (a privacy trade-off: the camera light stays on; Nate decides). Asking once per launch is likely the floor on iOS.
- Done in 0.36.0: the microphone is asked for once per camera opening, at the first video, and kept until the camera closes, so several videos in a row ask once. Still to do: the address changes, and the keep-warm question for Nate.

#### X36. Opening a notification goes there and reads it
- Requested (Nate, 2026-10-29): tapping a notification opens that chat or group, which marks the message read, and the notification clears. Partly there: a tap opens the chat (`sw.js`, `openFromLink`) and an open chat reads what's in it; 0.34.0 clears notifications when napsack opens. To check end to end, groups included, and when napsack was closed, in the background, or already open on another chat.
- Done (0.41.0): checked end to end; `test_live.py` follows a notification's link into a chat (the sender sees "Seen") and a group (unread goes to 0). The service worker now hands the link over before bringing napsack forward, so a phone that refuses `focus()` still goes there.

#### X37. Video: a cleaner ring, flip while recording, mute
- Requested (Nate, 2026-10-29), from using it on a phone:
  - The recording ring (a conic gradient on the shutter, with its border made transparent) shows rough edges as it fills. Draw it cleanly, for example as an SVG circle's stroke.
  - Double-tap with another finger while holding to record switches cameras. Recording goes through a canvas (X28), so the camera feeding it can change mid-video.
  - A mute button on a recorded video, before sending. It must take the sound out of what's sent, not just ask the other phone to play it silent (the audio would still be in the file): record a silent copy alongside, or encode again on mute. Choose when building.
- Built (0.41.0): the ring is an SVG stroke; a double tap while recording switches cameras without stopping (the canvas keeps drawing from the preview); with sound, a silent copy records alongside (instant mute, at the cost of a second encoder while recording), and the sound button swaps which file is sent. `test_video.py` checks a muted video decodes no audio.

#### X34. Add recipients from inside a chat
- Requested (2026-10-28): taking a pic or video from inside a chat or group shows who it's going to next to the send button. Tapping that opens the same **Send to…** picker as the camera tab (X26), with the current chat already ticked, to add more friends or groups.
- Built (0.40.0): "To Ben +" beside Send (which then just says Send). `test_captions.py`.

#### X22. Team Napsack: messages from napsack itself
- Requested (2026-10-24), queued: a system account, **Team Napsack**, that can message anyone without being their friend, for occasions: birthdays, holidays, and so on. No UI needed: an easy way to schedule them in code.
- Two kinds of schedule: driven by data (a person's birthday, with configurable recipients, e.g. just the birthday person) and by the calendar (holidays). To start, a couple of test events sent only to `nate`.
- Encryption: Team Napsack gets its own key pair, held by the server, which encrypts each message to the recipient exactly as a friend would, so the app reads it like any chat. The server writes these, so it knows what they say; it still can't read anyone else's chats. Each message is sent exactly once (recorded), and its chat is read-only.
- Built (0.33.0, [team-napsack.md](../implementation/team-napsack.md)): the account (`team.rs`), the schedule in `server/occasions.toml` (`occasions.rs`; birthday, yearly, and one-time; everyone, the birthday person, their friends, or named people; `only` to try one out), `POST /api/admin/occasions/{id}/try` to send one to yourself, and four starting occasions for `nate` only.

#### X20. Long pic captions are cut off
- Bug report from a friend (2026-10-23), queued: a caption longer than one line doesn't wrap; the rest is cut off. There's no visible character limit either. Check the caption box while writing (on the pic editor) and where it's shown (opening a pic, direct and group): wrap it, and either show a limit as you near it or make sure the server's limit is generous and enforced with a plain error. Test at phone width (390px).
- Cause: the caption box was a one-line input, so longer text scrolled sideways inside it, and its 200-character limit (the server's for old group pics, and the sealed format's) was silent. Fix: a box that wraps and grows to four lines, then scrolls; a `153/200` count from 160 characters; Enter still sends, and pasted line breaks become spaces. The viewer already wrapped.

#### I1. Move to napsack.getattr.com
- Done: napsack.getattr.com is live, and fade.getattr.com redirects to it (`redirect_domains`). Data verified intact across the instance replacement (snapshot `snap-09aa617c083942ca9` taken first).
- Serve napsack.getattr.com and redirect fade.getattr.com to it, so old links keep working.
- Browsers keep keys per site, so everyone signs in once on the new address. Their history comes back from their password.
- The domain will change again; nothing should hardcode it (use `terraform output url`).

#### I2. Backups you can restore
- DB backup system. We're moving this ahead of the ASG work: data must never be lost, and today's only backups are daily disk snapshots kept for 7 days.
- Add a daily consistent SQLite backup (`.backup` or `VACUUM INTO`) to a versioned S3 bucket that never deletes, longer snapshot retention, and a restore drill we actually run and write down.
- Built (see [backups.md](../operations/backups.md)): hourly backups via a systemd timer, integrity-checked and gzipped, to a new versioned bucket with `prevent_destroy` and no expiry (cheaper storage after 30 days); the server can only add objects. Disk snapshots go from 7 to 30 days. The admin panel shows the last backup (live in 0.7.0; it says "None yet" until the timer runs). `scripts/restore-drill.sh` checks the newest backup against production, read-only. The backup script passed a dry run against a test database: the uploaded copy restored with identical row counts, and a failure was recorded in the status file.
- Done: infrastructure applied (2026-10-20), first backup taken, restore drill passed and logged in backups.md, and the server's role proven unable to delete or list backups.

#### I5. Growing the single server
- Requested (2026-10-23): if napsack stays one server (today's stack), what runs out first and how do we grow it? Plan in [mono-scaling.md](../design/mono-scaling.md), measured against production.
- In order: the 100-account cap (ours), memory (0.5 GB: the first real upgrade, nano → micro), hourly full backups growing with database size forever (move to Litestream incremental before ~50 MB), CPU credits (the server is in **standard** credit mode: throttled, not billed), the 1 GB data disk (grow online), admin-panel queries. Step 0 is a local load test to replace estimates with measurements. CloudFront in front of the one server is a free improvement (no Elastic IP, no Caddy).
- Nothing built; Nate decides when.

#### I4. Metrics: how is the infrastructure doing?
- Requested (2026-10-22): live machine stats (CPU, memory, disk; ready for more than one machine) and basic server process stats, kept for about 24 hours to a few days, accurate, visual enough to see whether we're in the red, with a cost estimate. No Prometheus/Grafana.
- Approved (2026-10-22): build it in; 3 days, configurable (`FADE_METRICS_RETENTION_HOURS`); CloudWatch and Cost Explorer are fine at cents a month. Nate turned on the `App` cost tag.
- Done (0.26.0), as proposed below; how to read it is in [operations.md](../operations/operations.md#metrics). Not yet: the `agent` mode for a second machine (the store and the tab already handle several hosts).
- **Proposal:** built into the server, no new services.
  - **Collect** every 10s, in the server, from `/proc` and `statvfs` (extends `sysinfo.rs`): machine CPU % (busy, iowait, *steal*), memory used/available and swap, disk used/free and IOPS for the root and data volumes, network in/out; process CPU %, memory (RSS), threads, open files; app request rate, p50/p95/p99 latency, 5xx, live sockets, DB and pic sizes.
  - **Keep** each minute as min/avg/max (so spikes aren't averaged away) in a separate `metrics.db` on the data volume, a fixed ring of 3 days × 1,440 slots per host, overwritten in place: bounded size, survives deploys, never touches user data. The last hour at 10s stays in memory for the live view. Every row carries `host` (the instance id).
  - **More machines later:** the same code runs as `fade-server agent` on a machine without the app and posts its samples to the main server (admin-authenticated). The view already groups by host.
  - **t4g is burstable,** so "in the red" for CPU means burning credits, not 100%: read `CPUCreditBalance` and `CPUSurplusCreditsCharged` from CloudWatch every 5 minutes (free basic metrics; GetMetricData costs cents a month; needs one IAM permission, an in-place change).
  - **See it** in the admin page, a new Metrics tab: a status tile per host (OK / Watch / Red against set thresholds: memory > 80%, disk > 80%, credits falling or surplus charged, steal > 10%, p95 > 500ms, 5xx), then line charts for 1h / 24h / 3d. Inline SVG, no libraries.
  - **Cost:** a live run-rate from a small price table (instance type per hour, gp3 per GB-month, public IPv4, surplus credits, S3 backup size), plus the real month-to-date from Cost Explorer once a day by `App=fade` (needs the tag activated in Billing). Shows the next instance size up and its price.
- Rejected: CloudWatch agent (custom metrics ~$0.30 each per month, about as much as the server itself, and the view lives in the AWS console); Prometheus/Grafana (too heavy for a t4g.nano).

#### I6. Health monitor
- Requested (2026-10-23): an outside check that the single server is healthy, and that tries to fix it, gently first: restart the app, reboot, stop and start (new hardware), and as a last resort replace the server. Every incident is written up with its evidence and what was tried; a notification goes to an SNS topic (where it lands is decided later). No new cost if possible.
- Design: [health-monitor.md](../implementation/health-monitor.md).
- Done (0.29.0): running in production. Replacement (step 4) is a notification for now; automatic replacement waits for a group of one. To get notices: `aws sns subscribe --topic-arn $(terraform -chdir=infra output -raw health_topic_arn) --protocol email --notification-endpoint you@example.com`.

#### I7. napsack.io
- Requested (2026-10-23): `napsack.io` (registered in Route 53, with its zone) becomes the production address; `napsack.getattr.com` redirects to it permanently (301).
- Design and what people will notice: [domain-move.md](../operations/domain-move.md).
- Done (2026-10-23): server replaced with the Rule 1 checklist (snapshot snap-0ffc391a688a0f6b8 first; every row count equal after; the volume remounted). Left for Nate: set GitHub's `APP_URL` repository variable to https://napsack.io, and tell friends to sign in again at napsack.io.

#### I8. Staging
- Requested (2026-10-23): a second, fully separate copy of napsack in AWS, in the same network, on its own address, with no backups. For running the browser tests against a real deployment and for load testing. Production and its data must not be touchable from it.
- Design and results: [staging.md](../operations/staging.md). Done 2026-10-23: `scripts/test-staging.sh` passes everything that can run remotely (push needs a local receiver; live reload needs a debug build). Load test: 400 online at 718 texts/s with no errors; memory per connection is the first limit.

#### I9. Email on napsack.io
- Requested (2026-10-23), planning only: the simplest, cheapest way to have a real mailbox for nate@napsack.io on desktop and phone.
- Options and a recommendation: [email.md](../design/email.md).

#### I10. api.napsack.io: a stable address for the apps
- Nate (2026-10-29): "api.napsack.io is a good idea for mobile clients (not same origin as desktop), that way we can route through that and version and update real hostnames accordingly."
- Design: [api-host.md](../design/api-host.md). An `api.` name that serves only `/api/*` (the socket too), from the same server; release builds of the apps use it, so the site can move without breaking installed apps. Staging gets `api.staging.napsack.io`.
- Needs decision: when to apply it. The Caddy part is the boot script, so it replaces the instance (staging first; ideally with the next change that replaces it anyway). Needed before the first TestFlight build.

#### I3. Auto Scaling group
- Migrate compute to an EC2 ASG, set desired size to 1 for now
    - Eventually enable auto scaling rules, for now keep static
    - Will need to rethink deployment. Bake a new AMI and swap it out? Run deploy script across all ASG instances in parallel?
    - Filesystem/DB needs to move to EFS or similar instead of EBS.
- **Design catch:** SQLite on EFS (NFS) isn't safe; file locking over NFS can corrupt the database, and SQLite's docs warn against it. Two realistic paths:
  - **ASG of 1 keeping SQLite:** the instance attaches the existing EBS data volume at boot (same AZ). Gets self-healing replacement without changing the database.
  - **More than one instance:** move to Postgres (RDS), and the live-message hub needs a shared channel between servers.
- **Decided:** an ASG of one that keeps SQLite on the reattached EBS volume. Revisit only if one server isn't enough.
- **Superseded (2026-10-23):** Nate wants at least two servers, across availability zones, with low cost, private networking, and one deploy path for laptop and CI. Proposal in [horizontal-scaling.md](../design/horizontal-scaling.md): RDS PostgreSQL (also carrying live events between servers via `LISTEN/NOTIFY`), pics in S3, an Auto Scaling group of two behind an internal ALB with CloudFront as the only public entry point, IPv6-only outbound (no NAT), and deploys by instance refresh from `scripts/release.sh`. About $40 a month (about $54 with a Multi-AZ database) against $7.50 today; a group-of-one with Litestream (about $8) is the cheaper alternative. **Waiting on Nate's review**; nothing built.
