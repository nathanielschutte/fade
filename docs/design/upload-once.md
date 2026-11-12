# Upload a pic once for several friends (design)

Status: **planned, not built** ([F31](../management/plan.md#f31-upload-a-pic-once-for-several-friends)). Nate (2026-11-12): on a bad connection, sending one video to three friends shouldn't mean uploading it three times. Plan it now, build it later, as its own piece of work.

## Today

A pic or video sent to several chats at once (Send to…, or "To Ben +" from a chat's camera) is made ready once on the phone: the photo is compressed, or the video encoded. Then each chat gets its own copy:

- **A friend** gets a copy sealed with the key for the two of you (format 6 for a photo, 4 for a video; [how-napsack-works.md](../how-napsack-works.md#formats-4-to-7-videos-and-photos)). The bytes differ for each friend, so each one is uploaded on its own.
- **A group** gets one copy for everyone in it (format 7 or 5, the format 3 scheme): the media is sealed once with a random key, and each member gets that key wrapped for them ([group-encryption.md](../implementation/group-encryption.md)). One upload, however many members.

Uploads go one at a time on the iPhone (from 2026-11-12) and on the web. So a 10-second video, about 3.8 MB at the quality decided in [video-quality.md](video-quality.md), sent to three friends is about 11.4 MB up. On a phone uploading at 1 Mbit/s that's about 90 seconds, where one upload would be 30.

## The idea

Send to several friends the way a group pic is sent: seal the media once with a random key, upload it once, and give each friend that key, sealed for them.

### Encryption

Two new direct formats, one for a photo and one for a video: the next two format numbers, never a change to 4 or 6 (CLAUDE.md, Encryption).

- **The media:** sealed once, as format 7 and 5 seal it: a fresh random content key, AES-256-GCM, with the same packing (`packMedia`: the type, the caption, where it sits).
- **The key, for each friend:** the content key sealed with the friend's pair key (the key for the two of you that texts use). It's bound to the sender, that friend, the client id, and the hash of the sealed media, so a key can't be moved to another file or another person.
- **Associated data for the media:** the sender and the client id, but no recipient, since one file serves every recipient. Who it's for is in each key's binding instead.
- **Pinned vectors:** one new vector file, generated once, with its own independent Python check (`tests/vectors/check_*.py`), run by the web's `vector-checks.js`, `swift test`, and the Android crypto tests.

What a recipient learns doesn't change. Each friend can open the media, as they can today. Each friend could also tell that the same file went to others: the server can see that too, since it stores one file for several messages. Today the server can already see that one sender sent pics of the same size to several friends within seconds. The doc for this format should say so plainly.

### Server

- **Endpoint:** `POST /api/snaps` with the sealed media as the body, and the recipients with each one's sealed key in a header, as group pics carry their wraps today (`X-Napsack-Keys`). Each recipient must be a friend. The usual caps apply: size, writes per address and session, and the disk.
- **Storage:** one file, and one message per friend, each a `snap` with its own `snap_state` and its own sealed key. A new nullable column links each message to its shared file, and the migration only adds (Rule 1).
- **View-once is per recipient, as now.** A friend opening it marks their message opened. The file is discarded once every message that uses it is opened or expired, as a group pic's file is discarded once everyone has seen it (`group_pics.rs`). Expiry is the same 30 days.
- **Fetching:** `GET /api/snaps/{id}` serves the shared file to each recipient, plus that recipient's sealed key (the message carries it, as group messages carry `key`). Checks are as today: only that message's recipient, and only while it's pending.
- **Retries:** one `client_id` for the whole send, so a retry after a dropped answer never stores anything twice.
- **Account deletion:** `deletion.rs` handles the new column and the shared files, and `deletion::tests` seeds them.
- Group pics don't change.

### Clients

- **Reading:** the web, the iPhone, and Android open the new formats (`loadSnap`, `Conversation.open`).
- **Sending:** a pic going to two or more friends uses the new formats. A single friend keeps format 6 or 4, which is one upload either way. Groups in the same send stay as they are.
- **Showing it:** each chat still shows the pic on its way and settles when the server answers. One upload settles every friend's chat at once. If it fails, it fails for all of them, and Try again sends it again for all.

## Rollout

New encryption means a new message format, and readers ship before writers ([releasing.md](../operations/releasing.md)):

1. **Readers:** the server (the endpoint, the storage, serving the key), with the web and the iPhone able to open the new formats, released together. Nothing sends them yet.
2. **Senders:** once the iPhone builds people have can read them (the server's minimum iOS version raised to the reading build) and Android reads them (or isn't out yet), the web and the iPhone start sending them.

## Effort and risks

- **The size of it:** a new format in `crypto.js`, Swift, and Kotlin, with vectors. A server endpoint, a migration, and changes to discarding files and to account deletion. Smoke and browser tests. Two releases.
- **What could go wrong:** a shared file is discarded too early (it must wait for the last recipient), or never (expiry has to cover it). Tests: three recipients, each opening in turn; one never opening; one deleting their account midway.
- **What it saves:** (number of friends − 1) uploads of the same size, for every pic sent to two or more friends. Nothing changes for one friend or for a group.

## Not part of this

- **Resuming an upload that broke halfway:** a different change, uploading in pieces.
- **A smaller video:** that changes the quality decided in [video-quality.md](video-quality.md).
