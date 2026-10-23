# Group chats, end-to-end encrypted (design)

Status: **Phase 1 built (0.21.0).** Written 2026-10-21 for F17 in [plan.md](../management/plan.md); Nate's decisions are at the end, and what's built (and what isn't yet) is under [Built](#built). Read [how-napsack-works.md](../how-napsack-works.md) first: this builds directly on the direct-chat scheme.

Today group chats are the one part of napsack the server can read (`format` 0). This document is how they stop being that, and how we'll know it's done right.

## Goals

1. **The server can't read group messages, pics, captions, or reactions**, the same promise direct chats make. It still delivers them, so it still sees who is in which group, who sent something, when, and roughly how big it was (as for direct chats).
2. **Only the people in the group when a message is sent can read it.** Someone who joins later can't read what came before (that's already the rule: history starts when you join). Someone who leaves or is removed can't read anything sent after.
3. **A message says who really sent it.** Neither the server nor another member can make a message appear to come from someone else.
4. **Nothing new to manage for people.** No group passwords, no "verify the group" step. It works on every device someone is signed in on, like direct chats.
5. **Old messages stay readable** (Rule 1). Plaintext group messages from before stay `format` 0 forever and are shown as "sent before end-to-end encryption".

## Non-goals (for this version)

- **Forward secrecy.** Like direct chats, keys are long-lived: someone who steals your private key later could read your past group messages. Fixing that for both is a separate, larger project (ratcheting, as Signal does).
- **Hiding metadata.** The group's name, picture, member list, and timing stay visible to the server (see [What the server still knows](#what-the-server-still-knows)).
- **Huge groups.** Groups are capped at 32 people. The design leans on that.

## Threat model

| Who | Can | Must not be able to |
|---|---|---|
| The napsack server (or someone who took it over) | Store, delay, drop, and reorder messages; see metadata; serve public keys; manage the member list | Read anything; forge a message from a member; show a message to someone it wasn't sent to; quietly add a listener (see Phase 2) |
| A group member | Read everything sent while they're in the group | Read messages from before they joined or after they left; send a message that looks like it came from another member |
| A former member | Keep what they already saw | Read anything sent after they left |
| Someone with a stolen database backup | Everything the server has | Read anything |

## Options considered

**A. One shared group key per "epoch"** (what the plan first sketched). A random key for the group, handed to each member wrapped with their pair key, replaced whenever someone leaves. Messages are encrypted once with it.
- Every member holds the same key, so **any member can forge a message from any other member**: the sender id in the associated data proves nothing among people who all have the key. Fixing that needs signing keys, which napsack accounts don't have (they have one ECDH key each).
- Someone has to be online to make and hand out the new key when a member leaves or is removed; until then, messages are either blocked or sent with an old key the leaver still has. Races between two members changing the group at once need careful rules.
- It pays off with hundreds of members. We cap at 32.

**B. Sender keys** (Signal's groups). Each member has their own sending key per group, handed to the others pairwise and replaced on membership changes. Better than A for sender authenticity (with signatures), but it has all of A's distribution and rotation machinery, per member.

**C. MLS** (RFC 9420, the IETF standard). Tree-based group keys with forward secrecy and recovery after compromise. The right answer for large groups, but there's no small, audited browser library for it (OpenMLS would mean WebAssembly), and it's a big jump in complexity for a 32-person cap.

**D. Per-message key, wrapped for each member (chosen).** Each message is encrypted once with a fresh random key; that key is wrapped separately for each member with the key that sender already shares with them (the pair key from direct chats, under a separate label).
- **Sender authenticity for free.** Only the sender and that recipient can make a wrap under their pair key, so a wrap that opens proves who sent it. Another member can't forge one.
- **No group state to keep in sync.** Leaving or being removed takes effect on the very next message, because the sender simply doesn't wrap for them. Nobody has to come online to rotate anything; there are no epochs and no races.
- **Uses only what's already built and tested:** ECDH pair keys, HKDF, AES-256-GCM, the same envelope formats as direct chats. Nothing new for the iOS app to get right beyond what direct chats already need.
- **Cost:** up to 32 wraps of 60 bytes each per message (about 2 KB at the largest), and 32 ECDH computations the first time a sender writes to a group (each pair key is computed once per session and cached, as today). Pics are encrypted once; only the 32-byte key is wrapped per member.

D is what the group sizes we have call for. If groups ever grow past ~100 people, MLS is the upgrade, and it would be a new `format`.

## The scheme (format 3)

Notation: `‖` is concatenation, `b64` is standard base64, ids are decimal. Every AES-GCM use has a fresh 12-byte random IV prepended to its output, exactly as direct chats do (`seal`/`open` in `shared/crypto/crypto.js`).

**Group wrap key** (one per pair of people, the same on both sides, cached):

```
ECDH(my private key, their public key)
└─ HKDF-SHA-256 · salt "napsack/v1/pair/<lower id>/<higher id>" · info "napsack/v3/group-keys"
   └─ group wrap key (AES-256-GCM)
```

Same ECDH secret and salt as the direct chat key, different `info`, so the two keys are independent: nothing encrypted for a direct chat can be passed off as a group key wrap or the other way round. The sender also wraps for **themselves** (ECDH with their own public key is well defined), so their other devices can read what they sent.

**Sending.** Sender `S` writes to group `G`. The sender's app knows the current members `M` (sorted ids, `S` included).

```
K      = 32 random bytes                      message key, used once
mid    = 16 random bytes                      message id chosen by the sender
roster = SHA-256( "<id>,<id>,…" of M )        who the sender meant it for
body   = packText(text, replyTo)  or  packPic(photo, caption)   (the format 2 envelopes)

content   = seal(K, body, "napsack/v3/group/<G>/<S>/<b64(mid)>/<text|pic>")
digest    = SHA-256(content)
for each member r in M:
  wrap[r] = seal(groupWrapKey(S, r), K,
                 "napsack/v3/group-key/<G>/<S>/<r>/<b64(mid)>/<b64(digest)>/<b64(roster)>")
```

The server stores `content` once and `wrap[r]` for each member.

**Reading.** Member `r` gets `content`, their own `wrap[r]`, the sender id, `mid`, and the member list `M` the sender used. They recompute `digest` and `roster`, open their wrap with `groupWrapKey(S, r)`, then open `content` with `K`.

**Why each piece is there:**
- `digest` in the wrap's associated data ties the key to this exact content. A member who knows `K` can't pair it with different content and pass it off as `S`'s, because they can't make `S`'s wrap for anyone else.
- `G`, `S`, `r` in the associated data stop the server from moving a message to another group, relabeling its sender, or giving one member's wrap to another.
- `mid` lets clients drop a replayed copy (the server re-sending an old message as new): each client keeps the `mid`s it has shown per group, and the message list rejects a second row with the same `(G, S, mid)`.
- `roster` commits to who the sender meant the message for. Every reader can check it against their own view of the group and show "Sent to 5 people" honestly (and, in Phase 2, warn if the sender's view and theirs disagree).
- The `text|pic` label stops a text from being shown as a pic or the other way round.

**Reactions** (format 3). The reaction emoji goes in as a tiny `body` with the same scheme (`kind` "reaction", associated data also carries the target message id). Replies go inside the text envelope, as in direct chats, so the server no longer sees which message a group text replies to.

**Group pics** (format 3). The packed pic (`packPic`, the format 2 envelope with caption) is the `content`, stored as a file like direct pics, view-once per member as today. The server can no longer see these images, so it can't rebuild them with `images::clean`. They're handled like direct pics: opaque bytes on the server, decoded only by each member's browser. Group *pictures* (the group's avatar) and profile pictures stay server-visible and keep going through `images::clean`.

## Server changes

All additive (Rule 1, and the API only grows):

- `group_messages`: `format` 3 rows. `body` holds `b64(content)` for texts (for pics, the file holds `content` as for direct pics). New nullable columns `client_id` (`b64(mid)`) and `recipients` (the sender's member list as JSON, needed by readers to recompute `roster`). Unique index on `(group_id, sender_id, client_id)` refuses replays at the source too.
- New table `group_message_keys (message_id, user_id, wrapped)`: one row per member per message. Append-only.
- `POST /groups/{id}/messages` with `format: 3` takes `{content, client_id, recipients, wraps: {user_id: wrapped}}`. The server checks that `recipients` is exactly the current members (sender included) and that there's a wrap for each. If not, **409 "The group changed; sending again"**: the app refetches the member list, re-encrypts, and retries once. That also means a buggy or old client can't leave someone out.
- `GET /groups/{id}/messages` returns each format 3 message with `content`, `client_id`, `recipients`, and **only the caller's own** `wrap`. Nobody can download others' wraps (they couldn't open them anyway, but there's no reason to hand them out).
- Size limits: `content` the same as group texts today (2,000 characters of text, so about 2.8 KB encrypted) and pics the same as direct pics; at most 32 wraps of exactly 60 bytes each. Anything else is 400.
- Text validation (`text.rs`) can't run on encrypted text any more; it moves into the clients, which render text with `textContent` anyway (as for direct chats).
- Push notifications already say only "New message in <group>" and keep doing that.

## Client changes (web, then iOS)

- `shared/crypto/crypto.js`: `groupWrapKey`, `encryptGroup`, `decryptGroup`, with **pinned vectors** in `tests/vectors/group3.json` (fixed keys, `K`, IVs, and `mid`, so every client must produce and accept the same bytes). `shared/crypto/vector-checks.js` runs them in Node, Chromium, and on the iPhone.
- **Keys for members who aren't my friends.** Groups can include friends of friends. Their public keys come from the server like everyone's and get pinned the first time they're seen (trust on first use), exactly like friends' keys; a change blocks sending to the group with the same warning and the same two choices. The member list gets a safety code per member, so anyone can be checked in person.
- The group notice changes from "not end-to-end encrypted" to the same **Encrypted** button direct chats have, opening the per-member safety codes.
- Messages the app can't open (not wrapped for me, failed check, unknown format) show as "Couldn't decrypt this message", and the failure is reported to the log viewer without content, as for direct chats.

## Rollout: readers before writers

Following [releasing.md](../operations/releasing.md#compatibility-rules):

1. **Readers.** Ship reading format 3 in the web app and in the first iOS build. Nothing sends it yet. Test vectors pass on both.
2. **Writers.** Once every client in use can read it (the web app updates on reload; iOS requires a minimum version through `min_client_versions` before step 2), the web app starts sending format 3. Each group shows one event, "Messages are end-to-end encrypted from here on", and its old messages are labeled "sent before end-to-end encryption".
3. **Enforce.** Later, the server refuses new format 0 group messages, so a stale client can't quietly fall back to plaintext.

## What the server still knows

The group's name and picture, who is in it and who added or removed whom, who sent each message and when, its size, whether it was a text, pic, or reaction, which message a reaction is on, read positions ("Seen by"), and pic opens. The same kinds of things it knows for direct chats, plus the group's name and picture. Encrypting group names and pictures is possible later (they'd be wrapped like messages) but makes notifications and the chat list harder; not in this version.

## Phase 2: an authenticated member list

The server manages membership, so a dishonest server could add a member nobody approved (an extra account it controls) and members' apps would dutifully wrap keys for it. The group would show "X added Y" (events come from the server, so that could be faked too), but nobody might look. Phase 2 closes this:

- Membership changes are sent **as format 3 messages** by the person making them ("added Y", "removed Z"), so they're authenticated like any message.
- Each app keeps its own roster: the members it was told about by an authenticated welcome when it joined, plus authenticated add and remove messages since. It only wraps for members on that roster, and it warns ("Someone was added without a message from a member") if the server's member list ever disagrees.

Phase 1 already protects content from a server that's only curious (reading the database or backups). Phase 2 protects against a server that's actively lying. It's worth doing, but after Phase 1 has run for a while.

## Testing plan

- **Vectors:** `tests/vectors/group3.json` (never regenerated), checked by every client.
- **Rust unit tests:** the send check (exact roster, one wrap each, sizes), replay refusal, wraps returned only to their owner, Rule 1 (nothing deleted; leaving keeps everything).
- **Smoke test:** a format 3 send and read through the API for three members, a non-member gets 404, a stale roster gets 409, a replayed `client_id` is refused, the database holds no plaintext.
- **Independent check:** a Python decryptor (like `tests/push_receiver.py` does for push) opens a stored format 3 message with a test member's private key, proving the bytes match the spec rather than just our own code.
- **Browser tests:** a three-person group sends texts, a reply, a reaction, and a pic; someone added later can't read earlier messages; someone removed can't read later ones; a member's changed key blocks sending; the database and the server log contain none of the plaintext.

## Decisions (Nate, 2026-10-21)

1. **Approach D**, a fresh key per message wrapped for each member: "Approach D should work, let's at least try it out."
2. **Existing groups switch automatically**, with no one asked: "dont ask anyone."
3. **Group names and pictures stay visible to the server**, but **the app has to say so**, pictures especially: "we should document and notify that pictures are still unencrypted. that's important." The group's info sheet and the encrypted notice both say that the group's name and picture aren't encrypted (the messages and pics inside are).
4. **Phase 2 (an authenticated member list) waits, and must not make inviting people harder.** "I want to make sure we take precedence on the importance of growing the app and making it approachable... dont implement user onboarding friction with stuff like this for right now." Any Phase 2 design has to keep adding a friend to a group (and invite links) as easy as today: no extra verification steps for people. Tracked in the plan, not built.
5. **Forward secrecy** stays out of scope for now.

## Built

Phase 1, in 0.21.0 (2026-10-22):

- `shared/crypto/crypto.js`: `groupWrapKey`, `encryptGroup`/`decryptGroup`, and text and pic helpers, exactly as specified above. Pinned vectors in `tests/vectors/group3.json`, opened by an independent Python implementation (`check_group3.py`) and by every client (`vector-checks.js`: Node, Chromium, the iPhone).
- Server: migration 0014; `groups::check_e2e` (exact member list, one 60-byte wrap each, 16-byte message id), `prepare_for` (each viewer gets only their own wrap, everywhere a message leaves the server, live events included), encrypted pics stored and served as opaque bytes. The group's first encrypted message adds the "encrypted from now on" event.
- Web app: every group text and pic is sealed; members' keys are pinned on first sight like friends' (a changed key blocks sending to that group); a 409 refetches the members and seals again once.
- **Readers and writers shipped together.** The web app is the only client and loads the new version on reload (the update banner asks); there's no iOS build in use yet, and the iOS app reads format 3 from its first build (the vectors run on the phone). A tab left open from before shows a format 3 message as an empty line until it reloads.

Not yet:

- **Group reactions** are still plain emoji the server can see (the group sheet says so). Next: seal them like messages (kind `reaction`, the target message id in the associated data).
- **Refusing format 0** for new group messages, once no old client could still be sending it (rollout step 3).
- **Phase 2** (an authenticated member list), on Nate's condition that it adds no friction to inviting people.
