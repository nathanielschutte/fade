# System → Users

The Admins' tools for people's accounts, on the System page's **Users** tab: everyone at a glance, one account in detail, and what an Admin can do about it. Also announcements, and a record of every Admin action. Admins only ([roles.md](roles.md)): PowerUsers and Users get "not found" from every endpoint here, and don't see the tab.

Code: `server/src/admin_users.rs`, `server/src/announcements.rs`, migration `0018_admin.sql`; the page is `server/static/admin.js` (section "users"). Tests: `check_admin_users` and `check_roles` in `tests/smoke_test.py`, `tests/e2e/test_admin_users.py`.

## People

A table of every account: username, role, status (online, active, or turned off), when they joined, when they were last seen, friends, texts and pics sent, with a search. The header says how many of the account cap are in use; a turned-off account doesn't count toward it.

Choosing someone opens their account:

| | Where it comes from |
|---|---|
| Joined, last seen, online now | `users`, the live sockets |
| Signed in on N devices, M with notifications | Current sessions, push subscriptions |
| Friends, groups | Current friendships and memberships |
| Texts, pics, and group messages sent; invite links made | Counts of rows they sent |
| Recovery key | Whether they saved one (not the key) |
| Key reset | When an Admin reset code last gave them a new key |
| Wrong passwords | Failed sign-ins in the current 15-minute window, and whether they're locked |
| History | Every Admin action on the account, and every time it was turned off or on |

Counts and dates only, like the rest of the System page: never a message, a key, a profile, or anything they wrote.

## What an Admin can do

Every action takes two taps, and each is recorded (below).

**Turn the account off.** For someone who should no longer use napsack. Nothing is deleted (Rule 1): a row is added to `deactivations`, with an optional reason only Admins see. From that moment:
- every session ends and their live connections close, so their apps find themselves signed out;
- signing in, recovering with a recovery key, or using a reset code says "This account has been turned off", but only after the right password or key, so it tells a guesser nothing;
- friends keep the chat and can read all of it, but can't send texts, pics, or reactions to them; their chat list says "Account turned off" and the chat explains why sending is blocked;
- nobody can find them to send a friend request, and their invite links stop working;
- nothing reaches their devices (notifications only go to live sessions);
- they don't count toward the account cap.

An Admin can't turn off their own account, or another Admin's: Admins come from settings, so take them off the admin list first.

**Turn it back on.** Marks the row ended. Everything is as it was: they sign in with the same password and find all their history.

**Sign out everywhere.** Ends every session, for a lost or stolen phone. They sign in again with their password; nothing else changes.

**Clear sign-in lock.** Ten wrong passwords in 15 minutes lock a username (`ratelimit.rs`). This clears the count, so someone who has found their password doesn't have to wait.

**Reset password.** The reset code (account.rs; [how-napsack-works.md](../how-napsack-works.md#forgot-your-password)), moved here from the overview: a new password and a new key, without the old history. If they still have their recovery key, they should use that instead.

## Admin activity

`admin_actions` records every Admin action on an account (turned off, back on, signed out, lock cleared, reset code) and every announcement: who, what, to whom, when, and a little detail (how many devices were signed out, whether a reason was given; never the reason, a code, or anything secret). It's append-only. Each account shows its own; the Users tab shows the newest across everyone.

## Announcements

A short message from the Admins (280 characters, one line) that everyone signed in sees at the top of their chat list, live, until it ends (an hour to two weeks) or is withdrawn. One at a time: posting a new one withdraws the last. Dismissing it hides it on that device; a new one shows again. It's plain text the server stores and shows to everyone, so it's checked like other such text (`text.rs`) and shown with `textContent`. Withdrawn ones are kept.

Good for things like "napsack moved to napsack.io. Your saved password is listed under napsack.getattr.com."

## Ideas for later

- Turn off an account from the friend graph.
- Show sign-in failures per address as well as per username.
- A note on an account that only Admins see.
- Export one person's metadata (their own counts and dates) on request.
