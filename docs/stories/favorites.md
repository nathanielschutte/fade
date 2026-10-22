# Story: Favorites

> Shipped in 0.19.0 (taken over and finished on 2026-10-21; see X3 in [plan.md](../plan.md) for the decisions).

**As someone with a lot of chats, I want to mark my closest friends (and groups) as favorites, so they're always at the top of my chat list, whatever else is going on.**

This is yours to build. What follows is the shape of the problem: what "done" looks like, the questions you'll have to answer, and where in the code to start looking. How to build it is up to you. Read [ONBOARDING.md](../ONBOARDING.md) first.

## Done looks like

- I can mark a chat as a favorite, and unmark it, from somewhere obvious (and it's just as obvious how to undo).
- Favorites sit at the top of the chat list, set apart from the rest in a way I can see at a glance. Everything else stays in its usual order below.
- My favorites follow me: the same on my phone and my laptop, and they survive signing out and back in.
- Changing them on one device shows up on my other open devices without a reload.
- Nobody else knows who my favorites are. My friends see no difference.
- It works on a phone (390 px wide) and nothing scrolls sideways.
- The API, the rules it enforces, and the whole flow are covered by tests, and the new endpoint is in [API.md](../API.md).

## Questions you'll need to answer

Decide these before you write much code. Some have an obvious answer once you think about them; one or two are real product choices (write down what you picked, and why, in [plan.md](../plan.md)).

- **What can be a favorite?** Direct chats, groups, or both? Each one is identified differently in the app today.
- **How many?** Is there a limit? (Anything a person can create without limit needs one, see [SECURITY.md](../SECURITY.md).) What happens when someone tries to add one more?
- **What order are favorites in?** Most recent message first, like everything else, or an order I choose? (The first is much simpler; the second could be a follow-up.)
- **Where does the list live?** On the server, so it follows me between devices, or only in the browser? What does the server learn about me by storing it, and is that OK? (Compare with what it already knows: [how-napsack-works.md](../how-napsack-works.md), "At a glance".)
- **Rule 1: nothing is ever deleted.** Unfavoriting can't remove a row. What does the data look like so that "unfavorited" is recorded rather than erased? (There's a feature in the code that already solved exactly this problem for a private, per-person setting. Find it.)
- **What if the chat goes away?** I unfriend someone, or leave a group, while they're a favorite. Then we become friends again. What should happen at each step?
- **How do my other devices find out?** Look at how the app already hears that "something about my friends changed", and whether that's good enough here or you need something new.
- **The iOS app is coming.** Does your API make sense for a client that isn't the web app?

## Where to start reading

- **How the chat list is built and sorted**: `friends.rs` (`list_chats`) and `groups.rs` (`list`) on the server; `renderChatList` and `chatRow` in `app.js` (section `app shell`). Notice the direct chats and groups are merged and sorted in the browser.
- **A private, per-person setting that already exists**: nicknames, in `people.rs`, its migration (`server/migrations/0008_...`), and how the chat list returns them. The closest thing to what you're building.
- **A simple setting that tells your other devices**: `presence.rs`, `set_settings`.
- **Tests to copy the shape of**: `check_people` in `tests/smoke_test.py`, and the nickname part of `tests/e2e/test_profile.py`.
- **The rules**: [CLAUDE.md](../../CLAUDE.md), Rule 1 and Code standards.

## When you're stuck

Get a small slice working end to end first: one hardcoded favorite showing at the top, then make it real. If something in the codebase is confusing, that's worth a note in [ONBOARDING.md](../ONBOARDING.md) for the next person.

## Later, maybe

Not part of this story, but they'll be easier once it's done: choosing the order by hand, and muting or archiving chats (see X3 in [plan.md](../plan.md), which this story starts).
