# How napsack works

A tour of the app for the people who run it, with most of the time spent on the end-to-end encryption: what happens to your password, where keys live, and what the server can and can't see.

The exact strings and numbers here come from [`shared/crypto/crypto.js`](../shared/crypto/crypto.js) and [`server/static/app.js`](../server/static/app.js). If you change those, update this doc in the same change.

- [At a glance](#at-a-glance)
- [The parts](#the-parts)
- [What happens to your password](#what-happens-to-your-password)
- [Your keys, and where they live](#your-keys-and-where-they-live)
- [Sending a message](#sending-a-message)
- [Pics](#pics)
- [Safety codes and changed keys](#safety-codes-and-changed-keys)
- [Limits](#limits)
- [The admin panel](#the-admin-panel)
- [Glossary](#glossary)

## At a glance

Every direct text and every pic is encrypted in the sender's browser and decrypted in the recipient's. **Group chats are the exception for now:** see [Group chats](#group-chats). The server stores and forwards ciphertext. It still has to know some things to deliver messages at all:

| The server knows | The server never sees |
|---|---|
| Usernames and who is friends with whom | What any text says |
| When each message was sent, and whether it was a text or a pic | What any pic shows, or its caption |
| Display names, nicknames, and profile pictures (see [Profiles](#profiles)) | |
| Roughly how long each message is | Your password |
| When texts were read and whether pics were opened | Your private key, unwrapped |
| Each account's public key | The key you share with each friend |

## The parts

**The server** is one Rust program (axum and SQLite). It serves the API, a WebSocket for live updates, and the web app itself: the HTML, CSS and JavaScript are compiled into the binary, so a deploy is a single file.

**The web app** is plain JavaScript with no framework and no build step. All of the encryption lives in one file, `shared/crypto/crypto.js`, and uses only WebCrypto, the cryptography built into every modern browser. The iOS app uses the very same file. There are no third-party crypto libraries to trust.

**The machine** is one small ARM server on AWS. Caddy sits in front for HTTPS. The database and TLS certificates live on a separate encrypted disk that survives the server being replaced, with a snapshot taken every day. Unopened pics wait on that disk as ciphertext (see [Pics](#pics)).

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

> **Why the "associated" string matters.** It isn't secret and isn't stored, but it is mixed into the tag. If the server tried to replay a message you sent as if your friend had sent it, or relabel a pic as a text, the recipient's browser would compute a different associated string and decryption would fail. The server can drop or delay messages. It can't forge them, read them, or move them around undetected.

## Pics

Pics are called *snaps* in the code and API, so you'll see `snap` in the strings below.

1. **Capture.** The front camera is mirrored, like a mirror, and the photo matches the preview.
2. **Compress.** Redrawn as a JPEG, which drops all metadata, including GPS. Starts at 1280 px and quality 0.8, then lowers quality and shrinks until it's 200 KB or less.
3. **Caption.** Optional, up to 200 characters, typed over the preview.
4. **Encrypt.** The caption and the photo are packed together and encrypted as one: same chat key, fresh IV, associated string `napsack/v2/snap/<sender>/<recipient>`. This is message format 2 (below), so the server can't read the caption any more than the photo.
5. **Wait on disk.** The server writes the ciphertext to a file on the encrypted data disk, up to 512 KB per pic, and notes its size in the database. A restart or a deploy doesn't lose it.
6. **Open once.** The first fetch by the recipient deletes the file and marks the pic opened. A second fetch gets "gone".

Unopened pics expire after 30 days; the server deletes the file and marks them expired, so both people see what happened. The size check is the only check the server can make, because it can't see the image. In testing, a camera frame came out around 70 KB, and a deliberately hard-to-compress image around 160 KB.

**The trade-off of lasting pics.** Until 0.13.0, unopened pics lived only in server memory and vanished on every restart. Now an unopened pic's ciphertext sits on disk until it's opened or expires, and the daily disk snapshots can keep a copy for up to 30 days after that. It is still unreadable without one of the two friends' keys.

### Format 2: a pic with a caption

Format 1 encrypts the JPEG bytes alone. Format 2 encrypts this instead:

| Bytes | Contents |
|---|---|
| 2 | Caption length in bytes, big-endian (0 for no caption; at most 1000) |
| that many | The caption, UTF-8 |
| the rest | The JPEG |

The associated string says `v2` (`napsack/v2/snap/7/3`), so a format 2 pic can't be passed off as format 1 or the other way round. Every message stores its format, and format 1 pics stay readable forever. Texts are still format 1. The pinned test vectors are in `tests/vectors/format2.json`.

Group pics aren't end-to-end encrypted (see [Group chats](#group-chats)), so their captions are plain text on the server, revealed with the pic when it's opened.

View-once is a server promise, not a cryptographic one. The recipient's screen shows the decrypted photo for ten seconds, and nothing stops a screenshot or a second camera.

## Group chats

Group chats are **not end-to-end encrypted yet.** Group messages travel over HTTPS and sit on an encrypted disk, but the napsack server can read them, unlike direct chats. Every group shows a notice saying so, and group messages carry `format` 0 ("not encrypted"), so a future encrypted version can be told apart.

Doing it properly means giving each group a shared key, handing it to members through their own keys, and replacing it whenever someone leaves. That's planned; until then, keep anything private to direct chats.

## Profiles

You can set a display name and a profile picture. Your friends see them; nobody else does, and the server enforces that. You can also give any friend a nickname, which only you see. The app shows a friend by your nickname for them, else their display name, else their username.

These are **not** end-to-end encrypted: the server stores names and pictures, the way it stores usernames. Profile pictures are rebuilt by the server like every image it handles (decoded, size-checked, re-encoded), and every name and picture you've ever set is kept.

Usernames stay the identity. A display name could be anything, including someone else's name, so the app shows `@username` wherever a name differs from it, and safety codes and key warnings always use the username.

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

Usernames on the server's admin list (`FADE_ADMINS`, set from Terraform's `admin_usernames`) can open `/admin`. It shows totals and activity (users, sign-ups, who's online, messages per day, pic open rates, server health), all computed from counts and timestamps. It can't show message content, because the server doesn't have any. Everyone else gets a "not found".

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
