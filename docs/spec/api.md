# API

Every endpoint the web app (and the iOS app) uses. The server is the source of truth: routes are listed in `server/src/main.rs` (`fn router`), each handler next to the feature it belongs to. Every change follows the compatibility rules in [releasing.md](../operations/releasing.md): the API only grows.

All endpoints are under `/api`. Auth is `Authorization: Bearer <token>`, which works the same way for a mobile app. Errors look like `{"error": "human readable"}`. Native apps also send `X-Napsack-Client: ios/<version>+<build>`; see [releasing.md](../operations/releasing.md) for the compatibility rules every change has to follow.

| | |
|---|---|
| `GET  /config` | `{invite_required, snap_max_bytes, snap_ttl_hours, api_version, server_version, build, message_formats, min_client_versions, vapid_public_key, environment, started_at}` (no auth, never version-blocked). `environment` is null in production and names a non-production copy (`"staging"`): clients then mark every page and show the build (`server/static/env.js`). `started_at` is when the server started (unix seconds) |
| `POST /auth/register` | `{username, auth_key, public_key, wrapped_private_key, invite_code?}` → `{token, user, public_key, wrapped_private_key}` |
| `POST /auth/login` | `{username, auth_key}` → `{token, user, public_key, wrapped_private_key}` |
| `POST /auth/logout` | |
| `GET  /me` | `{id, username, is_admin, display_name, avatar_id, has_recovery_key, key_reset_at}` |
| `GET  /friends?tz=` | Chat list: `[{id, username, display_name, nickname, avatar_id, public_key, last_message, unread, favorite, hidden, birthday, streak, streak_expiring, muted, muted_until}]`, newest first. `tz`: minutes east of UTC, for counting days (default UTC). `streak`: days in a row you've both sent each other a pic (apps show it from 3); `streak_expiring`: it ends tonight unless you both send one. `nickname`, `favorite`, and `hidden` are yours alone; `birthday` is theirs as `"MM-DD"` |
| `PUT  /chats/{friend_id}/favorite` | `{on}`: keep this chat at the top of your list. Up to 10 favorites (direct and groups together); 400 past that |
| `PUT  /chats/{friend_id}/mute` · `PUT /groups/{id}/mute` | `{on, hours?}`: no notifications and no unread dot from that chat, for `hours` (1 to 8,760) or until turned off (no `hours`). Private. Lists carry `muted` and `muted_until` (null while muted means until turned off) |
| `PUT  /chats/{friend_id}/hidden` | `{on}`: hide (archive) the chat from your list, or show it again. Messages stay; a newer message, from either side, shows it again by itself |
| `DELETE /friends/{id}` | Unfriend |
| `GET  /users/{id}/profile` | Your own (`kind: "me"`: friends, your counts) or a friend's (`kind: "friend"`: what you share, mutual friends). Both have `birthday: {month, day, year}` or null; a friend's has `streak: {current, expiring, longest}`, yours `longest_streak`. Takes `?tz=` like `/friends`. 404 for anyone else |
| `GET  /friends/requests` | `{incoming: [...], outgoing: [...]}` |
| `POST /friends/requests` | `{username}`. Auto-accepts if they already asked you |
| `POST /friends/requests/{id}/accept` | |
| `DELETE /friends/requests/{id}` | Decline or cancel |
| `GET  /chats/{friend}/messages?before=&limit=` | Oldest first |
| `POST /chats/{friend}/messages` | `{ciphertext, format?, client_id?}`: base64 of IV ‖ AES-GCM output; `format` defaults to 1. `client_id` (8–64 base64/base64url characters, picked by the app) makes a retry safe: sending again with the same one returns the message already stored, not a copy. Messages carry their `client_id` |
| `POST /chats/{friend}/read` | Marks their texts as read |
| `POST /chats/{friend}/snaps?format=2&client_id=` | Encrypted caption + image (IV ‖ AES-GCM output). Format 1 (image only) is still accepted. `client_id` as for texts: a retried upload returns the pic already stored |
| `GET  /snaps/{id}` | The encrypted bytes (recipient only). Fetching doesn't open it, so a dropped download can be fetched again |
| `POST /snaps/{id}/opened` | The recipient's app has shown the pic: now it's opened and discarded (a repeat is fine). A pic fetched but never confirmed counts as opened 15 minutes after the first fetch |
| `GET  /groups` | Your groups: `[{id, name, role, member_count, last_message, unread, favorite, encrypted: false}]` (`encrypted` predates format 3 and stays false; messages say their own `format`). Also `muted`, `muted_until`. `GET /groups/{id}` members include `public_key`, for encrypting to them |
| `PUT  /groups/{id}/favorite` | `{on}`: a favorite group (counts toward the 10). Groups aren't hidden; you leave them |
| `POST /groups` | `{name, member_ids}` (your friends) → group with members; you're the owner |
| `GET  /groups/{id}` · `PATCH /groups/{id}` | Details and current members · rename (`{name}`), any member |
| `POST /groups/{id}/members` | `{user_id}`: add one of your friends, any member |
| `DELETE /groups/{id}/members/{user_id}` | Leave (yourself) or remove (owner only). Marks the membership ended; nothing is deleted |
| `GET  /groups/{id}/messages?before=&limit=` · `POST` | History from when you joined, oldest first · send `{format: 3, content, client_id, recipients, wraps}` (end-to-end encrypted; [group-encryption.md](../implementation/group-encryption.md)): `recipients` must be exactly the current members, you included (409 if the group changed: refetch and seal again), one 60-byte `wraps[member id]` each, `client_id` 16 random bytes (sending the same one again, after a dropped response, returns the message already stored). Format 3 messages come back with `content`, `client_id`, `recipients`, `sender_public_key`, and only your own `key`; `body` is empty. `{text, reply_to?}` (plain, `format` 0) still works for old clients |
| `POST /groups/{id}/read` | Marks the group read; tells the other members (`group_read`) if it moved |
| `GET /groups/{id}/reads` | `[{user_id, username, last_read_id}]` for current members, for "Seen by" |
| `POST /auth/unlock` | `{auth_key}` with a session: returns your password-wrapped key, so the client can wrap it again |
| `POST /me/password` | `{auth_key, new_auth_key, new_wrapped_private_key}`: same key, new password; other sessions end |
| `PUT  /me/recovery` | `{auth_key, recovery_auth_key, recovery_wrapped_key}`: set or replace your recovery key (needs the password) |
| `GET  /me/security` | `{recovery_set_at, key_reset_at, active_sessions}` |
| `POST /me/sessions/end-others` | Sign out every other device; their live connections close |
| `POST /auth/recover/start` · `/finish` | Forgot password, with the recovery key: get the recovery copy of your key, then set a new password. Rate-limited like sign-in |
| `POST /auth/reset` | `{username, code, new_auth_key, public_key, wrapped_private_key}`: an admin's one-time code; a new key pair, no history |
| `POST /admin/users/{id}/reset-code` | Admins: issue a reset code (shown once, 24 hours, any older one stops working) |
| `POST /invites` · `GET /invites` | Make an invite link (`{path: "/i/<token>"}`, shown once; 10 uses, 7 days) · mine, with who joined |
| `POST /invites/{id}/revoke` | Turn a link off |
| `GET  /invites/lookup/{token}` · `POST /invites/accept` | Who made a link (no sign-in needed) · signed in: become friends with them. `POST /auth/register` also takes `invite_token` in place of `invite_code` |
| `PUT  /me/settings` | `{share_activity}`: friends see when you're active or typing (mutual) |
| `POST /push/subscriptions` · `/remove` | This browser's `PushSubscription.toJSON()`, tied to the session · stop. Only known push services are accepted |
| `PUT  /chats/{friend}/messages/{id}/reaction` | `{ciphertext, format: 2}`, encrypted emoji; null takes it back. Comes back as `message_updated` |
| `PUT  /groups/{id}/messages/{id}/reaction` | `{emoji}` from the fixed set; null takes it back |
| `PUT  /me/name` | `{name}`: your display name, seen by friends. Empty clears it |
| `POST /me/avatar` · `DELETE /me/avatar` | Set your profile picture (raw small image; re-encoded) · remove it. Every picture is kept |
| `GET  /users/{id}/avatar/{avatar_id}` | A profile picture: yours or a friend's, current one only |
| `PUT  /me/birthday` | `{month, day, year?}`: your birthday, for friends (profile, and `birthday: "MM-DD"` in their `/friends`). Real dates only; the year is optional (1900 to this year). `{}` clears it |
| `PUT  /friends/{id}/nickname` | `{name}`: a nickname for a friend that only you see. Empty clears it |
| `POST /groups/{id}/pics` · `GET /groups/{id}/pics/{pic_id}` | Send a pic: `?format=3` with the sealed bytes as the body and `X-Napsack-Keys: {client_id, recipients, wraps}` (the caption is sealed inside); or (old clients) a raw JPEG/PNG/WebP body, re-encoded by the server, with `?caption=`; a resend with the same `client_id` returns the pic already stored · fetch it (members, not the sender): format 3 comes back as the sealed bytes (`application/octet-stream`); old ones as an image with the caption in `X-Napsack-Caption`. Fetching doesn't open it |
| `POST /groups/{id}/pics/{pic_id}/opened` | This member's app has shown the pic: it counts as opened for them (a repeat is fine; unconfirmed fetches count after 15 minutes). Gone once everyone has opened it, or after 30 days |
| `POST /groups/{id}/avatar` · `GET /groups/{id}/avatar/{avatar_id}` | Set the group picture (any member; re-encoded) · fetch it, members only. Every past picture is kept |
| `GET  /admin/stats` | Counts for the System overview. PowerUsers and Admins ([roles.md](../implementation/roles.md)); 404 for anyone else. `users.list` (the users table) is `null` except for Admins |
| `GET  /admin/roles` · `POST /admin/roles/{user_id}` · `DELETE /admin/roles/{user_id}` · `POST /admin/roles/reload` | Roles ([roles.md](../implementation/roles.md)): who's what (everyone for Admins; for PowerUsers, themselves and their friends) · make someone a PowerUser (Admins: anyone; PowerUsers: friends) · take it away (Admins) · reload the admin list from settings (Admins) |
| `GET  /admin/logs?level=&q=&source=&before=&after=&limit=` | Recent log entries, newest first. Admins only. `source`: `server` or `client` |
| `GET  /graph` | Your friend map ([friend-graph.md](../implementation/friend-graph.md)): `{nodes: [{key, user_id?, kind: self\|friend\|unknown}], edges: [[key, key]]}`. You, your friends, the friendships among them, and one `?n` per person a friend knows that you don't: no id, no name, shuffled. Only ever your own. `?chats=1` adds your group chats: `{key: "c<id>", kind: "chat", name, group_id, size, others}`, lined to you and the friends in them; members who aren't your friends are only counted (`others`), never lined, so a `?` is never tied to a chat |
| `GET  /admin/graph?all=1` · `?users=3,7&depth=1\|2` | The System graph, PowerUsers and Admins. For PowerUsers (`anonymous: true`), anyone they aren't friends with has no `user_id` or `username`: an alias `key` (per viewer) and an `alias` label, and is chosen by that key; `people` lists only them and their friends. Otherwise: everyone, or chosen people (you by default; at most 50) with their friends or friends of friends. Nodes carry `username`; `kind` is `seed` (chosen) or `member`. Plus `people` (every account's id and username) for the picker. `&chats=1` adds group chats with two or more people on the graph (`kind: "chat"`, `size`, `others`), lined to them; `name` and `group_id` only for chats the viewer is in, and for a PowerUser the others have an alias `key` (`x…`) |
| `GET  /admin/incidents` | The health monitor's incidents from the last 7 days (Admins only; [health-monitor.md](../implementation/health-monitor.md)): `{available, window_days, incidents: [{id, opened_at, closed_at, status: open\|recovered\|needs_human, state: open\|needs_human\|recovered\|resolved, resolved: {at, by}?, steps, timeline: [{at, note, healthy, error, instance, action: {step, name, result}}]}], error?}`. `available: false` off AWS. Read from S3, cached a minute; the serial console is left out |
| `POST /admin/incidents/{id}/resolve` | Admins only. Marks an incident resolved: writes `resolutions/<id>.json` beside the monitor's record (which is never changed). `id` must look like `20261023T171000Z` (400 otherwise); 404 if there's no such incident; marking it again returns the first resolution |
| `GET  /admin/metrics?hours=` | The Metrics tab, PowerUsers and Admins; `estimate`, `billing` and `aws_problems` only for Admins (`cost_visible`); `billing_read` is false on a non-production copy, which never reads the bill (it's production's). `hours` 1 (10-second readings) up to the retention window (minutes, merged to at most 720 points). `{generated_at, hours, retention_hours, interval_secs, on_aws, aws_problems, billing, hosts: [{host, info, status: ok\|watch\|red, reasons, latest, series: [{t, v: {figure: [min, avg, max]}}], credits, estimate}]}`. Figures: `cpu`, `steal`, `iowait`, `mem` (%), `mem_used`, `swap_used`, `load1`, `disk_<name>` (%), `disk_<name>_used`, `reads_/writes_/read_bytes_/write_bytes_<name>` (per second), `net_in`/`net_out` (bytes/s), `app_cpu` (% of the machine), `app_mem`, `app_threads`, `app_files`, `requests`/`errors` (per minute), `p50`/`p95`/`p99` (ms), `online`, `sockets`, `db_bytes` |
| `POST /logs` | Client diagnostics: `{entries: [{level, message, fields}]}`, up to 50 per request, rate-limited. Never send content; content-like fields are redacted |
| `GET  /ws` | WebSocket. First frame: `{"type":"auth","token":"..."}` |

Clients send `{"type":"visibility","visible":bool}` (no push while on screen), `{"type":"typing","to"|"group":id}`, and `{"type":"ping"}` (answered at once with `{"type":"pong"}`, so the app can tell a dead connection; the web app pings every 25 seconds while on screen) over the socket. WebSocket events: `typing {from, group_id}`, `presence {user_id, active, last_seen_at}`, `ready`, `message`, `message_updated`, `read {by, at}`, `friends_changed`, `group_message {group_id, message}` (new or updated; only to members who were in the group when it was sent), `groups_changed {group_id}`, `group_read {group_id, user_id, last_read_id}`. On every `ready` the client refetches its state, so missed events while disconnected don't matter.

Messages include `format`, the encryption scheme, so clients know how to read them: texts and pics are written as format 2 and format 1 stays readable; group messages are format 0 (not encrypted). The schemes are in [how-napsack-works.md](../how-napsack-works.md).
