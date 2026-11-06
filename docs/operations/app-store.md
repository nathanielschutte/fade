# The App Store

What napsack's App Store page says, how the privacy questions are answered, and how builds move from TestFlight to the store. App Store Connect is the owner's; this is the text to enter there, kept here so it changes with the app. Drafted 2026-11-06 for the first version, 1.2.0 ([releasing.md](releasing.md)); Nate edits it before it goes in.

The checklist of what Apple reviews is in [ios-onboarding.md](../ios-onboarding.md#external-testing-the-checklist); the plan is [F30](../management/plan.md#f30-napsack-10-on-the-app-store).

## How builds move

```
upload (scripts/ios-testflight.sh)  ─►  internal testers (minutes, no review)
                                    ─►  the external group (Beta App Review: the first build of each version)
                                    ─►  the App Store (App Review: every version)
```

- **Every upload is a new build** of whatever `MARKETING_VERSION` says (`ios/Config/Base.xcconfig`); the build number is the commit count, so it always goes up. Internal testers can install it as soon as Apple has processed it.
- **The external group:** the first build of a version goes through Beta App Review (usually a day or two). Later builds of the *same* version can usually go to the group straight away, though Apple may review one now and then. A new version's first build is reviewed again. Only one build per version is in review at a time.
- **Tweaks during the external test:** land them as more builds of the same version (1.2.0), so testers get them without another review. Raise the version only for something worth a new review, or once a version has been on the App Store.
- **The App Store** takes one build per version, chosen on the version's page: the build testers have tried. Every version is reviewed (usually a day or two). Once a version is released, the next change is a higher version (1.2.1 for fixes, 1.3.0 for features), its first build through Beta App Review again if it goes to testers first.
- **Release by hand:** choose "Manually release this version", so an approved version waits until the owner releases it. When it's released, tag the build's commit `ios-v<version>` ([releasing.md](releasing.md)).

## The listing

| Field | Text | Limit |
|---|---|---|
| Name | napsack | 30 |
| Subtitle | Private messages for friends | 30 |
| Category | Social Networking (no second category) | |
| Promotional text | Texts, and pics and videos that open once, for you and your closest friends. End-to-end encrypted. No ads, no trackers. | 170 |
| Keywords | private,messenger,encrypted,friends,chat,photos,view once,secure,texting,group chat,video | 100 |
| Support URL | https://napsack.io/support | |
| Marketing URL | none | |
| Privacy Policy URL | https://napsack.io/privacy | |
| Copyright | 2026 Nate Schutte | |

**Description** (up to 4,000 characters):

> napsack is a small, private messenger for you and your closest friends.
>
> Text your friends, one to one or in groups. Send a pic or a short video that opens once: when your friend has seen it, it's gone. Draw on it, add a caption, and what's on your screen is exactly what they see.
>
> Everything you send is end-to-end encrypted: locked on your phone with keys only you and the people in the chat have. napsack's server stores your messages locked and can't read them.
>
> Made for friends:
> • Only friends can message you. Add people by username or by sharing your link.
> • React to any message, reply to it, and edit a text for a few minutes after sending.
> • See who's active and typing, only when they choose to share it.
> • Report a message or a person, and block anyone, from their profile or the chat.
>
> Yours, and private:
> • No ads, no trackers, and nothing sold.
> • Your password never leaves your phone.
> • Lock napsack with Face ID.
> • Delete your account from Settings at any time: everything of yours is gone.
>
> napsack also works in your browser at napsack.io, with the same account and chats.

## App Privacy (the privacy labels)

What the app and server do ([how-napsack-works.md](../how-napsack-works.md), [the privacy policy](https://napsack.io/privacy)). Apple counts data as collected when the developer can read it; texts, pics, and videos are end-to-end encrypted, so they aren't collected.

**Data used to track you:** none. **Tracking:** no.

**Data linked to you**, each for **App Functionality** only:

| Apple's type | What it is in napsack |
|---|---|
| Contact Info › Name | the display name, if you add one (friends see it) |
| Identifiers › User ID | the username |
| User Content › Photos or Videos | the profile picture and group pictures, which aren't end-to-end encrypted |
| User Content › Other User Content | a birthday, if you add it, and group names |
| Diagnostics › Other Diagnostic Data | the app's own error reports (ids, counts, and statuses; never content) |

**Not collected:** texts, pics, videos, and captions (end-to-end encrypted); contacts (napsack never reads the phone's contacts); location; anything for advertising or analytics. Requests' internet addresses are logged to keep napsack running and stop abuse, which Apple's labels don't ask about unless they're used to work out where someone is.

## Age rating

Answers to Apple's questions (Nate's to give; Apple works out the rating):

- Violence, sexual content, profanity, horror, drugs, gambling, contests: none (none made by napsack).
- **User-generated content: yes. Messaging and chat: yes.** With them, the rating can't be the lowest. The privacy policy says napsack isn't meant for children under 13.
- Unrestricted web access: no (links in texts are text, except links to napsack's own chats).
- Advertising, in-app purchases, parental controls, age checks: none.

## Pricing and availability

Free, with no in-app purchases. The EU's trader question: **not a trader** (Nate, 2026-11-05). Countries: the owner's choice.

## App Review information

The same as for Beta App Review (the owner's notes): a contact, sign-in required with the reviewer account (its details only in App Store Connect), and notes on what to try, including reporting (hold a message › Report) and blocking (a profile › Block; Profile › Blocked lists them).

## Screenshots

napsack is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), so only iPhone screenshots are needed: one set at 6.9" (1320 × 2868), which Apple scales for smaller iPhones. They're taken on the Simulator with staging's seeded people (`scripts/reset-staging.sh`), never real accounts or conversations: the chat list, a chat, a pic with a caption being sent, a group, and Profile.
