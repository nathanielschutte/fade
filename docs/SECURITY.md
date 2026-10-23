# Security

How napsack protects its people and itself: what's in place, the limits that keep one small server standing, what we don't protect against yet, and what to do when something looks wrong.

napsack is one small server (an AWS t4g.nano: 2 vCPUs, 0.5 GB of memory, a 1 GB data disk) for a few dozen friends. Security here means three things:

1. **Nobody reads what they shouldn't.** Messages, keys, and anything sensitive stay private, even from us.
2. **Nobody gets in who shouldn't.** Accounts, sessions, and the admin panel are protected.
3. **Nobody knocks it over.** Floods, scripts, and scanners can't exhaust the server, its disk, or its database.

The rules for writing code that keeps all this true are in [CLAUDE.md](../CLAUDE.md) (Security); this doc is the overview. How the encryption works is in [how-napsack-works.md](how-napsack-works.md).

## What's protected, and how

### Your messages
- **Direct texts, pics, captions, and reactions are end-to-end encrypted** in the sender's app and decrypted in the recipient's. The server stores ciphertext and can't read it. Neither could anyone who stole the database.
- **Passwords never reach the server.** The app turns the password into a sign-in key and a separate key that unlocks your messages; the server only ever sees the first, and stores only a slow hash (Argon2) of it.
- **Safety codes** let two friends check nobody is in the middle. A changed key blocks sending until you've decided, and old keys stay on your device so history stays readable.
- **Not end-to-end encrypted yet:** group chats, profile names and pictures. The server can read those (they're friends-only, enforced by the server). The app says so in every group.

### Accounts and sign-in
- Sign-in attempts are limited per address and per username (a wrong password 10 times locks that username for 15 minutes, for everyone, without revealing whether it exists).
- Sign-up needs the invite code or a friend's invite link, and stops entirely once there are **100 accounts**. Invite links work 10 times within 7 days, can be turned off, and are stored only as hashes.
- Each person can be signed in on **4 devices**; a fifth sign-in quietly signs out the oldest.
- Changing your password, using your recovery key, or an admin reset signs out every other device, and their live connections close at once.
- Session tokens are stored only as hashes. Admin pages answer "not found" to anyone who isn't an admin.

### Everything people type or upload
- Every value goes into the database as a bound parameter, never pasted into SQL; a test fails the build otherwise.
- Text the server shows others is checked for invisible and direction-changing characters; the apps only ever display text as text, never as HTML.
- Every image the server can see is decoded with memory-safe decoders (with size limits, so "image bombs" don't work) and re-encoded from scratch, so nothing hidden survives.
- Every request has a size limit.

### Bots and scanners
- `robots.txt` asks every crawler to stay away, and every response says `noindex`, so napsack never shows up in search.
- Known scanning tools (sqlmap, Nuclei, masscan, and the like) are refused outright.
- An address that probes for things napsack doesn't have (`/.env`, `/wp-login.php`, `/.git`, `.php` pages, ...) is **banned for an hour** after three probes, or after 30 missing pages in 10 minutes. Real people never do either.
- Push notifications only ever go to the browser companies' push services; the server won't call any other address, whatever a request says.
- The only other calls the server makes are to AWS, for the admin Metrics tab (`aws.rs`): the instance metadata service, CloudWatch, and Cost Explorer, at addresses fixed in the code. Its permissions there are read-only (CPU credit numbers, the bill), and the instance credentials it uses are never logged.

### The server itself
- The only open ports are 80 and 443. There's no SSH port: admin access goes through AWS Systems Manager.
- Caddy terminates HTTPS (with HSTS) and caps request bodies; the app sends strict security headers on every response.
- The app runs as its own user with a read-only system, no new privileges, a 400 MB memory ceiling, and no swap (so nothing in memory reaches disk).
- Secrets (the invite code, admin list) live in AWS Parameter Store and are loaded into memory at start, never written to disk.
- Backups run every hour to S3. The server can add backups but not read, change, or delete them, so even a fully compromised server can't destroy them. Disk snapshots are kept 30 days. See [BACKUPS.md](BACKUPS.md).

## Limits

All far above normal use. Hitting one usually means a script, not a person. The "setting" ones can be changed without a code change (see [Changing a limit](#changing-a-limit)).

| What | Limit | Setting |
|---|---|---|
| Accounts in total | 100 | `FADE_MAX_ACCOUNTS` |
| Signed-in devices per person | 4 (a new one ends the oldest) | `FADE_MAX_SESSIONS` |
| Requests per address | 3,000 per 10 minutes | `FADE_REQUESTS_PER_ADDRESS` |
| Requests being handled at once | 200 (more get "busy, try again") | `FADE_MAX_IN_FLIGHT` |
| Live connections, whole server | 500 | `FADE_MAX_SOCKETS` |
| Live connections per person | 10 (a new one closes the oldest) | |
| Writes (sending, reacting, ...) | 600 per 10 minutes, per address and per session | |
| Sign-in and sign-up attempts | 30 per address per 10 minutes | |
| Wrong passwords | 10 per username per 15 minutes | |
| Image uploads | 60 per person per 10 minutes, decoded one at a time | |
| Friend requests | 50 per person per day | |
| Invite links | 20 new per person per day; 10 live at once; each 10 uses, 7 days | |
| New groups | 20 per person per day; 32 people per group | |
| Favorites | 10 per person (direct chats and groups together) | Turning one on or off adds a row (Rule 1); writes are capped by the write budgets |
| Unopened pics on disk | 256 MB direct, 200 MB group | `FADE_SNAP_DISK_MB`, `FADE_GROUP_PIC_DISK_MB` |
| Uploads stop when the data disk has less than | 150 MB free | |
| All writes stop when the data disk has less than | 40 MB free (so the database can't fill the disk) | |
| Client diagnostics | 300 entries per person per minute | |

Per-address limits don't apply to the server's own machine (development and tests). In-memory limits and bans reset when the server restarts.

## What we don't protect against (yet)

Being honest about the gaps:

- **A large network flood (DDoS).** Everything above works inside the app. A flood big enough to saturate the instance's network, or Caddy's TLS handshakes, would still take napsack offline until it stops. The fix is a CDN/WAF in front (AWS CloudFront with WAF, or Cloudflare); it costs money and moves TLS to the provider, so it's a decision for when napsack is a bigger target.
- **Many addresses at once.** Per-address limits slow one attacker; a botnet with thousands of addresses could still make noise. The account cap, the per-session limits, and the in-flight ceiling are what keep that from becoming damage.
- **The server is a single machine.** If it dies, napsack is down until it's replaced (the data volume and backups survive). Planned: an Auto Scaling group of one ([plan.md](plan.md)).
- **The web app is delivered by the server.** A compromised server could ship code that leaks keys as you type; every browser-based encrypted app shares this. The iOS app, signed and reviewed before install, closes it.
- **Metadata.** The server sees who talks to whom and when; it needs to, to deliver messages.

## When something looks wrong

1. **Look.** The admin panel's *Protection* line shows accounts used, banned addresses, and requests refused since start. `/admin#logs` holds recent events (search `ip=...` to see what one address did). Older history, and every problem an app reported: `scripts/ssh.sh "sudo journalctl -u fade --since '1 hour ago'"`.
2. **Stop new accounts.** Set `FADE_MAX_ACCOUNTS` to the current count (or change the invite code in `terraform.tfvars`), `terraform apply`, then `scripts/ssh.sh "sudo systemctl restart fade"`.
3. **Shut out an address** that gets past the automatic bans: add a deny rule for it to the subnet's network ACL in AWS (instant, no restart).
4. **Someone's account was taken over.** From the admin panel, issue them a reset code: it ends every session and gives them a new key.
5. **The server itself is compromised.** Take it out of service (stop the instance), snapshot the data volume, and rebuild from a known release; the backups in S3 can't have been altered. [BACKUPS.md](BACKUPS.md) has the restore drill.

## Changing a limit

The settings in the table are environment variables. Add the line to `local.env_file` in `infra/main.tf` (for example `"FADE_MAX_ACCOUNTS=150",`), run `terraform plan` and `apply` (it only updates the settings parameter), then restart: `scripts/ssh.sh "sudo systemctl restart fade"`. The rest are constants in `server/src/` (`guard.rs`, `main.rs`), changed with a release.

Every limit has a test: `server/src/guard.rs` (unit tests) and `tests/smoke_test.py` (`check_guard`, `check_rate_limits`).
