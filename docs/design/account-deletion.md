# Deleting your own account

Status: decided (Nate, 2026-11-03), being built ([plan.md](../management/plan.md), F22).

Anyone can delete their own account, from the web app or the iOS app, and everything of theirs goes. It's the one exception to Rule 1 (user data is never deleted), and only the person themselves can do it. Admins keep turning accounts off ([admin-users.md](../implementation/admin-users.md)), which deletes nothing.

The App Store requires it (Guideline 5.1.1(v), read 2026-11-03): "Offer to delete the entire account record, along with associated personal data… only offering to temporarily deactivate or disable an account is insufficient." A confirmation step is fine; if deletion takes time, say how long.

## What goes

Everything that is theirs or about them, in one transaction (`deletion.rs`):

- **The account:** username, past usernames, keys (public, wrapped private, recovery), the password check, credential history, reset codes, sessions, notification subscriptions (web and iPhone), roles, and Admin records about them (turn-offs, actions taken on them).
- **The profile:** display name, picture, birthday, and every nickname they gave or were given.
- **Friends:** friendships, friend requests, friend history (`friend_events`), their add-a-friend link and its uses, and everyone's favorite, hidden, and muted marks for their chat.
- **Direct chats:** every message to or from them, with its reactions and edits, Team Napsack's messages to them, and the files of pics and videos not yet opened. Their friends lose the chat; nothing else of theirs changes.
- **Groups** (Nate: wipe them): every message, pic, reaction, and edit they sent, their copies of group keys, which pics they opened, and their memberships. Membership events they made go too. A group they owned passes to the member who joined earliest, as when an owner leaves. The group's name and picture stay: they're the group's, and the others still use them.

## What stays

- **A hollow row in `users`:** the id and nothing else (no username, keys, or dates: placeholders that match nothing). Other people's records point at it: who created a group, who set its picture, who made an announcement or took an Admin action. SQLite can't make those columns nullable without rebuilding tables, and the migrations only add (Rule 1). A row with nothing in it isn't the person's data; it's how the database says "someone who's gone". Clients show it as "Deleted account" where it comes up at all.
- **`deleted_accounts`:** the id, when, and for 30 days a keyed hash of the username (below). After 30 days only the id and date remain.

## Confirmation

Robust (Nate), and the same on every client:

1. Settings › Delete account says what goes, plainly: messages in every chat and group, pics, friends, the profile, and that it can't be undone, ever, by anyone.
2. Type your password: the client derives the auth key and the server checks it, as for a password change (failed tries count against the sign-in limit).
3. Type your username.
4. A last button, "Delete my account forever", red, after the two fields are right.

Then it's immediate: no waiting period. The server ends every session and socket, friends' lists refresh, and the client signs out locally (everything of the account off the device) and says it's done.

## Backups (Nate: 30 days, then gone)

Backups were kept forever. Now database backups older than 30 days are deleted (the bucket's lifecycle; noncurrent versions too), and daily disk snapshots already last 30 days. So 30 days after a deletion, no copy remains anywhere. The privacy page says so.

A restore from a backup must not bring anyone back: each deletion also writes a marker (`deletions/<id>`, the id only) to the backups bucket, add-only like the backups, and the server re-applies any marked id it finds in its database when it starts. The markers outlive the backups they're needed for, and hold nothing but ids.

## The username (Nate: free after 30 days)

For 30 days no one can take it, so nobody can pose as the person their friends just lost. Held as an HMAC with a server key, not the name itself. After that the hash is cleared, and anyone can sign up with it.

## Rule 1, adjusted

- Migrations still only add. Application code still never deletes rows, with one exception: `deletion.rs`, run only by the person deleting themselves. `db::tests::code_never_deletes_rows` allows `DELETE FROM` in that file alone.
- A test seeds a person into every table and checks that after deletion nothing refers to them except the hollow row's references, and that a friend's own data is untouched. A new table that refers to users fails it until deletion handles it.
- Admins can't delete anyone, and Team Napsack can't be deleted.

## Every client

The web (desktop and phone) and the iOS app build the same confirmation. An Admin's System › Users shows deleted accounts as "Deleted" with no details, and they can't be turned back on.
