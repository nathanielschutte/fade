
# Plan

Central task tracking doc for napsack. Divides into categories ("Epics"), and a Tracker at the top which is a table with tasks from the below Epics that are actively being worked on.

## Tracker

Work top to bottom. Each row links to its entry in the Epics below, which holds the details and design notes. When something finishes, mark it done here (and move it to Done once the table gets long); when a new idea comes up, add it to an Epic first and slot it into the Tracker by priority.

Status: **In progress** · **Up next** · **Planned** · **Needs decision** (blocked on a choice, noted in the epic) · **Done**

| # | Task | Epic | Status | Why it's here |
|---|---|---|---|---|
| 1 | [Draw on pics](#f13-draw-on-pics) | Features | Planned | Fun, browser only, no server or format change |
| 2 | [Streaks](#f15-streaks) | Features | Planned | Snapchat's stickiest feature, from metadata the server already has |
| 3 | [Voice notes](#f16-voice-notes) | Features | Planned | End-to-end encrypted audio; a new message kind |
| 4 | [Chat list tools: pin, mute, search](#x3-chat-list-tools-pin-mute-search) | Experience | Planned | Gets useful as the friend list grows |
| 5 | [Group chats: "seen by", then end-to-end encryption](#f17-group-chats-seen-by-then-end-to-end) | Features | Planned | Groups are the one unencrypted part; design first |
| 6 | [Disappearing texts](#f18-disappearing-texts) | Features | Needs decision | Conflicts with "data is never deleted"; see notes |
| 7 | [iOS app](#f1-ios-app) | Features | In progress | Crypto spike built; waiting on Apple to put it on a phone |
| 8 | [Finish the release pipeline](#p2-turn-on-cicd) | Process | Planned | Releases use `scripts/deploy.sh` until then |
| 9 | [Auto Scaling group of one](#i3-auto-scaling-group) | Infrastructure | Planned | Keeps SQLite on its EBS volume |
| 10 | [Move the repo into WSL](#p3-testing-in-wsl) | Process | Needs decision | Faster builds and no Windows/Linux file issues; see notes |

**Done**

| Task | Shipped |
|---|---|
| [Logging pass and admin log viewer](#d1-log-viewer) | 0.2.0 |
| [Rename "snap" to "pic"](#x1-rename-snap) | 0.3.0 |
| [Profile page](#f4-profile-page) | 0.4.0 |
| [Chat pagination](#f3-chat-pagination) | 0.5.0 |
| [Client debug logs](#d2-client-debug-logs) | 0.6.0 |
| [Backups you can restore](#i2-backups-you-can-restore): hourly to S3, kept forever, drill passed | infra |
| Backup status in the admin panel (part of [backups](#i2-backups-you-can-restore)) | 0.7.0 |
| [Mark inactive instead of deleting](#p4-mark-inactive-instead-of-deleting) | 0.8.0 |
| [Request auditing and security hardening](#s1-request-auditing-and-security-hardening) | 0.9.0, 0.9.1 |
| [Group chats](#f7-group-chats) (texts; not end-to-end encrypted yet) | 0.10.0 |
| [Account bar on the main screen](#x2-account-buttons-on-the-main-screen), favicon | 0.11.0 |
| Pics and group pictures in group chats (not end-to-end encrypted yet; view-once, 30 days), shorter list previews, server resources in admin | 0.12.0 |
| Hostile-input hardening: images rebuilt server-side, SQL guard test, text validation, write and socket caps (see CLAUDE.md, Security) | 0.12.0 |
| [Profile pics and nicknames](#f5-profile-pic-and-nicknames): display names, private nicknames, profile pictures | 0.13.0 |
| [Pics last 30 days](#f9-pics-last-30-days): unopened pics wait on disk and survive restarts | 0.13.0 |
| [Captions on pictures](#f6-captions-on-pictures): message format 2 for direct pics; plain captions in groups | 0.13.0 |
| [Password reset and recovery](#f2-password-reset-and-recovery): recovery keys, change password, admin reset codes, accepting a friend's new key | 0.14.0 |
| [Account safety basics](#f8-account-safety-basics): sign out other devices (sign-in limits shipped in 0.9) | 0.14.0 |
| [Install as an app, with notifications](#f10-install-as-an-app-with-notifications) | 0.15.0 |
| [Reactions and replies](#f11-reactions-and-replies): text format 2, encrypted reactions | 0.15.0 |
| [Typing and "active now"](#f12-typing-and-active-now) | 0.15.0 |
| Abuse protection: account and device caps, request budgets, scanner refusal and probe bans, load shedding, disk floors ([SECURITY.md](SECURITY.md)); Home Screen app clears the iPhone status bar | 0.16.0 |
| [Invite links and QR codes](#f14-invite-links-and-qr-codes) | 0.17.0 |
| Move to napsack.getattr.com (old domain redirects) | infra |
| Development standard ([CLAUDE.md](../CLAUDE.md)), CI green on GitHub | process |

Production runs **0.17.0**. Releases ship with `scripts/deploy.sh`; commit what shipped afterwards.

**Why this order.** Process and data safety come first because everything else builds on them. Pagination, the "snap" rename, logging, and the recovery design come before the iOS app because each one changes something the app would otherwise have to build twice: the history API, the vocabulary, the debugging tools, and the key handling.

## Epics

### Process

#### P1. Development standard
- [CLAUDE.md](../CLAUDE.md): data durability rules, how every change is tested and shipped, prod verification. Grows as we go.

#### P3. Testing in WSL (and moving the repo there)
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
- [ ] Set the repo variables (`terraform output github_actions_variables`), create the `production` environment, protect `main` ([RELEASING.md](RELEASING.md#one-time-setup)).
- [x] Repo variables set. CI green on GitHub.
- [ ] Create the `production` environment, then ship a tagged release through the workflow. Until then, releases use `scripts/deploy.sh` with the version bumped in `server/Cargo.toml`.
- [x] Get CI green. The first run (`6f0519f`) failed with exit 126: scripts weren't executable in git. Fixed (mode bits, `bash scripts/test.sh`); confirm on the next push.
- [ ] Bump to 0.2.0 and ship `server-v0.2.0` through the release workflow. Production is running the same code today as build `6f0519f-dirty`.

### Features

#### F1. iOS app
- iOS app. This is the big one.
- Plan and milestones: [mobile.md](mobile.md). Push notifications are part of it.
- Needs: Apple Developer Program (requested 2026-10-19, pending), Expo account (done).
- Started (2026-10-19): crypto moved to `shared/crypto/` and checked in Node and Chromium; `mobile/` is an Expo SDK 58 app whose one screen runs every vector check on the phone. Next: `eas init`, register the iPhone, first development build, read the results. Status in [mobile.md](mobile.md#first-milestones).

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
- The encrypted picture is just JPEG bytes today, so a caption needs a new message format (an envelope holding picture + caption). That follows the readers-before-writers order in [RELEASING.md](RELEASING.md#compatibility-rules). If the iOS app can already read format 2 when it launches, this gets simpler.
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
- Tap-and-hold a message to react (a small fixed set: ❤️ 😂 😮 😢 👍 👎, like iMessage), or swipe/tap to reply to it with a quote.
- **Design:** both are end-to-end encrypted in direct chats. This introduces **text format 2**: the encrypted plaintext becomes a small JSON envelope (`{"t": "hi", "re": <message id>}`) instead of bare text, so future fields (replies, mentions, edits) don't each need a new format. Reactions are their own message kind (`reaction`), encrypted, pointing at the message they react to (the server sees which message got a reaction and when, not which emoji).
- Readers before writers ([RELEASING.md](RELEASING.md#compatibility-rules)): the web app ships both at once; the iOS app should read text format 2 from its first release. New pinned vectors (`tests/vectors/format2_text.json` or similar).
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

#### F14. Invite links and QR codes
- Today everyone signs up with one shared invite code from Terraform, then types usernames to add friends.
- **Invite links:** each person can make a link (`/i/<token>`) that signs a new person up and makes them friends with the inviter in one step. Limited uses and an expiry; the inviter sees who joined through it. Admins can still turn sign-ups off entirely. The shared code keeps working until it's retired.
- **QR codes:** your profile shows a QR code of a friend link; scanning it with a phone camera opens napsack with "Add Ana?" ready. Generated in the browser (a small QR encoder, written here rather than a third-party script, per the no-CDN rule).
- Tokens are random, stored hashed, marked used/revoked (never deleted), and rate-limited like sign-in.
- Done (0.17.0): one link does both (sign up with no code, or add if signed in); 10 uses, 7 days, turn off any time; the Friends sheet shows a QR code and who joined. The QR encoder is our own (`server/static/qr.js`), checked module for module against Python's `qrcode` and pixel by pixel on screen.

#### F15. Streaks
- A 🔥 and a count next to a friend when you've both sent each other a pic every day for 3+ days, and an ⌛ when today's streak is about to run out. Snapchat's stickiest feature.
- Computed on the server from message metadata it already has (who sent a pic to whom, and when), in each person's own time zone (the client sends its offset). No content involved.
- Also: your longest streak on your profile, and on a friend's profile, your streak together.

#### F16. Voice notes
- Hold the mic button to record (up to 2 minutes), release to send. Plays in the chat with a waveform; can be replayed (not view-once).
- End-to-end encrypted in direct chats like pics: recorded with `MediaRecorder` (Opus/AAC), encrypted in the browser, stored as a file on the data volume (they're kept, like texts; Rule 1), a new message kind `voice` with its own format number and vectors. Group voice notes are plain for now, like group pics.
- Disk: about 15 KB per 10 seconds; a cap per user and a total cap, shown in the admin panel.

#### F17. Group chats: "seen by", then end-to-end
- **"Seen by":** under the latest group message, "Seen by Ana, Ben" (read positions are already stored per member).
- **End-to-end encryption for groups:** the one part of napsack the server can read. Design doc first: likely a group key per membership change, sent to each member encrypted with their pair key (sender keys), so adding or removing someone rotates the key. A new group message format; old plaintext messages stay as they are. Big, careful work; the iOS app needs the same design.

#### F18. Disappearing texts
- Per-chat setting: texts disappear 24 hours after they're read (like Snapchat's default).
- **Needs a decision:** this conflicts with Rule 1 ("data in our DB can never be deleted"). Options:
  1. **Hidden, not deleted:** the server keeps the ciphertext forever but stops serving it after the timer. Honest about it in the UI ("hidden from the chat; napsack keeps an encrypted copy"). The server still can't read it.
  2. **Real deletion for these only:** an explicit, narrow exception to Rule 1 for ciphertext the sender asked to disappear, like pic files today. Needs the user's sign-off on the rule change.
  3. **Skip it.**

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

#### X3. Chat list tools: pin, mute, search
- **Pin** up to 3 chats to the top; **mute** a chat (no notifications, no unread dot, for 8 hours / a week / always); **archive** quiet chats out of the list (they come back on a new message).
- **Search:** find a chat by name, and search message text. Direct messages are end-to-end encrypted, so search runs in the browser over decrypted history (loading older pages as needed); group messages can be searched on the server.
- Pin/mute/archive are stored per person on the server (append-only state, Rule 1) so they follow you to new devices.

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
- Done: infrastructure applied (2026-10-20), first backup taken, restore drill passed and logged in BACKUPS.md, and the server's role proven unable to delete or list backups.

#### I3. Auto Scaling group
- Migrate compute to an EC2 ASG, set desired size to 1 for now
    - Eventually enable auto scaling rules, for now keep static
    - Will need to rethink deployment. Bake a new AMI and swap it out? Run deploy script across all ASG instances in parallel?
    - Filesystem/DB needs to move to EFS or similar instead of EBS.
- **Design catch:** SQLite on EFS (NFS) isn't safe; file locking over NFS can corrupt the database, and SQLite's docs warn against it. Two realistic paths:
  - **ASG of 1 keeping SQLite:** the instance attaches the existing EBS data volume at boot (same AZ). Gets self-healing replacement without changing the database.
  - **More than one instance:** move to Postgres (RDS), and the live-message hub needs a shared channel between servers.
- **Decided:** an ASG of one that keeps SQLite on the reattached EBS volume. Revisit only if one server isn't enough.
