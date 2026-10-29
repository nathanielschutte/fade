# How napsack works

A tour of the app for the people who run it, with most of the time spent on the end-to-end encryption: what happens to your password, where keys live, and what the server can and can't see.

The exact strings and numbers here come from [`shared/crypto/crypto.js`](../shared/crypto/crypto.js) and [`server/static/app.js`](../server/static/app.js). If you change those, update this doc in the same change.

- [At a glance](#at-a-glance)
- [The parts](#the-parts)
- [What happens to your password](#what-happens-to-your-password)
- [Your keys, and where they live](#your-keys-and-where-they-live)
- [Forgot your password?](#forgot-your-password)
- [Sending a message](#sending-a-message)
- [Pics](#pics)
- [Group chats](#group-chats)
- [Profiles](#profiles)
- [Replies and reactions](#replies-and-reactions)
- [Notifications](#notifications)
- [Typing and "active now"](#typing-and-active-now)
- [Team Napsack](#team-napsack)
- [Invite links](#invite-links)
- [The friend map](#the-friend-map)
- [Safety codes and changed keys](#safety-codes-and-changed-keys)
- [Limits](#limits)
- [Roles and the System page](#roles-and-the-system-page)
- [Keeping it running](#keeping-it-running)
- [Glossary](#glossary)

## At a glance

Every direct text and pic, and every group message and pic, is encrypted in the sender's browser and decrypted in the recipients'. A group's name and picture, and group reactions, aren't: see [Group chats](#group-chats). The server stores and forwards ciphertext. It still has to know some things to deliver messages at all:

| The server knows | The server never sees |
|---|---|
| Usernames and who is friends with whom | What any text says, direct or group |
| When each message was sent, and whether it was a text or a pic | What any pic shows, or its caption (or what was drawn on it) |
| Who is in which group, and each group's name and picture | Which emoji someone reacted with in a direct chat, or which message a text replies to |
| Display names, nicknames, profile pictures and birthdays (see [Profiles](#profiles)) | |
| That a reaction happened, on which message; which emoji, in groups | |
| Who's online and who's typing (to friends who share it) | Your password |
| Roughly how long each message is | Your private key, unwrapped |
| When texts were read and whether pics were opened | The key you share with each friend |
| Each account's public key | The key that opens each group message |

## The parts

**The server** is one Rust program (axum and SQLite). It serves the API, a WebSocket for live updates, and the web app itself: the HTML, CSS and JavaScript are compiled into the binary, so a deploy is a single file.

**The web app** is plain JavaScript with no framework and no build step. All of the encryption lives in one file, `shared/crypto/crypto.js`, and uses only WebCrypto, the cryptography built into every modern browser. The iOS app uses the very same file. There are no third-party crypto libraries to trust.

**The machine** is one small ARM server on AWS, at napsack.io. Caddy sits in front for HTTPS. The database and TLS certificates live on a separate encrypted disk that survives the server being replaced. The database is backed up every hour and the disk snapshotted every day (see [Keeping it running](#keeping-it-running)). Unopened pics wait on that disk as ciphertext (see [Pics](#pics)).

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

**Changing your password** keeps the same key pair. Your browser unlocks the private key with the old password and locks it again with the new one, then sends the new auth key and the newly locked copy. History stays readable, and every other signed-in device is signed out.

## Forgot your password?

The password unlocks your private key, and nobody else has a copy. So "reset my password" can't work the usual way. There are two ways back in, and only one keeps your history.

**Your recovery key (keeps everything).** When you sign up, napsack shows a recovery key once, like `0CG3-TPKQ-JJRW-XTR8-4N15-YZ4S-PV9Z-039A`: 20 random bytes in Crockford base32 (no I, L, O or U, so it's easy to copy by hand). Your browser uses it like a password:

| Step | What happens |
|---|---|
| Two keys | HKDF-SHA-256 turns the recovery key into a recovery auth key (`napsack/v1/recovery/auth`) and a recovery wrap key (`napsack/v1/recovery/wrap`). It's random, so no slow stretching is needed. |
| A second locked copy | The recovery wrap key locks a second copy of your private key (associated string `napsack/v1/recovery`). The server stores that copy and an Argon2 hash of the recovery auth key. |
| Getting back in | You enter your username, the recovery key and a new password. The server checks the recovery auth key and returns the second copy; your browser unlocks it and locks it again under the new password. |

The server never sees the recovery key or the private key. Making a recovery key later, or a new one, needs your password. Otherwise someone with a stolen session could plant their own. The pinned test vectors are in `tests/vectors/recovery.json`.

**A reset code from an admin (no history).** If you've lost both, an admin can give you a one-time reset code (16 characters, good for 24 hours, stored only as a hash). With it you choose a new password, and your browser makes a brand-new key pair. You keep your account, friends and groups, but messages from before can't be read by you or anyone else. Your friends see a changed safety code (below). The old keys aren't thrown away: if you ever remember the old password, the history it protects could still be unlocked.

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
2. **Draw.** Optional: pen strokes and emoji stickers, with undo. They're flattened into the photo itself before anything else happens, so nothing about the drawing travels separately.
3. **Compress.** Redrawn as a JPEG, which drops all metadata, including GPS. Starts at 1280 px and quality 0.8, then lowers quality and shrinks until it's 200 KB or less.
4. **Caption.** Optional, up to 200 characters, typed over the preview.
5. **Encrypt.** The caption and the photo are packed together and encrypted as one: same chat key, fresh IV, associated string `napsack/v2/snap/<sender>/<recipient>`. This is message format 2 (below), so the server can't read the caption any more than the photo.
6. **Wait on disk.** The server writes the ciphertext to a file on the encrypted data disk, up to 512 KB per pic, and notes its size in the database. A restart or a deploy doesn't lose it.
7. **Open once.** The recipient's app downloads the ciphertext, decrypts it, and shows it. Only then does it tell the server it was opened, and the server deletes the file and marks the pic opened, so a dropped download can simply be fetched again. A pic downloaded but never confirmed counts as opened 15 minutes after the first download. After that, a fetch gets "gone".

Unopened pics expire after 30 days; the server deletes the file and marks them expired, so both people see what happened. The size check is the only check the server can make, because it can't see the image. In testing, a camera frame came out around 70 KB, and a deliberately hard-to-compress image around 160 KB.

**The trade-off of lasting pics.** Until 0.13.0, unopened pics lived only in server memory and vanished on every restart. Now an unopened pic's ciphertext sits on disk until it's opened or expires, and the daily disk snapshots can keep a copy for up to 30 days after that. It is still unreadable without one of the two friends' keys.

### Format 2: a pic with a caption

Format 1 encrypts the JPEG bytes alone. Format 2 encrypts this instead:

| Bytes | Contents |
|---|---|
| 2 | Caption length in bytes, big-endian (0 for no caption; at most 1000) |
| that many | The caption, UTF-8 |
| the rest | The JPEG |

The associated string says `v2` (`napsack/v2/snap/7/3`), so a format 2 pic can't be passed off as format 1 or the other way round. Every message stores its format, and format 1 pics stay readable forever. Texts have a format 2 of their own (see [Replies and reactions](#replies-and-reactions)). The pinned test vectors are in `tests/vectors/format2.json`.

Group pics use this same envelope, caption included, sealed with format 3 (see [Group chats](#group-chats)), and wait on disk the same way, view-once for each member.

### Formats 4 and 5: videos

Hold the shutter to record a video of up to 10 seconds (the server's `FADE_VIDEO_MAX_SECONDS`), with sound. The browser records it (MP4 where it can, WebM otherwise), then encrypts a *media envelope*:

| Bytes | Contents |
|---|---|
| 2 | Header length in bytes, big-endian |
| that many | The header, UTF-8 JSON: `{"type": "video/mp4", "c": "the caption"}` |
| the rest | The video |

Only video types are accepted in `type`, by sender and receiver alike. Readers ignore header keys they don't know, so later additions don't need a new format. In a direct chat it's **format 4**: the same chat key, associated string `napsack/v4/snap/<sender>/<recipient>`. In a group it's **format 5**: the format 3 scheme with the content kind `video`. Either way the server stores opaque bytes, view-once, like a pic, with its own size cap (`FADE_VIDEO_MAX_KB`, 4 MB). The format number tells the server a video from a pic, which the size would show anyway. Pinned vectors: `tests/vectors/media4.json`.

View-once is a server promise, not a cryptographic one. The recipient's screen shows the decrypted photo for ten seconds, and nothing stops a screenshot or a second camera.

## Group chats

Group messages and pics are **end-to-end encrypted** (format 3). The full design, with the reasons and the threat model, is in [group-encryption.md](implementation/group-encryption.md). In short:

```
each message:
  K        = 32 random bytes, used once
  content  = AES-GCM(K, the text or pic, "napsack/v3/group/<group>/<sender>/<message id>/<text|pic>")
  for each member m (the sender too, for their other devices):
    wrap[m] = AES-GCM(group wrap key(sender, m), K,
                      "napsack/v3/group-key/<group>/<sender>/<m>/<message id>/<SHA-256 of content>/<SHA-256 of the member list>")

group wrap key(a, b) = HKDF(ECDH(a, b), salt "napsack/v1/pair/<lower id>/<higher id>", info "napsack/v3/group-keys")
```

The server stores the content once and one 60-byte wrap per member, and gives each member only their own. A wrap only the sender and that member could have made proves who sent the message, so neither the server nor another member can forge one. Someone who joins can't read what came before; someone who leaves or is removed isn't wrapped for again. Members' keys are pinned like friends' keys: if one changes, the app won't send to that group.

**Not encrypted:** the group's **name** and **picture** (the server can see them, and each group says so), **reactions** in groups (which emoji), and messages and pics sent before the group switched, which stay `format` 0 and readable by the server. The switch happened by itself with the first encrypted message, shown in the chat as "Messages and pics here are end-to-end encrypted from now on". The group's picture, being visible to the server anyway, is rebuilt by the server like profile pictures.

History starts when you join: the server sends each group message, and any later update to it (a reaction, "opened by"), only to members whose history includes it.

## Profiles

You can set a display name and a profile picture. Your friends see them; nobody else does, and the server enforces that. You can also give any friend a nickname, which only you see. The app shows a friend by your nickname for them, else their display name, else their username.

These are **not** end-to-end encrypted: the server stores names and pictures, the way it stores usernames. Profile pictures are rebuilt by the server like every image it handles (decoded, size-checked, re-encoded), and every name and picture you've ever set is kept.

Usernames stay the identity. A display name could be anything, including someone else's name, so the app shows `@username` wherever a name differs from it, and safety codes and key warnings always use the username.

## Replies and reactions

Texts are written in **format 2** now: instead of the bare text, the browser encrypts a small JSON object, `{"t": "the text", "re": 41}`, where `re` (only when replying) is the message being replied to. So the server can't see which message a reply quotes. Readers ignore keys they don't know, so later additions (mentions, edits) won't need another format. The associated string says `v2` (`napsack/v2/text/7/3`). Format 1 texts stay readable.

A reaction is one of six emoji, encrypted with the chat key and the associated string `napsack/v2/reaction/<sender>/<recipient>/<message id>`. Binding the message id in means the server can't move a reaction onto a different message. The server stores that a reaction happened and on which message; the newest one per person wins, and taking it back stores an empty one. Pinned vectors: `tests/vectors/texts2.json`.

In group chats, a reply's link is sealed inside the encrypted text, as in direct chats. Reactions are the exception: in a group the server can see which emoji someone used (sealing them like messages is planned).

## Notifications

napsack can be installed as an app (on iPhone: Share, then Add to Home Screen) and send notifications with the standard Web Push protocol. The browser hands napsack an address at its push service (Apple, Google, Mozilla or Microsoft) and a public key. For each notification, the server encrypts a small message to that key (RFC 8291) and signs the request (VAPID, RFC 8292), so the push service only relays ciphertext.

A notification says **who, never what**: "Ana: New message", "Sent you a pic", "Ben wants to be friends". The server couldn't say more about a direct message if it wanted to; group notifications follow the same rule. There's no notification while napsack is on your screen, and signing out stops that device's notifications.

## Typing and "active now"

While you type, your friend sees "Ana is typing…"; it travels over the live connection and is never stored. A green dot means a friend has napsack open, and "Active 5m ago" says when they last did. It's mutual and friends-only: turn off "Show friends when I'm active or typing" in your profile and nobody sees yours, and you stop seeing theirs.

## Team Napsack

napsack's own account, **Team Napsack**, can write to anyone for occasions: a birthday wish, a holiday, a heads-up that a friend's birthday is today. Its messages are encrypted to you exactly as a friend's are, and your app decrypts them the same way. The difference is who writes them: the server holds Team Napsack's key and writes these itself, so it knows what they say. It still can't read anything else. Its chat is read-only, and it never signs in or becomes anyone's friend. [team-napsack.md](implementation/team-napsack.md)

## Invite links

You can invite someone with a link or a QR code (`/i/<token>`). Someone new signs up with it without the invite code and becomes your friend at once; someone who already has an account adds you in one tap. A link works 10 times and for 7 days, and you can turn it off. The server stores only a hash of the token, so the database alone can't be used to make a working link.

## The friend map

The Friends sheet can draw your **friend map**: you in the middle, your friends around you, a line between two friends who are friends with each other, and a **?** for each person a friend knows that you don't. Friends who know each other gather into groups, outlined and lettered.

The server decides what's on it, and shows you only what you already know plus anonymous structure: a **?** has no id, name, or picture, and the ?s come in a shuffled order, so nothing hints at who one is. You can only ever get your own map. With the **Group chats** switch on, your group chats appear too, lined to you and the friends in them; members who aren't your friends are only counted, so a chat never gives away who a ? is. Details: [friend-graph.md](implementation/friend-graph.md).

## Safety codes and changed keys

There's one attack the scheme above can't stop by itself: a dishonest server could hand you its own public key and claim it's your friend's. You'd then be encrypting to the server. napsack defends against this in two ways.

**Pinning.** The first time your browser sees a friend's public key, it remembers it. If the server later serves a different key, the chat shows a warning and refuses to send anything until you decide.

Keys only change when an admin resets an account. When that happened, the warning says so, but that's the server's claim, so you get two choices:
- **Compare safety codes** with your friend in person or on a call, then tap *The codes match*. This is the safe way.
- **Accept without checking** (two taps), if you'd rather trust it.

Either way, your browser keeps the old key locally, so you can still read everything from before. Old keys only ever come from your own device, never from the server: a server that could hand you an "old key" could also forge old messages under it.

**Safety codes.** Tap *Encrypted* in any chat to see a code like `48663 30443 09844 / 47350 63988 34781`. Both of you see the same code, computed from both public keys (SHA-256 of the two keys, sorted, cut into six five-digit groups). Compare it in person or over a call. If it matches, nobody is in the middle, and pinning keeps it that way.

## Limits

- **A forgotten password and a lost recovery key mean unreadable history.** The key can only be unlocked with one of them. An admin can give the account back, but nobody, including whoever runs the server, can recover the old messages.
- **A weak password is the weakest link.** Someone who stole the database could try passwords offline against the wrapped key. The 600,000-round stretch makes each guess slow, but a short or common password will still fall. Use a long one.
- **The server delivers the app.** The web app's JavaScript comes from the same server. A compromised server could ship code that leaks keys as you type. Every browser-based encrypted app shares this problem. A native app, whose code is signed and reviewed before install, closes it.
- **No forward secrecy.** Each pair of friends uses one long-lived key. If a password and old ciphertext both leaked, past messages could be read. Signal-style ratcheting fixes this at real complexity.
- **Metadata is visible.** Who talks to whom, when, and how much is what the server needs to deliver messages. It's also what the System page shows, as counts.

## Roles and the System page

Everyone is a **User**. Two roles see more of how napsack is doing, never more of anyone's private data, through the **System** page (the gear button). The server checks the role on every request and answers "not found" to anyone below it. Details: [roles.md](implementation/roles.md).

- **PowerUser**, for friends curious about how napsack runs: the overview's counts (without the list of users), the Metrics tab without cost, and the friend graph with everyone they aren't friends with anonymous (no id, no username, an alias only they see). They can make a friend a PowerUser; only an Admin can take it away.
- **Admin**: everything, including the users table, reset codes for people locked out, cost, the health monitor's incidents, and the server's logs. Admins are a list in the server's settings (an SSM parameter in production), never something the app itself can grant.

Nothing on the System page shows message content: the server doesn't have any. Logs record events and ids (sign-ins, friendships, errors), never what anyone wrote, and the server redacts anything that looks like content or a secret.

## Keeping it running

- **Backups.** The database is copied to S3 every hour and kept forever; the server can add backups but can't read, change, or delete them. The data disk is also snapshotted daily, kept 30 days. Nothing in the database is ever deleted in the first place: when something ends (a friendship, a session), it's marked, not removed. [backups.md](operations/backups.md)
- **The health monitor.** Every 5 minutes, a small program outside the server (an AWS Lambda) asks `https://napsack.io/api/health` whether the database answers and the disk has room. Two failures in a row open an incident, and it tries to fix things one gentle step at a time: restart the app, reboot, then move the server to new hardware. If none of that works, it asks for a person. Every step and its evidence is written down, and Admins see the last week of incidents on the Metrics tab. [health-monitor.md](implementation/health-monitor.md)
- **Metrics.** The Metrics tab shows how the machine and the server are doing (CPU, memory, disk, response times, errors) and says plainly whether anything needs attention. [metrics.md](implementation/metrics.md)
- **Staging.** A separate copy at staging.napsack.io, with no real accounts and no access to production's data, is where changes get tried on a real deployment and load tested. On the same size machine it handled 400 people online and 718 texts a second. [staging.md](operations/staging.md)

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
