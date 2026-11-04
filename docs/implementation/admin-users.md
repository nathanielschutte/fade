# System → Users

The Admins' tools for people's accounts, on the System page's **Users** tab: everyone at a glance, one account in detail, and what an Admin can do about it. Also announcements, a record of every Admin action, and the **Reports** tab (below), where Admins act on what people report. Admins only ([roles.md](roles.md)): PowerUsers and Users get "not found" from every endpoint here, and don't see the tab.

Code: `server/src/admin_users.rs`, `server/src/announcements.rs`, `server/src/reports.rs`, migrations `0018_admin.sql` and `0029_reports_and_blocks.sql`; the page is `server/static/admin.js` (sections "users" and "reports"). Tests: `check_admin_users`, `check_reports`, and `check_roles` in `tests/smoke_test.py`, `tests/e2e/test_admin_users.py`, `tests/e2e/test_reports.py`.

## People

A table of every account (an account its owner deleted isn't listed, and its page is "not found": nothing of it is left to show): username, role, status (online, active, or turned off), when they joined, when they were last seen, friends, texts and pics sent, with a search. The header says how many of the account cap are in use; a turned-off account doesn't count toward it.

Choosing someone opens their account:

| | Where it comes from |
|---|---|
| Joined, last seen, online now | `users`, the live sockets |
| Signed in on N devices, M with notifications | Current sessions, push subscriptions |
| Friends, groups | Current friendships and memberships |
| Texts, pics, and group messages sent; add-a-friend links made (one each since X39) | Counts of rows they sent |
| Recovery key | Whether they saved one (not the key) |
| Key reset | When an Admin reset code last gave them a new key |
| Wrong passwords | Failed sign-ins in the current 15-minute window, and whether they're locked |
| History | Every Admin action on the account, and every time it was turned off or on |

Counts and dates only, like the rest of the System page: never a message, a key, a profile, or anything they wrote.

## What an Admin can do

Every action takes two taps, and each is recorded (below).

**Turn the account off.** For someone who should no longer use napsack. Nothing is deleted (Rule 1; only people themselves can delete their account, [account-deletion.md](../design/account-deletion.md), and Admins never can): a row is added to `deactivations`, with an optional reason only Admins see. From that moment:
- every session ends and their live connections close, so their apps find themselves signed out;
- signing in, recovering with a recovery key, or using a reset code says "This account has been turned off", but only after the right password or key, so it tells a guesser nothing;
- friends keep the chat and can read all of it, but can't send texts, pics, or reactions to them; their chat list says "Account turned off" and the chat explains why sending is blocked;
- nobody can find them to send a friend request, and their add-a-friend link stops working;
- nothing reaches their devices (notifications only go to live sessions);
- they don't count toward the account cap.

An Admin can't turn off their own account, or another Admin's: Admins come from settings, so take them off the admin list first.

**Turn it back on.** Marks the row ended. Everything is as it was: they sign in with the same password and find all their history. It also ends a suspension early.

**Suspensions** (from a report, below) are the same row with an end: `deactivations.until`. Everything above applies until then. At `until` it ends by itself: a sweep every minute marks the row ended (`reactivated_at` is `until`, `reactivated_by` stays empty, and the account's history says "Suspension ended"), and signing in doesn't wait for the sweep, it ends one that's due on the spot. Every "is this account on" query reads `reactivated_at`, which is why the end is a mark rather than a comparison in each of them. A turn-off or suspension from a report also has `notice`, the Admin's words to the person: signing in (after the right password or key, as always) says "This account is suspended until 10 Nov, 14:02 UTC: <notice>" or "This account has been turned off: <notice>". `reason` stays Admins-only (for a report, "Report #42").

**Sign out everywhere.** Ends every session, for a lost or stolen phone. They sign in again with their password; nothing else changes.

**Clear sign-in lock.** Ten wrong passwords in 15 minutes lock a username (`ratelimit.rs`). This clears the count, so someone who has found their password doesn't have to wait.

**Reset password.** The reset code (account.rs; [how-napsack-works.md](../how-napsack-works.md#forgot-your-password)), moved here from the overview: a new password and a new key, without the old history. If they still have their recovery key, they should use that instead.

## Reports

The **Reports** tab (Admins only; PowerUsers never see it, and every endpoint answers them "not found") lists what people reported ([report-and-block.md](../design/report-and-block.md)): the open ones first, newest first, then the ones dealt with. Each shows who reported whom (a link to that person's account here), when, the reason and the reporter's note (as text), what was reported ("a text in their chat, sent Nov 3, 2:02 PM (message 1234)", "a pic in Road trip", "their profile"), and how many other reports there are about the same person. Never what a message said: the server doesn't know. A link to one report, `/admin#reports=42`, opens on it (the support email will carry one); `/admin#users=7` opens someone's account.

What an Admin can do about a report, once, two taps each, with their own words (one line, up to 500 characters):

- **Dismiss**, with an optional note for Admins.
- **Warn**: Team Napsack writes to the reported person, end-to-end encrypted like its other messages (team.rs): "An Admin reviewed a report about a message you sent to @ana on 3 Nov (UTC): <words>", with a link that opens it (`/#chat=<friend>&message=<id>`, or `/#group=<id>&message=<id>`). Nothing else changes.
- **Suspend** for 1, 7, or 30 days: turned off (above) until then, with the words as the notice; one already running is replaced.
- **Turn off**: until an Admin turns it back on, with the words as the notice. An account already off for good is left to the Users tab.

A suspension or a turn-off also gets the Team Napsack message, after "Your account is suspended until …" or "Your account has been turned off.", for when they're back. Nobody is told who reported them (for a direct message, whom they sent it to is who reported it), and the reporter isn't told the outcome. Each outcome is a `report_outcomes` row (append-only, one per report) and an `admin_actions` entry (`report_dismissed`, `report_warned`, `report_suspended`, `report_blocked`, with the report's id; never the words). The outcome says whether the Team Napsack message went.

## Admin activity

`admin_actions` records every Admin action on an account (turned off, back on, signed out, lock cleared, reset code, a report's outcome) and every announcement: who, what, to whom, when, and a little detail (how many devices were signed out, whether a reason was given; never the reason, a code, or anything secret). It's append-only. Each account shows its own; the Users tab shows the newest across everyone.

## Announcements

A short message from the Admins (280 characters, one line) that everyone signed in sees at the top of their chat list, live, until it ends (an hour to two weeks) or is withdrawn. One at a time: posting a new one withdraws the last. Dismissing it hides it on that device; a new one shows again. It's plain text the server stores and shows to everyone, so it's checked like other such text (`text.rs`) and shown with `textContent`. Withdrawn ones are kept.

Good for things like "napsack moved to napsack.io. Your saved password is listed under napsack.getattr.com."

## Ideas for later

- Turn off an account from the friend graph.
- Show sign-in failures per address as well as per username.
- A note on an account that only Admins see.
- Export one person's metadata (their own counts and dates) on request.
