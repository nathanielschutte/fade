# Security

How napsack protects its people and itself: what's in place, the limits that keep one small server standing, what we don't protect against yet, and how the owner responds when something looks wrong.

napsack is one small server (an AWS t4g.nano: 2 vCPUs, 0.5 GB of memory, a 5 GB data disk) for a few dozen friends. Security here means three things:

1. **Nobody reads what they shouldn't.** Messages, keys, and anything sensitive stay private, even from us.
2. **Nobody gets in who shouldn't.** Accounts, sessions, and the admin panel are protected.
3. **Nobody knocks it over.** Floods, scripts, and scanners can't exhaust the server, its disk, or its database.

The rules for writing code that keeps all this true are in [CLAUDE.md](../CLAUDE.md) (Security); this doc is the overview. How the encryption works is in [how-napsack-works.md](how-napsack-works.md).

## What's protected, and how

### Your messages
- **Direct texts, pics, captions, and reactions are end-to-end encrypted** in the sender's app and decrypted in the recipient's. The server stores ciphertext and can't read it. Neither could anyone who stole the database.
- **Passwords never reach the server.** The app turns the password into a sign-in key and a separate key that unlocks your messages; the server only ever sees the first, and stores only a slow hash (Argon2) of it. Each check takes about 19 MiB for its moment, so only a few run at once (one per CPU, two to four; two in production), and a burst waits its turn or hears "busy" rather than running the server out of memory.
- **Neither does a passkey's secret.** Signing in with a passkey (F26) also has to unlock your private key, so each passkey keeps a copy of it, wrapped by a secret only that passkey can produce (WebAuthn's PRF extension). The server stores the passkey's public key (to check its signatures), its id, a signature count, where it's kept ("iCloud Keychain", from its authenticator's well-known id) and when it was added and last used, and the wrapped copy, which it can't open. A passkey that can't produce the secret isn't used at all ([passkeys.md](design/passkeys.md)).
- **Safety codes** let two friends check nobody is in the middle. A changed key blocks sending until you've decided, and old keys stay on your device so history stays readable.
- **Reports never carry content.** Reporting a message sends the server its id, kind, and time, which it already has, never what it said ([report-and-block.md](design/report-and-block.md)). You can only report what you were shown, and anything else gets the same answer whether it exists or not. A report's note is the reporter's own words, for Admins.
- **Not end-to-end encrypted yet:** group chats, profile names and pictures. The server can read those (they're friends-only, enforced by the server). The app says so in every group.

### Accounts and sign-in
- Sign-in attempts are limited per address and per username (a wrong password 10 times locks that username for 15 minutes, for everyone, without revealing whether it exists). An attempt counts when it starts, so ten sent at once lock it too; the right password gives its attempt back. A username that can't exist (3 to 20 letters, numbers, dots, and underscores) is turned away before it's counted, logged, or looked up.
- Sign-up needs the invite code or a friend's add-a-friend link, and stops entirely once there are **100 accounts**. Each person has one link, which doesn't change or expire (X39); it's stored only as a hash, and lookups are rate-limited like sign-in.
- Each person can be signed in on **10 devices**; an eleventh sign-in quietly signs out the one used least recently (a session whose browser forgot it is never used again, so it goes first). A session lasts a year and renews while it's used.
- Changing your password, using your recovery key, or an admin reset signs out every other device, and their live connections close at once.
- Deleting an account takes the password (wrong tries count toward the sign-in lock above) and the username typed again, and only ever deletes your own; nobody else, Admins included, can delete an account. A deleted account's username is held for 30 days (as a keyed hash), so nobody can sign up as it and pose as the person ([account-deletion.md](design/account-deletion.md)). Admins can't delete their own account at all (`403`), so an Admin's username is never freed and nobody can ever pose as one.
- **Passkeys** sign in without the password. Adding one needs the password (wrong tries count toward the sign-in lock above), so a stolen session can't plant a way in. The server checks every passkey itself (`webauthn.rs`): ES256 signatures only, the person verified by Face ID, a fingerprint, or a PIN, its own site and origin (staging's passkeys are staging's), each challenge answered once within 5 minutes, and a signature count that only goes up. Removing one marks it ended, at once; an admin's reset code ends all of an account's passkeys (their copies are of the old key); a turned-off account can't sign in with one either.
- Session tokens are stored only as hashes. Admin pages answer "not found" to anyone who isn't an admin.
- **Admins can't act on Admins.** No Admin can issue a reset code for an Admin's account (a reset code is a way in, handed to whoever asks for it), their own included, or turn one off or sign it out everywhere; to do any of that, take them off the admin list first. So one Admin's session, stolen, can't take over another Admin. A name on the admin list that nobody has yet can't be signed up as or renamed into (only the server's own machine and staging's test machines make Admins that way, for tests). The list should name Admins as `id:N`, which nobody can take; the server warns at start and on each reload about every entry that's a username.
- **Blocking** someone ends the friendship, and from then on their friend requests, your add-a-friend link, and adding you to a group answer them exactly as for someone who isn't there, so a block can't be detected. Admins can suspend an account (1, 7, or 30 days) or turn it off over a report; the person is told why at sign-in (only after the right password) and by Team Napsack, and never who reported them.

### Everything people type or upload
- Every value goes into the database as a bound parameter, never pasted into SQL; a test fails the build otherwise.
- Text the server shows others is checked for invisible and direction-changing characters; the apps only ever display text as text, never as HTML.
- Every image the server can see is decoded with memory-safe decoders (with size limits, so "image bombs" don't work) and re-encoded from scratch, so nothing hidden survives.
- Every request has a size limit.

### Bots and scanners
- `robots.txt` asks every crawler to stay away, and every response says `noindex`, so napsack never shows up in search.
- Known scanning tools (sqlmap, Nuclei, masscan, and the like) are refused outright.
- An address that probes for things napsack doesn't have (`/.env`, `/wp-login.php`, `/.git`, `.php` pages, ...) is **banned for an hour** after three probes, or after 30 missing pages in 10 minutes. Real people never do either.
- Push notifications only ever go to the browser companies' push services, and iPhone notifications to Apple's two push servers (`apns.rs`, fixed in the code; a request only says which); the server won't call any other address, whatever a request says.
- **Links in texts don't leave the app.** A link in a message is tappable only when it's to napsack's own site with an exact in-app route (`#chat=`, `#group=`, optionally `&message=`), and it opens that chat inside the app; every other link, and anything that only looks like one, stays plain text (`test_block_report.py`, `ChatLinkTests`).
- The only other calls the server makes are to AWS, for the admin Metrics tab (`aws.rs`): the instance metadata service, CloudWatch, and Cost Explorer, at addresses fixed in the code. Its permissions there are read-only (CPU credit numbers, the bill), and the instance credentials it uses are never logged. It also sends one email per new report through SES (`reports.rs`), from `noreply@` its own domain to the one address in its settings, which is all its permission allows; the email says who reported whom and links to System › Reports, never the reason, the note, or any content.

### The server itself
- The only open ports are 80 and 443. There's no SSH port: admin access goes through AWS Systems Manager.
- Caddy terminates HTTPS (with HSTS) and caps request bodies; the app sends strict security headers on every response.
- The app runs as its own user with a read-only system, no new privileges, a 400 MB memory ceiling, and no swap (so nothing in memory reaches disk).
- Secrets (the invite code, admin list) live in AWS Parameter Store and are loaded into memory at start, never written to disk.
- Backups run every hour to S3, kept 30 days. The server can add backups but not read, list, or delete them. It can write over one whose name it knows (adding to S3 allows that); the bucket's versioning keeps the version written over, but only for a day, so a compromised server could spoil backups if nobody noticed within a day. Disk snapshots, kept 30 days, are made by AWS's own schedule, which the server can't touch. See [backups.md](operations/backups.md).

## Limits

All far above normal use. Hitting one usually means a script, not a person. The "setting" ones can be changed without a code change (see [Changing a limit](#changing-a-limit)).

| What | Limit | Setting |
|---|---|---|
| Accounts in total | 100 | `FADE_MAX_ACCOUNTS` |
| Signed-in devices per person | 10 (a new one ends the one used least recently) | `FADE_MAX_SESSIONS` |
| Requests per address | 3,000 per 10 minutes | `FADE_REQUESTS_PER_ADDRESS` |
| Requests being handled at once | 200 (more get "busy, try again") | `FADE_MAX_IN_FLIGHT` |
| Live connections, whole server | 500 | `FADE_MAX_SOCKETS` |
| Live connections per person | 10 (a new one closes the oldest) | |
| Writes (sending, reacting, ...) | 600 per 10 minutes, per address and per session | |
| Sign-in and sign-up attempts | 30 per address per 10 minutes (signing in with a passkey too: asking for its challenge and answering it each count; and unlocking your key with the password, as the app does before changing it) | |
| Password checks (Argon2) at once, whole server | one per CPU, 2 to 4 (2 in production, 38 MiB at most); a check waits up to 5 seconds for its turn, then "busy, try again" | `auth.rs` `ARGON2_AT_ONCE` |
| Passkeys | 10 per person | |
| Passkey challenges waiting, whole server | 10,000 (each answered once, within 5 minutes; past that, "busy, try again") | |
| Wrong passwords | 10 per username per 15 minutes, counted as each attempt starts | |
| Keys one in-memory limit tracks (addresses, usernames, sessions) | 10,000; past that, ended windows go first, then the oldest; a key over 128 bytes is kept as its hash | `ratelimit.rs` `MAX_KEYS` |
| Image uploads | 60 per person per 10 minutes, decoded one at a time | |
| Friend requests | 50 per person per day | |
| Reports | 20 per person per day (counted in the database, so a restart doesn't reset it); a note, and an Admin's words, up to 500 characters, one line | `guard.rs` `MAX_REPORTS_PER_DAY`, `MAX_REPORT_WORDS` |
| Blocks | 500 people blocked at once; 100 blocks made per day (each adds a row, Rule 1) | `guard.rs` `MAX_BLOCKS`, `MAX_BLOCKS_PER_DAY` |
| New groups | 20 per person per day; 32 people per group | |
| Favorites | 10 per person (direct chats and groups together) | Turning one on or off adds a row (Rule 1); writes are capped by the write budgets |
| Edits | 20 per text, within 15 minutes of sending | Every version is kept (Rule 1) |
| Username changes | once a week (Admins exempt) | Old names are reserved for their owner forever |
| Size of one pic, one video | 512 KB, 6 MB (videos run 10 seconds at most) | `FADE_SNAP_MAX_KB`, `FADE_VIDEO_MAX_KB`, `FADE_VIDEO_MAX_SECONDS` |
| Unopened pics and videos on disk | 2 GB direct, 1.5 GB group (production; 256 MB and 200 MB by default) | `FADE_SNAP_DISK_MB`, `FADE_GROUP_PIC_DISK_MB` |
| Uploads stop when the data disk has less than | 150 MB free | |
| All writes stop when the data disk has less than | 40 MB free (so the database can't fill the disk) | |
| Client diagnostics | 300 entries per person per minute signed in, 60 per address signed out; a message 500 bytes, a field 300 | `logs.rs` |
| The log viewer's memory | the server's own entries: 20,000 and 32 MB; the apps': their own 4 MB, so they can never push the server's out; any value over 1 KB is cut | `logs.rs` `SERVER_BYTES`, `CLIENT_BYTES` |
| One live connection's traffic | 60 frames from the client per 10 seconds; 256 events waiting to go to it; a send that takes over 20 seconds. Past any of these the connection closes, and the app reconnects | `ws.rs` `MAX_FRAMES`, `QUEUE` |
| Badge updates to iPhones (`apns.rs`) | one per person per second at most, and only when the number changed, to that person's own iPhones | |

Per-address limits don't apply to the server's own machine (development and tests), or on staging to the test machines listed in `FADE_EXEMPT_ADDRESSES` (never set in production). In-memory limits and bans reset when the server restarts.

## What we don't protect against (yet)

Being honest about the gaps:

- **A large network flood (DDoS).** Everything above works inside the app. A flood big enough to saturate the instance's network, or Caddy's TLS handshakes, would still take napsack offline until it stops. The fix is a CDN/WAF in front (AWS CloudFront with WAF, or Cloudflare); it costs money and moves TLS to the provider, so it's a decision for when napsack is a bigger target.
- **Many addresses at once.** Per-address limits slow one attacker; a botnet with thousands of addresses could still make noise. The account cap, the per-session limits, and the in-flight ceiling are what keep that from becoming damage.
- **The server is a single machine.** If it dies, napsack is down until it's replaced (the data volume and backups survive). Planned: an Auto Scaling group of one ([plan.md](management/plan.md)).
- **The web app is delivered by the server.** A compromised server could ship code that leaks keys as you type; every browser-based encrypted app shares this. The iOS app, signed and reviewed before install, closes it.
- **Metadata.** The server sees who talks to whom and when; it needs to, to deliver messages.

## When something looks wrong

The owner has a private runbook for incidents, with the commands. In outline:

1. **Look.** The admin panel's *Protection* line shows accounts used, banned addresses, and requests refused since start. `/admin#logs` holds recent events (search `ip=...` to see what one address did); older history, and every problem an app reported, is in the server's journal.
2. **Stop new accounts** by lowering `FADE_MAX_ACCOUNTS` to the current count, or changing the invite code (a settings change, below).
3. **Shut out an address** that gets past the automatic bans, at the network, in front of the server (instant, no restart).
4. **Someone's account was taken over.** An Admin issues them a reset code: it ends every session and gives them a new key.
5. **The server itself is compromised.** It's taken out of service, the data volume is snapshotted, and it's rebuilt from a known release; backups older than the compromise can't have been read or deleted, and any written over in the last day still have their earlier version in the bucket (it keeps them a day), as do the disk snapshots ([backups.md](operations/backups.md)).

## Changing a limit

The settings in the table are environment variables in production's settings parameter, which Terraform writes (`local.env_file` in `infra/main.tf`): changing one is the owner's, an apply that touches nothing else and a restart. The rest are constants in `server/src/` (`guard.rs`, `main.rs`), changed with a release.

Every limit has a test: `server/src/guard.rs` (unit tests) and `tests/smoke_test.py` (`check_guard`, `check_rate_limits`, `check_attempts` for attempts at once and usernames that can't exist, `check_passkeys` for passkeys per person, and `check_reports` for reports per day); blocks per person in `blocks::tests`; password checks at once in `auth::tests`; limiter keys in `ratelimit::tests`; the log viewer's budgets in `logs::tests`; a connection's frames and queue in `ws::tests`.
