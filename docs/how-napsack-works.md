# How napsack works

A tour of the app for the people who run it, with most of the time spent on the end-to-end encryption: what happens to your password, where keys live, and what the server can and can't see.

The exact strings and numbers here come from [`server/static/crypto.js`](../server/static/crypto.js) and [`server/static/app.js`](../server/static/app.js). If you change those, update this doc in the same change.

- [At a glance](#at-a-glance)
- [The parts](#the-parts)
- [What happens to your password](#what-happens-to-your-password)
- [Your keys, and where they live](#your-keys-and-where-they-live)
- [Sending a message](#sending-a-message)
- [Snaps](#snaps)
- [Safety codes and changed keys](#safety-codes-and-changed-keys)
- [Limits](#limits)
- [The admin panel](#the-admin-panel)
- [Glossary](#glossary)

## At a glance

Every text and every snap is encrypted in the sender's browser and decrypted in the recipient's. The server stores and forwards ciphertext. It still has to know some things to deliver messages at all:

| The server knows | The server never sees |
|---|---|
| Usernames and who is friends with whom | What any text says |
| When each message was sent, and whether it was a text or a snap | What any snap shows |
| Roughly how long each message is | Your password |
| When texts were read and whether snaps were opened | Your private key, unwrapped |
| Each account's public key | The key you share with each friend |

## The parts

**The server** is one Rust program (axum and SQLite). It serves the API, a WebSocket for live updates, and the web app itself: the HTML, CSS and JavaScript are compiled into the binary, so a deploy is a single file.

**The web app** is plain JavaScript with no framework and no build step. All of the encryption lives in one file, `crypto.js`, and uses only WebCrypto, the cryptography built into every modern browser. There are no third-party crypto libraries to trust.

**The machine** is one small ARM server on AWS. Caddy sits in front for HTTPS. The database and TLS certificates live on a separate encrypted disk that survives the server being replaced, with a snapshot taken every day. The machine has no swap and core dumps are off, so snap bytes held in memory can't be paged or dumped to disk.

## What happens to your password

Most apps send your password to the server and the server checks it. napsack can't do that, because the same password also unlocks your messages: a server that saw it could read everything. So your browser turns the password into two separate keys before anything is sent.

1. **Password.** Typed into the sign-in form. Never leaves the browser.
2. **Stretch it.** PBKDF2-SHA256, 600,000 rounds, salted with your username. Takes about a second on purpose.
3. **Split it.** HKDF turns the result into two unrelated 256-bit keys.
4. **Auth key → server.** Sent in place of the password. The server stores only an Argon2 hash of it.
5. **Wrap key → stays.** Never sent. Used only to lock and unlock your private key.

```
password
└─ PBKDF2-SHA256 · 600,000 rounds · salt "napsack/v1/user/<username>"
   └─ master secret (256 bits)
      ├─ HKDF · info "napsack/v1/auth"  → auth key   sent at sign-in; server keeps Argon2(auth key)
      └─ HKDF · info "napsack/v1/wrap"  → wrap key   AES-256-GCM key, never leaves the device
```

Because the two keys come out of HKDF with different labels, knowing the auth key tells you nothing about the wrap key. The server can check that you know your password without ever being able to unlock what the password protects.

Usernames are case-insensitive, so the username is lowercased before it's used as the salt. `Nate` and `nate` derive the same keys.

## Your keys, and where they live

When you create an account, your browser makes a key pair on the P-256 curve. The **public key** is safe to share; friends use it to set up a shared key with you. The **private key** is what lets you read messages.

The browser locks (wraps) the private key with your wrap key using AES-256-GCM, and uploads two things: the public key, and the locked private key. The server stores both, but the locked copy is useless without your password.

Signing in on a new device:

1. **Sign in anywhere.** A new phone or browser derives the auth key and wrap key from your password.
2. **Download the locked key.** The server returns your wrapped private key after checking the auth key.
3. **Unlock it locally.** The wrap key opens it. A wrong password simply fails here.
4. **Keep it in the browser.** Stored in IndexedDB as a non-extractable key: page code can use it but can't read it out.

That's why your whole history appears on a new device: every message was encrypted to the same key pair, and your password gets that key back. Reloading the page doesn't ask for the password again, because the unlocked key stays in the browser's storage. Signing out deletes it.

## Sending a message

You and each friend share one secret key that only the two of you can compute. It comes from a Diffie-Hellman exchange (ECDH): your private key combined with their public key gives exactly the same result as their private key combined with your public key. Nobody else can produce it, including the server, which only ever has the public halves.

```
ECDH(your private key, their public key)      same value on both phones
└─ HKDF · salt "napsack/v1/pair/<lower id>/<higher id>" · info "napsack/v1/messages"
   └─ chat key (AES-256-GCM)

each message:
   iv          = 12 random bytes, new every time
   associated  = "napsack/v1/<text|snap>/<sender id>/<recipient id>"
   stored      = base64( iv ‖ AES-GCM(chat key, iv, message, associated) )
```

Here is the shape of what the server stores for the text "see you at 8":

| Column | Value |
|---|---|
| `sender_id` | `7` |
| `recipient_id` | `3` |
| `kind` | `text` |
| `ciphertext` | `GNrlSfBc9OsEiVd0++hM/8qrLRwegNitZzi9Q3RmD5G0R5tMtT1ANQ==` |
| `created_at` | `1792441555` |

That's 40 bytes: the first 12 are the random IV, then the 12 encrypted bytes of the text, then a 16-byte authentication tag. Change a single bit and decryption fails instead of producing garbage. Send the same text again and the stored value is completely different.

> **Why the "associated" string matters.** It isn't secret and isn't stored, but it is mixed into the tag. If the server tried to replay a message you sent as if your friend had sent it, or relabel a snap as a text, the recipient's browser would compute a different associated string and decryption would fail. The server can drop or delay messages. It can't forge them, read them, or move them around undetected.

## Snaps

1. **Capture.** The front camera is mirrored, like a mirror, and the photo matches the preview.
2. **Compress.** Redrawn as a JPEG, which drops all metadata, including GPS. Starts at 1280 px and quality 0.8, then lowers quality and shrinks until it's 200 KB or less.
3. **Encrypt.** Same chat key, fresh IV, associated string ending in `snap/<sender>/<recipient>`.
4. **Hold in memory.** The server keeps the ciphertext in RAM only, never on disk, up to 512 KB per snap.
5. **Open once.** The first fetch by the recipient removes it from memory. A second fetch gets "gone".

Unopened snaps expire after 24 hours, and a server restart drops them all. The server marks them expired so both people see what happened. The size check is the only check the server can make, because it can't see the image. In testing, a camera frame came out around 70 KB, and a deliberately hard-to-compress image around 160 KB.

View-once is a server promise, not a cryptographic one. The recipient's screen shows the decrypted photo for ten seconds, and nothing stops a screenshot or a second camera.

## Safety codes and changed keys

There's one attack the scheme above can't stop by itself: a dishonest server could hand you its own public key and claim it's your friend's. You'd then be encrypting to the server. napsack defends against this in two ways.

**Pinning.** The first time your browser sees a friend's public key, it remembers it. napsack keys never change, so if the server later serves a different key, the chat shows a warning and refuses to send anything until it's explained.

**Safety codes.** Tap *Encrypted* in any chat to see a code like `48663 30443 09844 / 47350 63988 34781`. Both of you see the same code, computed from both public keys (SHA-256 of the two keys, sorted, cut into six five-digit groups). Compare it in person or over a call. If it matches, nobody is in the middle, and pinning keeps it that way.

## Limits

- **A forgotten password means unreadable history.** The key can only be unlocked with the password. Nobody, including whoever runs the server, can recover it.
- **A weak password is the weakest link.** Someone who stole the database could try passwords offline against the wrapped key. The 600,000-round stretch makes each guess slow, but a short or common password will still fall. Use a long one.
- **The server delivers the app.** The web app's JavaScript comes from the same server. A compromised server could ship code that leaks keys as you type. Every browser-based encrypted app shares this problem. A native app, whose code is signed and reviewed before install, closes it.
- **No forward secrecy.** Each pair of friends uses one long-lived key. If a password and old ciphertext both leaked, past messages could be read. Signal-style ratcheting fixes this at real complexity.
- **Metadata is visible.** Who talks to whom, when, and how much is what the server needs to deliver messages. It's also what the admin panel shows, as counts.
- **Passwords can't be changed yet.** Changing one means re-wrapping the private key and replacing the auth key in one step. It's planned.

## The admin panel

Usernames on the server's admin list (`FADE_ADMINS`, set from Terraform's `admin_usernames`) can open `/admin`. It shows totals and activity (users, sign-ups, who's online, messages per day, snap open rates, server health), all computed from counts and timestamps. It can't show message content, because the server doesn't have any. Everyone else gets a "not found".

## Glossary

| Term | What it does here |
|---|---|
| PBKDF2 | Slowly stretches your password into a strong secret, so guessing passwords is expensive. |
| HKDF | Turns one secret into several independent keys, each tied to a label. |
| Argon2 | The server's slow hash of your auth key, so a database leak can't be used to sign in. |
| P-256 / ECDH | The key pair each account has, and the exchange that gives two friends the same secret. |
| AES-256-GCM | Encrypts each message and detects any tampering with it. |
| IV | 12 random bytes per message, so the same text never encrypts the same way twice. |
| Associated data | Context (sender, recipient, kind) checked during decryption but not encrypted. |
| Wrapping | Encrypting a key with another key. Your private key is wrapped with your wrap key. |
| Pinning | Remembering a friend's key the first time you see it, and warning if it changes. |
