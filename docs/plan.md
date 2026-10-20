
# Plan

Central task tracking doc for napsack. Divides into categories ("Epics"), and a Tracker at the top which is a table with tasks from the below Epics that are actively being worked on.

## Tracker

Work top to bottom. Each row links to its entry in the Epics below, which holds the details and design notes. When something finishes, mark it done here (and move it to Done once the table gets long); when a new idea comes up, add it to an Epic first and slot it into the Tracker by priority.

Status: **In progress** · **Up next** · **Planned** · **Needs decision** (blocked on a choice, noted in the epic) · **Done**

| # | Task | Epic | Status | Why it's here |
|---|---|---|---|---|
| 1 | [Backups you can restore](#i2-backups-you-can-restore) | Infrastructure | In progress | Code ready and tested; the infrastructure apply is the last step |
| 2 | [Pics last 30 days](#f9-pics-last-30-days) | Features | Planned | Requested; unopened pics are lost on every restart today |
| 3 | [Account buttons on the main screen](#x2-account-buttons-on-the-main-screen) | Experience | Planned | Requested; profile, admin, and sign out are buried in the Friends sheet |
| 4 | [Password reset and recovery](#f2-password-reset-and-recovery) | Features | Planned | Shapes the key design the iOS app must implement |
| 5 | [Account safety basics](#f8-account-safety-basics) | Features | Planned | Sign-in rate limits and device list before more people join |
| 6 | [Profile pic and nicknames](#f5-profile-pic-and-nicknames) | Features | Planned | |
| 7 | [iOS app](#f1-ios-app) | Features | Planned | The big one; starts with the crypto spike |
| 8 | [Captions on pictures](#f6-captions-on-pictures) | Features | Planned | Needs message format 2 |
| 9 | [Finish the release pipeline](#p2-turn-on-cicd) | Process | Planned | Releases use `scripts/deploy.sh` until then |
| 10 | [Auto Scaling group of one](#i3-auto-scaling-group) | Infrastructure | Planned | Keeps SQLite on its EBS volume |
| 11 | [Group chats](#f7-group-chats) | Features | Planned | Biggest encryption change; last |
| 12 | [Testing in WSL](#p3-testing-in-wsl) | Process | Needs decision | Smart App Control blocks Windows builds; WSL needs three libraries |

**Done**

| Task | Shipped |
|---|---|
| [Logging pass and admin log viewer](#d1-log-viewer) | 0.2.0 |
| [Rename "snap" to "pic"](#x1-rename-snap) | 0.3.0 |
| [Profile page](#f4-profile-page) | 0.4.0 |
| [Chat pagination](#f3-chat-pagination) | 0.5.0 |
| [Client debug logs](#d2-client-debug-logs) | 0.6.0 |
| Backup status in the admin panel (part of [backups](#i2-backups-you-can-restore)) | 0.7.0 |
| Move to napsack.getattr.com (old domain redirects) | infra |
| Development standard ([CLAUDE.md](../CLAUDE.md)), CI green on GitHub | process |

Production runs **0.7.0**. Every release since 0.2.0 shipped with `scripts/deploy.sh` from uncommitted code (build `aa50af4-dirty`), so the next commit should cover all of it.

**Why this order.** Process and data safety come first because everything else builds on them. Pagination, the "snap" rename, logging, and the recovery design come before the iOS app because each one changes something the app would otherwise have to build twice: the history API, the vocabulary, the debugging tools, and the key handling.

## Epics

### Process

#### P1. Development standard
- [CLAUDE.md](../CLAUDE.md): data durability rules, how every change is tested and shipped, prod verification. Grows as we go.

#### P3. Testing in WSL
- Windows Smart App Control (on, enforcing) blocks every freshly compiled program, so `cargo build`/`cargo test` and the local server only run in WSL. Unit and API tests already run there (`bash scripts/test.sh --no-browser`).
- The browser tests need three system libraries in WSL: `sudo apt-get install -y libnspr4 libnss3 libasound2t64`. Until then they run from Windows against a WSL-built server (CLAUDE.md, Environment notes).
- **Decision needed:** install those libraries (recommended), or turn off Smart App Control, which Windows can't turn back on without a reinstall.

#### P2. Turn on CI/CD
- [x] Commit the admin panel, versioning, tests, and docs (`6f0519f`).
- [ ] Commit this round: CLAUDE.md, plan, unit tests, crypto vectors, domain redirect, SSH keys, CI fixes.
- [x] Apply the GitHub deploy role (`infra/github.tf`). Done with the domain apply.
- [ ] Set the repo variables (`terraform output github_actions_variables`), create the `production` environment, protect `main` ([RELEASING.md](RELEASING.md#one-time-setup)).
- [x] Repo variables set. CI green on GitHub.
- [ ] Create the `production` environment, then ship a tagged release through the workflow. Until then, releases use `scripts/deploy.sh` with the version bumped in `server/Cargo.toml`.
- [x] Get CI green. The first run (`6f0519f`) failed with exit 126: scripts weren't executable in git. Fixed (mode bits, `bash scripts/test.sh`); confirm on the next push.
- [ ] Bump to 0.2.0 and ship `server-v0.2.0` through the release workflow. Production is running the same code today as build `6f0519f-dirty`.

### Features

#### F1. iOS app
- iOS app. This is the big one.
- Plan and milestones: [mobile.md](mobile.md). Push notifications are part of it.
- Needs: Apple Developer Program, Expo account.

#### F2. Password reset and recovery
- Password reset flow - email?  Admin recovery key for support.
- **Design catch:** the password is also the key to message history. A reset (by email or by an admin) can give someone their account back, but their old messages become unreadable, because nobody else holds the key. An admin recovery key that *could* restore history would mean the admin can read everyone's messages, which ends end-to-end encryption.
- **Recommendation:** a personal recovery key shown once at sign-up (saved by the user) restores everything. An admin-assisted reset restores access to the account and friends, with history lost. Email is optional; we don't collect emails today.
- **Decided:** a recovery key held by the user (restores everything) plus admin-assisted reset (restores the account, history is lost). No admin key that can read history. Email collection is still open; only needed for self-serve resets.

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

#### F6. Captions on pictures
- Write text caption on a picture before you send it.
- The encrypted picture is just JPEG bytes today, so a caption needs a new message format (an envelope holding picture + caption). That follows the readers-before-writers order in [RELEASING.md](RELEASING.md#compatibility-rules). If the iOS app can already read format 2 when it launches, this gets simpler.

#### F9. Pics last 30 days
- Requested: unopened pics shouldn't expire for a while, around 30 days.
- **Why it isn't a setting change:** unopened pics live only in server memory, so every restart (each deploy) loses them, and the memory pool is 128 MB.
- **Proposal:** keep each unopened pic's ciphertext in a file on the data volume until it's opened or 30 days pass. It's end-to-end encrypted, so the server still can't see it. View-once stays: the file is removed when opened or expired, which is the feature, not a data loss. Restarts no longer lose pics, and the server expires them by age from the database. A disk cap of about 256 MB (~1,500 pending pics) fits the 1 GB volume; growing the volume later is a safe, in-place change.
- **Trade-off to accept:** a pic's ciphertext now sits on disk while it waits, and can linger in the daily disk snapshots for up to 30 days after it's opened. Still unreadable without the recipient's keys, but no longer "only ever in RAM". The docs and the "never written to disk" wording change accordingly.

#### F7. Group chats
- Group chats (encryption design implication)
- Every pair of friends shares a key today. Groups need either per-member encryption (simple, fine for small groups) or a group key handed out to members (scales better, harder when someone leaves). Design doc first.

#### F8. Account safety basics
- Rate-limit sign-in attempts per username and per IP.
- List signed-in devices with "sign out everywhere".

### Debug

#### D1. Log viewer
- Log viewer (also for admins only). Central view of server logs with search features. Along with this, take a pass at the server code and improve logging. Debug logging can be verbose.
- Logs never include message content (the server doesn't have it), keys, tokens, or invite codes.
- Done (0.2.0): structured logging across auth, friends, texts, pics, sockets, and every request; viewer at `/admin#logs` with search, level filter, live tail, and paging. Entries live in memory (last 20,000 since the server started), so a restart clears them; the journal keeps older history.
- Possible follow-up: persist logs across restarts, in a separate log store with rotation (never in the user database).

#### D2. Client debug logs
- Client side debug logs. Browser/iOS client debug logs should be viewable in the admin log viewer as well (see above)
- Same rule: nothing decrypted leaves the device, so clients log events and errors, never text or pictures.
- Done (0.6.0): `POST /api/logs` (signed in or not, 50 entries per request, 300 per user per minute, fields bounded and content-looking names redacted). The web app reports uncaught errors, failed loads and sends, decryption failures, key changes, socket connects, pic compression, and sign-in results. The viewer's Source filter splits server from apps.

### Experience/visual

#### X1. Rename "snap"
- Remove the word 'snap', let's refer to pictures as something else
- **Decided:** *pic*. The UI changes; the API, database, and code keep `snap` internally, the same way `fade` stays the internal name.

#### X2. Account buttons on the main screen
- Requested: move profile and the other account buttons (admin, sign out) out of the Friends sheet to a better spot on the main screen.
- Proposal: an account bar at the bottom of the chat list, with your avatar and name (opens your profile), an Admin link for admins, and Sign out. It's visible on phones too, since the chat list is the home screen there. The Friends sheet goes back to just friends and requests.

### Infrastructure

#### I1. Move to napsack.getattr.com
- Done: napsack.getattr.com is live, and fade.getattr.com redirects to it (`redirect_domains`). Data verified intact across the instance replacement (snapshot `snap-09aa617c083942ca9` taken first).
- Serve napsack.getattr.com and redirect fade.getattr.com to it, so old links keep working.
- Browsers keep keys per site, so everyone signs in once on the new address. Their history comes back from their password.
- The domain will change again; nothing should hardcode it (use `terraform output url`).

#### I2. Backups you can restore
- DB backup system. We're moving this ahead of the ASG work: data must never be lost, and today's only backups are daily disk snapshots kept for 7 days.
- Add a daily consistent SQLite backup (`.backup` or `VACUUM INTO`) to a versioned S3 bucket that never deletes, longer snapshot retention, and a restore drill we actually run and write down.
- Built (see [BACKUPS.md](BACKUPS.md)): hourly backups via a systemd timer, integrity-checked and gzipped, to a new versioned bucket with `prevent_destroy` and no expiry (cheaper storage after 30 days); the server can only add objects. Disk snapshots go from 7 to 30 days. The admin panel shows the last backup (live in 0.7.0; it says "None yet" until the timer runs). `scripts/restore-drill.sh` checks the newest backup against production, read-only. The backup script passed a dry run against a test database: the uploaded copy restored with identical row counts, and a failure was recorded in the status file.
- **Left to do:** apply the infrastructure (new bucket, IAM, DLM retention, and the boot script change, which replaces the instance, with the snapshot procedure), start the first backup, run the restore drill, and log it in BACKUPS.md.

#### I3. Auto Scaling group
- Migrate compute to an EC2 ASG, set desired size to 1 for now
    - Eventually enable auto scaling rules, for now keep static
    - Will need to rethink deployment. Bake a new AMI and swap it out? Run deploy script across all ASG instances in parallel?
    - Filesystem/DB needs to move to EFS or similar instead of EBS.
- **Design catch:** SQLite on EFS (NFS) isn't safe; file locking over NFS can corrupt the database, and SQLite's docs warn against it. Two realistic paths:
  - **ASG of 1 keeping SQLite:** the instance attaches the existing EBS data volume at boot (same AZ). Gets self-healing replacement without changing the database.
  - **More than one instance:** move to Postgres (RDS), and the live-message hub needs a shared channel between servers.
- **Decided:** an ASG of one that keeps SQLite on the reattached EBS volume. Revisit only if one server isn't enough.
