
# Plan

Central task tracking doc for napsack. Divides into categories ("Epics"), and a Tracker at the top which is a table with tasks from the below Epics that are actively being worked on.

## Tracker

Work top to bottom. Each row links to its entry in the Epics below, which holds the details and design notes. When something finishes, mark it done here (and move it to Done once the table gets long); when a new idea comes up, add it to an Epic first and slot it into the Tracker by priority.

Status: **In progress** · **Up next** · **Planned** · **Needs decision** (blocked on a choice, noted in the epic) · **Done**

| # | Task | Epic | Status | Why it's here |
|---|---|---|---|---|
| 0 | [Friend map](#x15-friend-map) | Features | In progress | Nate asked for it (2026-10-23); design in friend-graph.md |
| 1 | [iOS app](#f1-ios-app) | Features | In progress | Apple Developer Program approved; first build, then TestFlight for early users |
| 2 | [Voice notes](#f16-voice-notes) | Features | Planned | End-to-end encrypted audio; a new message kind |
| 3 | [Group chats: encrypt reactions; refuse plain text](group-encryption.md#built) | Features | Planned | Phase 1 shipped in 0.21.0; these finish it |
| 4 | [Disappearing texts](#f18-disappearing-texts) | Features | Needs decision | Conflicts with "data is never deleted"; see notes |
| 5 | [Finish the release pipeline](#p2-turn-on-cicd) | Process | Planned | Releases use `scripts/deploy.sh` until then |
| 6 | [Scale out: two servers across zones](horizontal-scaling.md) | Infrastructure | Needs decision | Design and cost in horizontal-scaling.md; Nate reviews before anything is built |
| 7 | [Move the repo into WSL](#p3-testing-in-wsl) | Process | Needs decision | Faster builds and no Windows/Linux file issues; see notes |

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
| Push refusals log the push service's reason; an unchanged subscription no longer adds a row | 0.17.3 |
| [Pics back to back](#x4-open-pics-back-to-back), [message box grows to 4 lines](#x5-composer-grows-to-4-lines), [keyboard stays up after Send](#x6-keyboard-stays-up-after-send), [pull to refresh](#x7-pull-to-refresh-the-chat-list), [group "seen by"](#f17-group-chats-seen-by-then-end-to-end); admin tabs no longer jump between Overview and Logs | 0.18.0 |
| [Chat list header](#x8-chat-list-header-buttons): Friends and a + for starting things, together on the right | 0.18.1 |
| iPhone notifications from some friends were refused by Apple ("BadWebPushTopic"): push topics are now valid base64url, and keyed so the push service can't tell who sent them | 0.18.2 |
| [Favorites](stories/favorites.md) and [hiding chats](#x3-chat-list-tools-pin-mute-search): swipe (phone) or hover (computer) a chat for Favorite, Hide, or Leave | 0.19.0 |
| [Admin "Online now"](#d3-admin-online-now-count) counts whoever is looking at the admin page; [removing people from groups](#x9-removing-people-from-groups) says who can, and takes two taps; [birthdays](#f19-birthday-and-more-profile-fields) on profiles, with a 🎂 on the day | 0.20.0 |
| **[End-to-end encrypted group chats](group-encryption.md)** (format 3): messages and pics; the group's name and picture, and reactions, still visible to the server, and every group says so | 0.21.0 |
| [Draw on pics](#f13-draw-on-pics): a pen, stickers, and undo, flattened into the photo before it's encrypted | 0.22.0 |
| [Streaks](#f15-streaks): 🔥 and a count when you've both sent pics every day, ⌛ when it's about to end | 0.23.0 |
| [Mute and search](#x3-chat-list-tools-pin-mute-search): mute a chat for 8 hours, a week, or always; search chats by name and messages by text (in the browser) | 0.24.0 |
| [Befriend people from a group](#x10-befriend-people-from-a-group): Add friend / Requested / Accept in a group's member list | 0.24.1 |
| [Bad connections](#x11-bad-connections): pics count as opened only once shown; texts and pics resend safely; heartbeat and offline note | 0.25.0 |
| [Double tap a chat to send a pic](#x12-double-tap-a-chat-to-send-a-pic); [double tap the camera to switch it](#x13-double-tap-the-camera-to-switch-it) | 0.25.1 |
| [Phone double tap waits a beat](#x12-double-tap-a-chat-to-send-a-pic); [group badge in the list](#x14-tell-groups-from-direct-chats-in-the-list) | 0.25.2 |
| [Metrics tab](#i4-metrics-how-is-the-infrastructure-doing): machine and server readings, status, cost (see OPERATIONS.md) | 0.26.0 |
| Move to napsack.getattr.com (old domain redirects) | infra |
| Development standard ([CLAUDE.md](../CLAUDE.md)), CI green on GitHub | process |

Production runs **0.24.1**. Releases ship with `scripts/deploy.sh`; commit what shipped afterwards.

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
- Needs: Apple Developer Program (approved 2026-10-21), Expo account (done).
- Getting it to early users: TestFlight (internal testers first, then an external group by public link, which needs a short Beta App Review).
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
- Done (0.22.0): `server/static/draw.js`. After taking or choosing a pic: a pen (six colors, thin or thick), emoji stickers you drag, resize (+/−, the mouse wheel, or a pinch), and undo for all of it. The drawing is kept relative to the photo, then flattened into it and compressed again before it's encrypted, for direct and group pics alike. `tests/e2e/test_draw.py` reads the received photo's pixels.

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
- Done (0.23.0): `streaks.rs`. A day counts when both of you sent the other at least one direct pic that day, in the viewer's own time zone (`?tz=`). 🔥 and the count by a friend's name from 3 days; ⌛ when it stands through yesterday, today hasn't counted, and less than 6 hours are left. A friend's profile shows the streak and the longest; yours shows your longest with anyone. One query per list load, from when pics were sent (no content).

#### F16. Voice notes
- Hold the mic button to record (up to 2 minutes), release to send. Plays in the chat with a waveform; can be replayed (not view-once).
- End-to-end encrypted in direct chats like pics: recorded with `MediaRecorder` (Opus/AAC), encrypted in the browser, stored as a file on the data volume (they're kept, like texts; Rule 1), a new message kind `voice` with its own format number and vectors. Group voice notes are plain for now, like group pics.
- Disk: about 15 KB per 10 seconds; a cap per user and a total cap, shown in the admin panel.

#### F17. Group chats: "seen by", then end-to-end
- **"Seen by":** under the latest group message, "Seen by Ana, Ben" (read positions are already stored per member). Done (0.18.0): `GET /groups/{id}/reads` and a live `group_read` event; "Seen by everyone" once all of 3+ others have read it.
- **End-to-end encryption for groups:** the one part of napsack the server can read. Nate (2026-10-21): "a key point of interest... design it thoroughly and document the approach in the repo."
- **Decided (2026-10-21), Nate:** build Approach D from the design; existing groups switch automatically, no one asked; group names and pictures stay server-visible, but the app must say clearly that group pictures (and names) aren't encrypted; Phase 2 (authenticated member list) later, and never at the cost of easy invites (growing the app and keeping it approachable comes first while sign-up is invite-only); forward secrecy out of scope. Status: Phase 1 built and shipped (0.21.0): see [group-encryption.md, Built](group-encryption.md#built). Still to do: encrypt group reactions; refuse new plain-text group messages; Phase 2 later.
- **Design written (2026-10-21): [group-encryption.md](group-encryption.md).** Recommends a fresh key per message, wrapped for each member with the pair key they already share with the sender (rather than a shared group key): sender authenticity among members, no key rotation when someone leaves, only primitives we already use. Format 3, readers before writers, then Phase 2 (an authenticated member list). Five open decisions listed at the end of the doc; nothing gets built until Nate answers them.

#### F19. Birthday and more profile fields
- Requested (2026-10-21): "more profile field entries like a birthday (optional)."
- Friends-only like the rest of the profile (server-visible, not end-to-end encrypted). Birthday as month and day, with the year optional; friends see it on your profile, and maybe a small 🎂 on the day. Other candidates to offer: pronouns, a short "about" line. Stored append-only like display names (Rule 1), validated like other text (`text.rs`).
- Done (0.20.0): birthday on your profile (month and day; year optional, 1900 to now; real dates only, Feb 29 fine without a year), shown to friends on your profile, and a 🎂 by your name in friends' chat lists on the day (their own time zone). `user_birthdays` (migration 0013), append-only. **Still to offer:** pronouns, a short "about" line.

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
- **Favorites** first: [stories/favorites.md](stories/favorites.md). Taken over from Nate's story on 2026-10-21 and shipped with hiding (below), since both are marks on a chat row.
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
- Enter: on a computer, Enter sends and Shift+Enter starts a new line. On a phone, Return starts a new line and the Send button sends (like iMessage). Messages already keep their line breaks when shown.
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
- Design: [friend-graph.md](friend-graph.md). Server decides scope and privacy (`graph.rs`); clusters and layout in a shared, platform-neutral module (`shared/graph/graph.js`, usable by iOS later); an SVG renderer shared by both pages.

### Infrastructure

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

#### I5. Growing the single server
- Requested (2026-10-23): if napsack stays one server (today's stack), what runs out first and how do we grow it? Plan in [mono-scaling.md](mono-scaling.md), measured against production.
- In order: the 100-account cap (ours), memory (0.5 GB: the first real upgrade, nano → micro), hourly full backups growing with database size forever (move to Litestream incremental before ~50 MB), CPU credits (the server is in **standard** credit mode: throttled, not billed), the 1 GB data disk (grow online), admin-panel queries. Step 0 is a local load test to replace estimates with measurements. CloudFront in front of the one server is a free improvement (no Elastic IP, no Caddy).
- Nothing built; Nate decides when.

#### I4. Metrics: how is the infrastructure doing?
- Requested (2026-10-22): live machine stats (CPU, memory, disk; ready for more than one machine) and basic server process stats, kept for about 24 hours to a few days, accurate, visual enough to see whether we're in the red, with a cost estimate. No Prometheus/Grafana.
- Approved (2026-10-22): build it in; 3 days, configurable (`FADE_METRICS_RETENTION_HOURS`); CloudWatch and Cost Explorer are fine at cents a month. Nate turned on the `App` cost tag.
- Done (0.26.0), as proposed below; how to read it is in [OPERATIONS.md](OPERATIONS.md#metrics). Not yet: the `agent` mode for a second machine (the store and the tab already handle several hosts).
- **Proposal:** built into the server, no new services.
  - **Collect** every 10s, in the server, from `/proc` and `statvfs` (extends `sysinfo.rs`): machine CPU % (busy, iowait, *steal*), memory used/available and swap, disk used/free and IOPS for the root and data volumes, network in/out; process CPU %, memory (RSS), threads, open files; app request rate, p50/p95/p99 latency, 5xx, live sockets, DB and pic sizes.
  - **Keep** each minute as min/avg/max (so spikes aren't averaged away) in a separate `metrics.db` on the data volume, a fixed ring of 3 days × 1,440 slots per host, overwritten in place: bounded size, survives deploys, never touches user data. The last hour at 10s stays in memory for the live view. Every row carries `host` (the instance id).
  - **More machines later:** the same code runs as `fade-server agent` on a machine without the app and posts its samples to the main server (admin-authenticated). The view already groups by host.
  - **t4g is burstable,** so "in the red" for CPU means burning credits, not 100%: read `CPUCreditBalance` and `CPUSurplusCreditsCharged` from CloudWatch every 5 minutes (free basic metrics; GetMetricData costs cents a month; needs one IAM permission, an in-place change).
  - **See it** in the admin page, a new Metrics tab: a status tile per host (OK / Watch / Red against set thresholds: memory > 80%, disk > 80%, credits falling or surplus charged, steal > 10%, p95 > 500ms, 5xx), then line charts for 1h / 24h / 3d. Inline SVG, no libraries.
  - **Cost:** a live run-rate from a small price table (instance type per hour, gp3 per GB-month, public IPv4, surplus credits, S3 backup size), plus the real month-to-date from Cost Explorer once a day by `App=fade` (needs the tag activated in Billing). Shows the next instance size up and its price.
- Rejected: CloudWatch agent (custom metrics ~$0.30 each per month, about as much as the server itself, and the view lives in the AWS console); Prometheus/Grafana (too heavy for a t4g.nano).

#### I3. Auto Scaling group
- Migrate compute to an EC2 ASG, set desired size to 1 for now
    - Eventually enable auto scaling rules, for now keep static
    - Will need to rethink deployment. Bake a new AMI and swap it out? Run deploy script across all ASG instances in parallel?
    - Filesystem/DB needs to move to EFS or similar instead of EBS.
- **Design catch:** SQLite on EFS (NFS) isn't safe; file locking over NFS can corrupt the database, and SQLite's docs warn against it. Two realistic paths:
  - **ASG of 1 keeping SQLite:** the instance attaches the existing EBS data volume at boot (same AZ). Gets self-healing replacement without changing the database.
  - **More than one instance:** move to Postgres (RDS), and the live-message hub needs a shared channel between servers.
- **Decided:** an ASG of one that keeps SQLite on the reattached EBS volume. Revisit only if one server isn't enough.
- **Superseded (2026-10-23):** Nate wants at least two servers, across availability zones, with low cost, private networking, and one deploy path for laptop and CI. Proposal in [horizontal-scaling.md](horizontal-scaling.md): RDS PostgreSQL (also carrying live events between servers via `LISTEN/NOTIFY`), pics in S3, an Auto Scaling group of two behind an internal ALB with CloudFront as the only public entry point, IPv6-only outbound (no NAT), and deploys by instance refresh from `scripts/release.sh`. About $40 a month (about $54 with a Multi-AZ database) against $7.50 today; a group-of-one with Litestream (about $8) is the cheaper alternative. **Waiting on Nate's review**; nothing built.
