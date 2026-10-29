# Team Napsack

**Team Napsack** is napsack's own account. It can message anyone without being their friend, for occasions: a birthday, a holiday, a heads-up that a friend's birthday is today. Its messages are scheduled in code, in [`server/occasions.toml`](../../server/occasions.toml); there's no screen for writing them. Plan entry: [X22](../management/plan.md#x22-team-napsack-messages-from-napsack-itself).

Code: `server/src/team.rs` (the account, its key, sending), `server/src/occasions.rs` (the schedule), migration `0019_team.sql`. Tests: unit tests in both files, `check_team` in `tests/smoke_test.py`, `tests/e2e/test_team.py`.

## Scheduling a message

Add an `[[occasion]]` to `server/occasions.toml`, run the tests (`the_shipped_schedule_is_valid` checks the file), and release. Every 5 minutes the server looks at what's due.

```toml
[[occasion]]
id = "christmas"                 # letters, digits, hyphens; never reuse one that has sent
when = "yearly 12-25"            # "birthday", "yearly MM-DD", or "once YYYY-MM-DD"
hour = 15                        # UTC, optional (15 is 10 in the morning, US Central)
to = "everyone"                  # or "birthday person", "birthday friends", or ["nate", "ana"]
only = ["nate"]                  # optional: narrow it to these usernames, to try it out
text = "Merry Christmas, {name}! 🎄"
```

| Field | Values |
|---|---|
| `when` | `"birthday"`: on each person's birthday, from their profile. `"yearly MM-DD"`: every year that day. `"once YYYY-MM-DD"`: just that day |
| `hour` | 0 to 23, UTC. It sends at or after that hour, that day only. A day the server is down all day isn't made up |
| `to` | `"everyone"`: every account that's on. `"birthday person"` and `"birthday friends"` (with `"birthday"`): the person whose birthday it is, or their friends. A list: those usernames (an old username still means its owner) |
| `only` | Narrows any of the above to these usernames: the way to try something on yourself first |
| `text` | Up to 1,000 characters. `{name}` is the recipient's name as they set it; `{birthday_name}` (birthday only) is whose birthday it is, as the recipient knows them |

**To see one before it goes**, send it to yourself: `POST /api/admin/occasions/<id>/try` (Admins only; from the browser console while signed in, or curl with your session token). It doesn't count as the real send. `GET /api/admin/occasions` lists the schedule, any problems in the file, how many each has sent, and who each would reach today.

**Each message goes once.** Before sending, the server claims a row in `occasion_sends` (occasion, occurrence, person), and a unique index stops a second. A birthday's occurrence is the date and the birthday person, so two birthdays the same day are two occurrences. Changing an occasion's text doesn't resend it; a new `id` would.

Starting entries (2026-10-24), all to `nate` only: a one-time hello (Oct 25, from midnight UTC), Halloween, a birthday wish, and a heads-up on a friend's birthday.

## How it works

**The account.** At startup, if it isn't there, the server makes it: a P-256 key pair (the private key in `server_keys`, never replaced: a new key would show everyone a changed safety code), a user `napsack` (or `team.napsack` if that name is taken) with the display name "Team Napsack", and a row in `system_accounts`. It can't sign in: the stored password hash is of a key nobody has, and sign-in refuses system accounts before checking. It isn't counted in the account cap, can't be found for friend requests, and Admins can't turn it off, sign it out, or reset it.

**Encryption.** Its messages are ordinary format 2 texts, end-to-end encrypted to the recipient the same way any friend's are ([how-napsack-works.md](../how-napsack-works.md)): the server does what a friend's app does, ECDH between Team Napsack's private key and the recipient's public key, HKDF with the sorted ids, then AES-256-GCM with the sender and recipient bound in. The app decrypts them with no special case. A unit test opens the pinned vectors made by `crypto.js` with the server's code, so the two can't drift. Because the server writes these messages, it knows what they say; it still can't read anyone else's chats. Each recipient's app pins Team Napsack's key like a friend's.

**The chat.** It appears in someone's list once Team Napsack has written to them, read-only: "Messages from Team Napsack, for birthdays and other occasions. You can't reply here." They can read it, mark it read, mute it, favorite it, or hide it; they can't send, react, or open a profile. It never shows up as a friend (groups, the friend map). A message arrives live, with a notification like any other ("Team Napsack: New message").

## Ideas for later

- Show Team Napsack's chat with napsack's mark instead of an initial.
- A recipient's own time zone for `hour` (the app knows it; the server doesn't keep it).
- Occasions driven by other data: an anniversary of joining, a streak milestone.
