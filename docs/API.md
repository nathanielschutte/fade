# API

Every endpoint the web app (and the iOS app) uses. The server is the source of truth: routes are listed in `server/src/main.rs` (`fn router`), each handler next to the feature it belongs to. Every change follows the compatibility rules in [RELEASING.md](RELEASING.md): the API only grows.

All endpoints are under `/api`. Auth is `Authorization: Bearer <token>`, which works the same way for a mobile app. Errors look like `{"error": "human readable"}`. Native apps also send `X-Napsack-Client: ios/<version>+<build>`; see [RELEASING.md](RELEASING.md) for the compatibility rules every change has to follow.

| | |
|---|---|
| `GET  /config` | `{invite_required, snap_max_bytes, snap_ttl_hours, api_version, server_version, build, message_formats, min_client_versions, vapid_public_key}` (no auth, never version-blocked) |
| `POST /auth/register` | `{username, auth_key, public_key, wrapped_private_key, invite_code?}` → `{token, user, public_key, wrapped_private_key}` |
| `POST /auth/login` | `{username, auth_key}` → `{token, user, public_key, wrapped_private_key}` |
| `POST /auth/logout` | |
| `GET  /me` | `{id, username, is_admin, display_name, avatar_id, has_recovery_key, key_reset_at}` |
| `GET  /friends` | Chat list: `[{id, username, display_name, nickname, avatar_id, public_key, last_message, unread}]`, newest first. `nickname` is yours for them |
| `DELETE /friends/{id}` | Unfriend |
| `GET  /users/{id}/profile` | Your own (`kind: "me"`: friends, your counts) or a friend's (`kind: "friend"`: what you share, mutual friends). 404 for anyone else |
| `GET  /friends/requests` | `{incoming: [...], outgoing: [...]}` |
| `POST /friends/requests` | `{username}`. Auto-accepts if they already asked you |
| `POST /friends/requests/{id}/accept` | |
| `DELETE /friends/requests/{id}` | Decline or cancel |
| `GET  /chats/{friend}/messages?before=&limit=` | Oldest first |
| `POST /chats/{friend}/messages` | `{ciphertext, format?}`: base64 of IV ‖ AES-GCM output; `format` defaults to 1 |
| `POST /chats/{friend}/read` | Marks their texts as read |
| `POST /chats/{friend}/snaps?format=2` | Encrypted caption + image (IV ‖ AES-GCM output). Format 1 (image only) is still accepted |
| `GET  /snaps/{id}` | View once; returns the encrypted bytes |
| `GET  /groups` | Your groups: `[{id, name, role, member_count, last_message, unread, encrypted: false}]` |
| `POST /groups` | `{name, member_ids}` (your friends) → group with members; you're the owner |
| `GET  /groups/{id}` · `PATCH /groups/{id}` | Details and current members · rename (`{name}`), any member |
| `POST /groups/{id}/members` | `{user_id}`: add one of your friends, any member |
| `DELETE /groups/{id}/members/{user_id}` | Leave (yourself) or remove (owner only). Marks the membership ended; nothing is deleted |
| `GET  /groups/{id}/messages?before=&limit=` · `POST` | History from when you joined, oldest first · send `{text, reply_to?}` (plain text, `format` 0) |
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
| `PUT  /friends/{id}/nickname` | `{name}`: a nickname for a friend that only you see. Empty clears it |
| `POST /groups/{id}/pics` · `GET /groups/{id}/pics/{pic_id}` | Send a pic (raw JPEG/PNG/WebP body; re-encoded by the server; optional `?caption=`, one line, 200 characters) · open it, once per member, not the sender; the caption comes back in `X-Napsack-Caption`, percent-encoded. Gone once everyone has opened it, or after 30 days |
| `POST /groups/{id}/avatar` · `GET /groups/{id}/avatar/{avatar_id}` | Set the group picture (any member; re-encoded) · fetch it, members only. Every past picture is kept |
| `GET  /admin/stats` | Counts for the admin panel; 404 unless you're in `FADE_ADMINS` |
| `GET  /admin/logs?level=&q=&source=&before=&after=&limit=` | Recent log entries, newest first; same access rule. `source`: `server` or `client` |
| `POST /logs` | Client diagnostics: `{entries: [{level, message, fields}]}`, up to 50 per request, rate-limited. Never send content; content-like fields are redacted |
| `GET  /ws` | WebSocket. First frame: `{"type":"auth","token":"..."}` |

Clients send `{"type":"visibility","visible":bool}` (no push while on screen) and `{"type":"typing","to"|"group":id}` over the socket. WebSocket events: `typing {from, group_id}`, `presence {user_id, active, last_seen_at}`, `ready`, `message`, `message_updated`, `read {by, at}`, `friends_changed`, `group_message {group_id, message}`, `groups_changed {group_id}`, `group_read {group_id, user_id, last_read_id}`. On every `ready` the client refetches its state, so missed events while disconnected don't matter.

Messages include `format`, the encryption scheme, so clients know how to read them: texts and pics are written as format 2 and format 1 stays readable; group messages are format 0 (not encrypted). The schemes are in [how-napsack-works.md](how-napsack-works.md).
