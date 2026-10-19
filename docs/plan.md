
# Plan

Central task tracking doc for napsack. Divides into categories ("Epics"), and a Tracker at the top which is a table with tasks from the below Epics that are actively being worked on.

## Tracker

Work top to bottom. Each row links to its entry in the Epics below, which holds the details and design notes. When something finishes, mark it done here (and move it to Done once the table gets long); when a new idea comes up, add it to an Epic first and slot it into the Tracker by priority.

Status: **In progress** · **Up next** · **Planned** · **Needs decision** (blocked on a choice, noted in the epic) · **Done**

| # | Task | Epic | Status | Why it's here |
|---|---|---|---|---|
| 1 | [Move to napsack.getattr.com](#i1-move-to-napsackgetattrcom) | Infrastructure | Done | Live; fade.getattr.com redirects |
| 2 | [Development standard (CLAUDE.md)](#p1-development-standard) | Process | Done | Rules every change follows from now on |
| 3 | [Turn on CI/CD, first tagged release](#p2-turn-on-cicd) | Process | In progress | Everything after this ships through it |
| 4 | [Backups you can restore](#i2-backups-you-can-restore) | Infrastructure | Up next | Data must never be lost, and 7 days of snapshots isn't enough |
| 5 | [Chat pagination](#f3-chat-pagination) | Features | Planned | Texts live forever; clients only load the last 100 |
| 6 | [Rename "snap"](#x1-rename-snap) | Experience | Needs decision | Settle the word before the iOS app bakes it in |
| 7 | [Logging pass and admin log viewer](#d1-log-viewer) | Debug | Planned | We'll need it to debug the iOS app |
| 8 | [Client debug logs](#d2-client-debug-logs) | Debug | Planned | Same; depends on #7 |
| 9 | [Password reset and recovery](#f2-password-reset-and-recovery) | Features | Needs decision | Shapes the key design the iOS app must implement |
| 10 | [Account safety basics](#f8-account-safety-basics) | Features | Planned | Sign-in rate limits and device list before more people join |
| 11 | [iOS app](#f1-ios-app) | Features | Planned | The big one; starts with the crypto spike |
| 12 | [Profile page](#f4-profile-page) | Features | Planned | |
| 13 | [Profile pic and nicknames](#f5-profile-pic-and-nicknames) | Features | Needs decision | |
| 14 | [Captions on pictures](#f6-captions-on-pictures) | Features | Planned | Needs message format 2 |
| 15 | [Move compute to an Auto Scaling group](#i3-auto-scaling-group) | Infrastructure | Needs decision | SQLite can't go on EFS; see notes |
| 16 | [Group chats](#f7-group-chats) | Features | Planned | Biggest encryption change; last |

**Why this order.** Process and data safety come first because everything else builds on them. Pagination, the "snap" rename, logging, and the recovery design come before the iOS app because each one changes something the app would otherwise have to build twice: the history API, the vocabulary, the debugging tools, and the key handling.

## Epics

### Process

#### P1. Development standard
- [CLAUDE.md](../CLAUDE.md): data durability rules, how every change is tested and shipped, prod verification. Grows as we go.

#### P2. Turn on CI/CD
- [x] Commit the admin panel, versioning, tests, and docs (`6f0519f`).
- [ ] Commit this round: CLAUDE.md, plan, unit tests, crypto vectors, domain redirect, SSH keys, CI fixes.
- [x] Apply the GitHub deploy role (`infra/github.tf`). Done with the domain apply.
- [ ] Set the repo variables (`terraform output github_actions_variables`), create the `production` environment, protect `main` ([RELEASING.md](RELEASING.md#one-time-setup)).
- [ ] Get CI green. The first run (`6f0519f`) failed with exit 126: scripts weren't executable in git. Fixed (mode bits, `bash scripts/test.sh`); confirm on the next push.
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
- **Decision needed:** confirm that trade-off, and whether to collect emails.

#### F3. Chat pagination
- Text chat pagination. We DO want texts to live forever. Make sure the clients use pagination for when chat history grows extensively.
- The server already pages (`?before=&limit=`). The web client loads the newest 100 and never asks for more. Add load-on-scroll-up, and keep the chat list query fast as tables grow (check indexes).

#### F4. Profile page
- User profile page.  View your list of friends and some stats that belong to you. Friends can view each other's profiles.

#### F5. Profile pic and nicknames
- Profile pic. Nicknames settable by own user.
- **Decision needed:** should profile pictures be end-to-end encrypted (only friends can see them, more work) or visible to the server like usernames are?

#### F6. Captions on pictures
- Write text caption on a picture before you send it.
- The encrypted picture is just JPEG bytes today, so a caption needs a new message format (an envelope holding picture + caption). That follows the readers-before-writers order in [RELEASING.md](RELEASING.md#compatibility-rules). If the iOS app can already read format 2 when it launches, this gets simpler.

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

#### D2. Client debug logs
- Client side debug logs. Browser/iOS client debug logs should be viewable in the admin log viewer as well (see above)
- Same rule: nothing decrypted leaves the device, so clients log events and errors, never text or pictures.

### Experience/visual

#### X1. Rename "snap"
- Remove the word 'snap', let's refer to pictures as something else
- **Decision needed:** the new word. A few to react to: *pic*, *flash*, *glimpse*, *peek*. The UI changes first. The API, database, and code can keep `snap` internally, the same way `fade` stays the internal name.

### Infrastructure

#### I1. Move to napsack.getattr.com
- Done: napsack.getattr.com is live, and fade.getattr.com redirects to it (`redirect_domains`). Data verified intact across the instance replacement (snapshot `snap-09aa617c083942ca9` taken first).
- Serve napsack.getattr.com and redirect fade.getattr.com to it, so old links keep working.
- Browsers keep keys per site, so everyone signs in once on the new address. Their history comes back from their password.
- The domain will change again; nothing should hardcode it (use `terraform output url`).

#### I2. Backups you can restore
- DB backup system. We're moving this ahead of the ASG work: data must never be lost, and today's only backups are daily disk snapshots kept for 7 days.
- Add a daily consistent SQLite backup (`.backup` or `VACUUM INTO`) to a versioned S3 bucket that never deletes, longer snapshot retention, and a restore drill we actually run and write down.

#### I3. Auto Scaling group
- Migrate compute to an EC2 ASG, set desired size to 1 for now
    - Eventually enable auto scaling rules, for now keep static
    - Will need to rethink deployment. Bake a new AMI and swap it out? Run deploy script across all ASG instances in parallel?
    - Filesystem/DB needs to move to EFS or similar instead of EBS.
- **Design catch:** SQLite on EFS (NFS) isn't safe; file locking over NFS can corrupt the database, and SQLite's docs warn against it. Two realistic paths:
  - **ASG of 1 keeping SQLite:** the instance attaches the existing EBS data volume at boot (same AZ). Gets self-healing replacement without changing the database.
  - **More than one instance:** move to Postgres (RDS), and the live-message hub needs a shared channel between servers.
- **Decision needed:** whether we really need more than one server. If not, the first path is much simpler.
