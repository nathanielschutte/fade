# Report and block

Status: decided in outline (Nate, 2026-11-03), not built. Plan: [F28](../management/plan.md#f28-report-and-block). Why now: App Review guideline 1.2 asks apps where people send each other things to let them report it and block whoever sent it, and to act on reports in good time. It's the likeliest reason the first external TestFlight build would be refused, and the external group is the next milestone.

## Decided (Nate, 2026-11-03)

- **No message content in a report, ever.** Reporting must not break end-to-end encryption: a report carries the reported message's id, kind, and time (what the server already knows), never its text or picture, decrypted or not.
- **The reported person can know which message.** What they're told points at the message by its id, so their own app can show it to them; still no content in what the server stores or sends.
- **Admins work reports from a Reports page on the System page**, with tools to act on the reported person: warn, suspend for a while, or block (turn off), each telling them why.
- **An email to the support address** for each new report, linking to its record on the Reports page (and nothing more).

## What people can do

**Report.** From a message's menu (a text, a pic or video, in a chat or a group) and from a person's profile: pick a reason, optionally add a line in their own words, send. Reasons: Spam; Harassment or bullying; Nudity or sexual content; Violence or threats; Hate; Something else. The app says what happens: "An Admin will look at it. They'll see who sent it and when, but never what it said." After reporting a person or their message, it offers to block them too.

The note is the reporter's own words, stored as plain text for Admins (checked like other stored text, `text.rs`, and shown with `textContent`), and the app says not to paste the message into it.

**Block.** From a profile, a chat's menu, or after reporting. Blocking someone:
- ends the friendship (a mark, as unfriending does, with the reason `blocked`), so they can't send you anything;
- refuses their friend requests to you, and your add-a-friend link to them, with the same answer as an unknown person gets, so a block can't be detected;
- stops them adding you to a group; groups you're both already in stay as they are (you can leave);
- is listed in Profile › Blocked, where you can unblock (a mark; nothing is deleted).

## What Admins see and do

**System › Reports** (Admins only; PowerUsers never see it, `roles.rs`, a row in `check_roles`): the open reports, newest first, and the dealt-with ones below. Each shows who reported whom, when, the reason and note, and what was reported: "a text in their chat, sent 2026-11-03 14:02 (message 1234)", "a pic in Road trip", "their profile". Never content. It shows how many other reports there are about the same person, and their account (link to System › Users).

Actions on a report, each two taps, each recorded in `admin_actions` (append-only):
- **Dismiss**, with an optional note for Admins.
- **Warn**: a message from Team Napsack to the reported person, with the Admin's words and, for a message, which one (below). Nothing else changes.
- **Suspend** for 1, 7, or 30 days: their account is turned off until then (the existing `deactivations`, now with an end), with the Admin's words shown to them.
- **Block**: turned off until an Admin turns it back on, with the Admin's words shown to them.

## What the reported person is told

- **Warned:** a Team Napsack message, end-to-end encrypted to them as Team Napsack's messages are ([team-napsack.md](../implementation/team-napsack.md)): "An Admin reviewed a report about a message you sent to @ana on 3 Nov: <the Admin's words>", with a link that opens that chat at that message (`/#chat=<friend>&message=<id>`; the apps already open a chat at a message for search). The server writes this message itself, so it knows what it says; it never knows what the reported message said.
- **Suspended or blocked:** signing in (after the right password or key, as today, so it tells a guesser nothing) says "This account is suspended until 10 Nov: <the Admin's words>" or "This account has been turned off: <the Admin's words>". A Team Napsack message says the same, for when they're back.
- **Never** who reported them.

The reporter isn't told the outcome (a possible later addition: "We reviewed your report").

## The email

For each new report, an email to the support address (`FADE_REPORTS_EMAIL`, a setting): "New report #42: a message, reported by @ana about @ben. <link to System › Reports #42>". Nothing else: no reason text, no note, no content.

The server sends it through Amazon SES (an AWS endpoint fixed in the code, as `aws.rs`'s others; the server still never connects where a request says). That needs, from the owner: an SES identity for the domain with its DKIM records in Route 53 (Terraform), permission for the instance's role to send, and the address as a setting. In SES's sandbox it can already send to a verified address, which is all this needs. Until that's applied, reports still land on the Reports page; the email is the second step.

## Server

- `reports` (id, reporter_id, reported_id, kind `message` | `group_message` | `person`, message_id, group_id, reason, note, created_at), and `report_outcomes` (report_id, action `dismissed` | `warned` | `suspended` | `blocked`, admin_id, notice, until, created_at): both append-only (Rule 1).
- `blocks` (blocker_id, blocked_id, created_at, ended_at): unblocking marks `ended_at`.
- `deactivations` gains `until` (an automatic end) and `notice` (words the person sees); the existing `reason` stays Admins-only. An expired suspension ends by itself (a sweep marks `reactivated_at`, or reads treat a past `until` as ended; decide when building).
- A report is checked against what the reporter can see: the message must be theirs to read (sent to them, or in a group whose history includes them, `groups::audience`), so nobody can report what they've never been shown, or learn whether a message id exists.
- Limits (`guard.rs`, a row in [security.md](../security.md)): reports per person per day; blocks per person. The note is capped and checked (`text.rs`).
- Deletion (`deletion.rs`): a person deleting their account removes their reports, blocks, and outcomes; `deletion::tests` seeds the new tables.
- Logs: report and block events at info, with ids only; never the note.
- API: `POST /api/reports`, `POST /api/blocks/{user}`, `POST /api/blocks/{user}/remove`, `GET /api/blocks`; Admins: `GET /api/admin/reports`, `GET /api/admin/reports/{id}`, `POST /api/admin/reports/{id}/outcome`. In [api.md](../spec/api.md) when built.

## Order of work

1. The server (tables, endpoints, the sign-in notice, Team Napsack's warning, deletion, limits, smoke tests).
2. System › Reports (admin.js), then reporting and blocking on the web.
3. The iPhone app: Report in the message menu and on profiles, Block, Profile › Blocked.
4. The email, once the owner applies the SES setup.

## Open questions for Nate

- The reasons list above, and suspensions of 1, 7, or 30 days: right?
- Should the reporter hear the outcome ("We reviewed your report")?
- In a group with someone you've blocked, should their messages be hidden from you, or left as they are (you can leave the group)?
