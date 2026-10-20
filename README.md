# napsack

A minimal private messenger for a few friends. You get a list of chats with your friends, text messages, and photo pics that disappear once they're viewed. Every text and pic is end-to-end encrypted in the browser, so the server only ever stores and relays ciphertext. Pics are held only in server RAM, never written to the database, disk, or S3.

`fade` is still the internal name: the binary, systemd unit, env vars, and AWS resources keep it.

```
server/         Rust (axum + SQLite). One binary that serves the API and the web client.
  static/       Web client: plain HTML/CSS/ES modules, no build step, no Node. crypto.js holds all E2E code.
  migrations/   SQLite schema
infra/          Terraform for AWS
scripts/        test.sh, deploy.sh, rollback.sh, ssh.sh
tests/          API smoke test and browser (Playwright) tests
docs/           how-napsack-works.md, RELEASING.md, mobile.md
.github/        CI on every push; server releases on server-v* tags
```

## Run locally

```sh
cd server
cargo run                                   # http://127.0.0.1:8080
FADE_INVITE_CODE=letmein cargo run          # require an invite code to sign up
```

The camera works on `localhost` because browsers treat it as a secure context. To try it from your phone over LAN you need HTTPS, so deploy instead, or tunnel through something like `tailscale serve`.

### Tests

`scripts/test.sh` builds the server, starts it on a throwaway database, and runs everything CI runs: unit tests, the API smoke test (which sends opaque encrypted payloads and checks the server stores and returns them untouched, plus the version checks), and browser tests that drive the real web client in Chrome through sign-up, encrypted chat, pics, safety codes, the admin panel, and camera mirroring.

```sh
pip install -r tests/requirements.txt
scripts/test.sh                  # everything (needs Chrome)
scripts/test.sh --no-browser     # skip the browser tests
```

### Configuration (environment)

| Variable | Default | |
|---|---|---|
| `FADE_BIND` | `127.0.0.1:8080` | |
| `FADE_DATABASE_URL` | `sqlite://fade.db` | |
| `FADE_INVITE_CODE` | unset (open signup) | Required to register when set |
| `FADE_SNAP_TTL_HOURS` | `24` | Unopened pics are dropped after this |
| `FADE_SNAP_MAX_KB` | `512` | Hard cap per encrypted pic. The client compresses every photo to 200 KB or less |
| `FADE_SNAP_POOL_MB` | `128` | RAM ceiling for all unopened pics |
| `FADE_SESSION_DAYS` | `90` | |
| `FADE_ADMINS` | unset (panel off) | Comma-separated usernames allowed into `/admin` |
| `RUST_LOG` | `fade_server=info` | What goes to stdout (the system journal on the server) |
| `FADE_LOG_BUFFER` | `fade_server=debug` | What the admin log viewer keeps (last 20,000 entries, in memory) |
| `FADE_MIN_CLIENT_VERSIONS` | unset | e.g. `ios=1.2.0`. Older native apps get `426` and an update prompt ([docs/RELEASING.md](docs/RELEASING.md)) |

## Deploy to AWS

```sh
cd infra
cp terraform.tfvars.example terraform.tfvars   # set invite_code
terraform init && terraform apply
cd ..

# one-time build tooling
rustup target add aarch64-unknown-linux-musl
cargo install cargo-zigbuild && pip install ziglang

scripts/deploy.sh          # build, copy over SSH, restart, check the live build
scripts/ssh.sh             # shell on the box; extra args run a command
scripts/rollback.sh        # list kept builds, or roll back to one
```

The normal way to ship the server is a `server-v*` tag, which GitHub Actions tests, builds, and deploys. `scripts/deploy.sh` is for hotfixes. Versioning, compatibility rules, rollbacks, and one-time CI setup are in [docs/RELEASING.md](docs/RELEASING.md).

SSH uses `~/.ssh/id_ed25519` by default (`ssh_public_key_path`). With `ssh_allowed_cidrs` empty, port 22 stays closed and SSH is tunneled through SSM, which needs the AWS CLI and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Set it to e.g. `["203.0.113.7/32"]` to connect directly instead. To use plain `ssh fade`, scp, or VS Code Remote-SSH, run `terraform -chdir=infra output -raw ssh_config >> ~/.ssh/config`.

Deploy runs `sudo fade-update <file>` on the box: it keeps the old binary as `fade-server.prev`, restarts, and fails if the service doesn't come back up. It also copies the build to S3, so a replaced instance boots with the same release.

With no `domain` set, the app is served at `https://<elastic-ip-with-dashes>.sslip.io` with a real Let's Encrypt cert, so you don't need DNS. To use your own domain on a fresh deploy, run `terraform apply -target=aws_eip.app` first, point an A record at that IP, set `domain`, then run a full `terraform apply`. Otherwise Caddy requests the cert before DNS resolves and backs off. Changing it replaces the instance, but the data volume survives.

What you get: one Graviton `t4g.nano` running Amazon Linux 2023, Caddy for TLS, and the app under a hardened systemd unit. The DB and certs sit on a separate encrypted EBS volume with daily snapshots. You get in over SSH as `ec2-user`, which has sudo. The SSH host keys live on the data volume, so replacing the instance doesn't trigger host-key warnings.

Changing config: edit tfvars, run `terraform apply` (which updates the SSM parameter), then `scripts/ssh.sh sudo systemctl restart fade`. Rollback: `scripts/rollback.sh`.

### Rough monthly cost (us-east-1, on-demand)

| | |
|---|---|
| t4g.nano | ~$3.07 |
| Public IPv4 (Elastic IP) | ~$3.65 |
| 8 GB root + 1 GB data gp3 | ~$0.72 |
| Snapshots, S3, SSM parameter | cents |
| **Total** | **~$7.50** |

The first 100 GB/month of outbound data is free. Check current prices before relying on these numbers. The IPv4 charge is the biggest line after compute. Putting CloudFront in front could eventually remove it, but that's not worth the complexity yet.

## End-to-end encryption

For a fuller walkthrough with diagrams, see [docs/how-napsack-works.md](docs/how-napsack-works.md).

All of it is in [server/static/crypto.js](server/static/crypto.js), using the browser's built-in WebCrypto.

- **Sign-in.** The password never leaves the browser. PBKDF2-SHA256 (600k iterations, salted with the lowercased username) turns it into a master secret, and HKDF splits that into an *auth key*, sent in place of the password (the server Argon2-hashes it), and a *wrap key*, which never leaves the device.
- **Identity.** Each account has a P-256 key pair made at sign-up. The server stores the public key and the private key encrypted (AES-GCM) with the wrap key. Signing in on any device downloads that blob and unwraps it locally, which is why history works on a new phone. The unwrapped key is kept as a non-extractable `CryptoKey` in IndexedDB, and signing out deletes it.
- **Messages.** Two friends' keys give them the same AES-256-GCM key (ECDH, then HKDF salted with both user ids). Every text and pic gets a fresh random IV, and the sender id, recipient id, and kind are bound in as additional data, so the server can't reattribute or relabel a message.
- **Trust.** The first key a browser sees for each friend is pinned. If the server ever serves a different one, that chat shows a warning and refuses to send. Each chat has a safety code (tap "Encrypted") that both friends can compare in person to rule out a man in the middle.

What the server still sees: who is friends with whom, when messages are sent and read, message sizes, and pic state. What it can't see: text content, photos, or passwords.

Limits worth knowing:
- **A forgotten password means unreadable history.** No one, including the server, can recover the key.
- **The server delivers the JavaScript.** A compromised server could ship code that leaks keys. That's true of every web-based E2E app; a native client with pinned code fixes it.
- **No forward secrecy.** Keys are long-lived, so someone who learns a password and has saved ciphertext can read it. Signal-style ratcheting would fix that, at real complexity.
- **Password changes aren't supported yet.** The key would need to be re-wrapped and the auth key replaced in one step.

## How pics work

Pics are called *snaps* in the code, API, and database (`snap_state`, `/api/snaps`), the same way `fade` is the internal name.

1. The client draws the photo through a canvas. This strips EXIF (including GPS) and compresses it to a JPEG of at most 200 KB: it starts at 1280px and quality 0.8, then lowers the quality and shrinks the picture until it fits. It encrypts the JPEG and POSTs the ciphertext to `/api/chats/{friend}/snaps`.
2. The server checks only the size (it can't see the image), writes a metadata row (`snap_state = pending`, no image), and keeps the ciphertext in an in-memory map keyed by message id.
3. The recipient's `GET /api/snaps/{id}` removes the ciphertext from the map and returns it once, with `Cache-Control: no-store`, and the browser decrypts it. A second fetch gets `410 Gone`. The sender can't fetch it.
4. The row becomes `opened`, and both people get a `message_updated` event so the chat shows "Opened" or "Viewed".
5. Unopened pics expire after the TTL. A restart drops them all, and they're marked `expired` on boot.

To make "never touches disk" hold at the OS level, the instance runs with no swap and core dumps disabled, and the unit sets `MemorySwapMax=0` and `LimitCORE=0`.

Known limits:
- Anyone can screenshot. Browsers can't block it, and native apps can only detect it on some platforms.
- The recipient's browser has the decrypted photo while it's on screen. View-once is enforced by the server dropping the ciphertext, not by cryptography.

## API

All endpoints are under `/api`. Auth is `Authorization: Bearer <token>`, which works the same way for a mobile app. Errors look like `{"error": "human readable"}`. Native apps also send `X-Napsack-Client: ios/<version>+<build>`; see [docs/RELEASING.md](docs/RELEASING.md) for the compatibility rules every change has to follow.

| | |
|---|---|
| `GET  /config` | `{invite_required, snap_max_bytes, snap_ttl_hours, api_version, server_version, build, message_formats, min_client_versions}` (no auth, never version-blocked) |
| `POST /auth/register` | `{username, auth_key, public_key, wrapped_private_key, invite_code?}` → `{token, user, public_key, wrapped_private_key}` |
| `POST /auth/login` | `{username, auth_key}` → `{token, user, public_key, wrapped_private_key}` |
| `POST /auth/logout` | |
| `GET  /me` | `{id, username, is_admin}` |
| `GET  /friends` | Chat list: `[{id, username, public_key, last_message, unread}]`, newest first |
| `DELETE /friends/{id}` | Unfriend |
| `GET  /users/{id}/profile` | Your own (`kind: "me"`: friends, your counts) or a friend's (`kind: "friend"`: what you share, mutual friends). 404 for anyone else |
| `GET  /friends/requests` | `{incoming: [...], outgoing: [...]}` |
| `POST /friends/requests` | `{username}`. Auto-accepts if they already asked you |
| `POST /friends/requests/{id}/accept` | |
| `DELETE /friends/requests/{id}` | Decline or cancel |
| `GET  /chats/{friend}/messages?before=&limit=` | Oldest first |
| `POST /chats/{friend}/messages` | `{ciphertext, format?}`: base64 of IV ‖ AES-GCM output; `format` defaults to 1 |
| `POST /chats/{friend}/read` | Marks their texts as read |
| `POST /chats/{friend}/snaps?format=1` | Encrypted image bytes (IV ‖ AES-GCM output) |
| `GET  /snaps/{id}` | View once; returns the encrypted bytes |
| `GET  /admin/stats` | Counts for the admin panel; 404 unless you're in `FADE_ADMINS` |
| `GET  /admin/logs?level=&q=&source=&before=&after=&limit=` | Recent log entries, newest first; same access rule. `source`: `server` or `client` |
| `POST /logs` | Client diagnostics: `{entries: [{level, message, fields}]}`, up to 50 per request, rate-limited. Never send content; content-like fields are redacted |
| `GET  /ws` | WebSocket. First frame: `{"type":"auth","token":"..."}` |

WebSocket events: `ready`, `message`, `message_updated`, `read {by, at}`, `friends_changed`. On every `ready` the client refetches its state, so missed events while disconnected don't matter.

Messages include `format` (the encryption scheme, 1 today) so clients know how to decrypt them.

## The iOS app

Planned in [docs/mobile.md](docs/mobile.md): Expo (React Native, TypeScript), sharing the web client's encryption code and checked against common test vectors, built and shipped through EAS so it can be developed from Windows.

## Next up

1. **The iOS app, with push notifications.** [docs/mobile.md](docs/mobile.md). A messenger without notifications only works while it's open.
2. **Recovery key and password change.** Today a forgotten password locks you out and loses your history. A recovery key shown once at sign-up (it wraps the private key too) fixes both, and makes password change a re-wrap.
3. **Account safety basics.** Rate-limit sign-in attempts, list signed-in devices with "sign out everywhere", and let people delete their account.
4. **Disappearing texts.** A per-chat timer after which the server deletes the ciphertext. Fits the product, and means less data held.
5. **Group chats.** Needs its own encryption design (pairwise fan-out is simplest for small groups), so it comes after the app.

Smaller ideas: sender-chosen pic timers, typing indicators, reactions, and forward secrecy.
