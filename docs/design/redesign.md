# Redesigning napsack

A plan for redesigning the iPhone app first and bringing the web app along, and a map of where every piece of the current design lives: colors, icons, type, shapes, motion. Nothing here has been built, and nothing here changes how the app looks yet. Plan: [X57](../management/plan.md#x57-redesign).

This was written on 2026-11-06 by reading the code. The iPhone app wasn't run for it, so check anything marked "on a phone" there. Search for the names given here rather than trusting line numbers, which move.

## The short version

**The iPhone app has no design layer to change.** The web has one: named colors at the top of `style.css`, used about 400 times. The iPhone has one named color, the accent. Everything else is either the system's default or a literal typed where it's used (`.red`, `.white`, a corner radius of 18). So changing the iPhone's look today means editing around 20 files, one call at a time.

That decides the order of the work:

1. **Decide what the redesign is for** ([the decisions](#decisions-for-nate)). Most of them take a minute each.
2. **Take "before" pictures** of every screen, on both clients.
3. **Give the iPhone a design layer that changes nothing visible:** one Swift file of named colors, shapes, and icons, with every screen moved onto it. The pictures must match. It's invisible, so it can go in at any time.
4. **Keep one list of the values,** with a test that fails when a client drifts from it.
5. **Design on a board, not in code:** a few directions on the screens that matter most (chat list, chat, camera, a pic opening). Nate picks one before anything is built.
6. **Build it on the iPhone a screen at a time,** through TestFlight.
7. **Bring the web along,** first the colors (one block of CSS), then the places where it's laid out differently.
8. **Finish:** app icon, App Store screenshots, Android's palette.

Don't start by editing screens, because a redesign without step 3 has to be redone at every later change of mind. And don't let the visible part reach the App Store until 1.0 is through review ([F30](../management/plan.md#f30-napsack-10-on-the-app-store)): a visible change in the middle of a review could raise new questions, and the store screenshots would need taking again.

## What surprised me

Four findings that should shape the redesign:

1. **The iPhone and the web aren't the same design today.** The web is always dark forest green. The iPhone follows the phone's own light or dark setting, on the system's white or black, and the green shows only in the accent color and the app icon. Nothing in the docs or the plan records this as a decision, and neither the code nor the settings set an appearance (no `preferredColorScheme`, no `UIUserInterfaceStyle`). It looks like the default that was never revisited.
2. **The accent is hard to read in light mode on the iPhone.** `#93C5A3` was picked for a dark background and has one value, with no dark or light variant. On white, "Tap to view pic" and the initials in avatars come in far below the usual minimums ([numbers below](#contrast)). This is worth fixing whatever else happens.
3. **The two clients draw messages differently.** The web is a left-aligned transcript with a colored rule beside each message; the iPhone has bubbles, yours on the right. It's the biggest visual difference between them, and [a decision](#decisions-for-nate).
4. **The web's signature moment isn't on the iPhone.** On the web a pic stays for 10 seconds, with a bar draining, while the photo blurs and sinks into the green (`VIEW_MS`, `@keyframes fade-out`, `tint-in`, `drain`). The iPhone's viewer has no timer, bar, or fade: it stays until you tap. It's the one bit of motion that says what the app is about.

## Decisions for Nate

Each of these changes what gets built. A recommendation comes with each, and the answers go here and in [X57](../management/plan.md#x57-redesign).

| # | Decision | Recommendation | Why |
|---|---|---|---|
| 1 | What should change, in a sentence? A new identity, or the same identity done properly and everywhere? | The same identity, done properly | The dark green is distinctive and already on the icon, the web, and Android. The iPhone is what's missing it. If you're tired of the green, say so first, since everything below follows from this |
| 2 | Does the iPhone have light mode? | Dark only for now, like the web and Android; light mode later as its own palette, if people ask | Two appearances mean every color is chosen and checked twice. Dark only is one line (`INFOPLIST_KEY_UIUserInterfaceStyle = Dark` in `App.xcconfig`) and removes the contrast problem straight away. The cost: people who keep their phone in light mode lose that |
| 3 | On the iPhone: napsack's own surfaces, or the system's with an accent? | Own colors on system components: `--ink` behind the lists and chat, while tab bars, navigation, sheets, and menus stay the system's | You keep what iOS does for free (gestures, Dynamic Type, its current look) and still look like napsack. Hand-drawn replacements for system components are the expensive way to do this |
| 4 | Messages: bubbles or transcript? | Bubbles on both | iOS is the focus and bubbles are what's there. On a wide screen the web's transcript reads well, so this is the one with a real case either way: see it on the board first |
| 5 | Icons: SF Symbols or drawn by us? | SF Symbols on the iPhone, with custom drawings only where the meaning is napsack's own (new group, already noted as "custom artwork later"; the pic marker). The web keeps its own line icons, chosen to sit close to them | 64 symbols already scale and match weight on their own. A custom symbol is a template file per icon. Apple's license ties SF Symbols to its own platforms, so the web and Android can't use them anyway |
| 6 | Typeface? | Stay with the system font; if you want character, draw the wordmark as artwork | A custom font has to be bundled on the iPhone and scale with Dynamic Type, and on the web compiled into the binary (no third-party fonts). Captions stay in the system font regardless ([pic-framing.md](../implementation/pic-framing.md)) |
| 7 | Should a pic's fade and timer come to the iPhone? | Yes, as a decision of its own | It changes behavior as well as looks, so it needs its own entry. People would have less time with a pic, and zooming has to fit around it |
| 8 | The app icon: keep the "n"? | Keep it until the rest is settled | It's the last thing to change and the one people notice most |

## The plan, in steps

Step 1 is [the decisions](#decisions-for-nate) above.

### 2. "Before" pictures

Without these, step 3's "nothing changed" can't be shown.

- **iPhone:** the app already has a way to draw a screen at any size into a picture without a Simulator per phone (`Hosted`, `Phone.small`, `Phone.large` in `ios/NapsackTests/Hosting.swift`, used by `CameraLookTests`, `PeopleLookTests`, `ModerationLookTests`, `FitLookTests`, `WhoReactedLookTests`, and others). A new `RedesignLookTests` could add the screens they don't cover, for later comparison. It runs on the Mac:
  ```sh
  TEST_RUNNER_NAPSACK_SHOTS=/tmp/shots ONLY=NapsackTests/OnScreen/CameraLookTests bash scripts/test-ios.sh
  ```
- **Web:** a Playwright script at desktop and 390px wide, as the browser tests do.

### 3. A design layer on the iPhone, with no visible change

A new `ios/Napsack/Theme.swift` (new files just go in the folder) and named colors in `Assets.xcassets`. Roughly:

```swift
enum Theme {
    // Colors, by what they're for. The web's names, so one word means one thing.
    static let sage = Color.accentColor
    static let danger = Color.red
    static let myBubble = Color.accentColor.opacity(0.3)
    static let theirBubble = Color(.secondarySystemBackground)
    // Shapes
    static let bubbleRadius: CGFloat = 18
    static let menuRadius: CGFloat = 14
}

enum Icon {
    static let chats = "bubble.left.and.bubble.right"
    static let newGroup = "person.3"
    static let close = "xmark"
}
```

Every value starts out as exactly what's there now. Then the screens move onto it, file by file, a mechanical change that's easy to review. Once it's done, a new accent is one line and a new "close" icon is one line. This is an iOS-only pull request: `make ios` on both iOS versions, no server release.

Leave the camera and the pic viewer's black and white out of it, or name them plainly. They sit on top of photos and are meant to stay neutral.

### 4. One list of values, checked by a test

The palette is now typed by hand in several places ([what changing a color touches](#changing-a-color-today)). Generating them would add a build step the web doesn't want, so do what the crypto vectors do: keep one reference and a test that fails when a client disagrees.

- `shared/design/tokens.json`: the colors and radii.
- A small check in `scripts/test.sh` that reads it and compares `style.css`, the asset catalog, `Theme.kt`, `colors.xml`, the `theme-color` lines, and the manifest.

Clients can still choose to differ, but only on purpose, with the exception written in the file.

### 5. Design on a board

Three or so directions, each showing the chat list, a chat, the camera, and a pic opening, at the iPhone's smallest and largest sizes with real-looking data. Nate wants to see visual redesigns before they're built. Any inspiration stays off the repository's docs: they describe napsack on its own terms and never name other apps as the model.

### 6. Build on the iPhone, in slices

In this order, each its own pull request and TestFlight build, so each can be lived with on a real phone:

1. The palette and tab bar, across everything at once (because of the `Theme` file).
2. The chat list: rows, markers, avatars, swipe actions.
3. A chat: messages, composer, the held-message menu, reactions.
4. The camera and the pic viewer (with the fade, if decision 7 says so).
5. Friends, Profile and Settings, groups, profiles.
6. Sign-in, the lock screen, the launch screen.

### 7. Bring the web along

- **Colors and shapes first:** the `:root` block in `style.css`, plus the [literals standing in for tokens](#web-colors).
- **Then the layout differences** in [the table below](#where-the-iphone-and-web-differ), as decided.
- It ships differently: the web is compiled into the server, so it needs staging and a `server-v` tag, and goes live for everyone at once. The iPhone waits for TestFlight or App Review. Nothing in a redesign touches the API, so either can go first and the compatibility rules aren't in play. Try to land the two close together, since people use both.

### 8. Finish

- **The app icon** on every platform ([recipe](#changing-the-app-icon)).
- **App Store screenshots:** retaken as [app-store.md](../operations/app-store.md) describes, from staging's seeded people.
- **Android:** it's a shell, so it's cheap now and costlier every week. Update `Theme.kt` when the palette settles, and put what it still needs in [plan-android.md](../management/plan-android.md).
- **Docs:** this map becomes `docs/implementation/design-system.md`, describing what's there rather than what's planned. [ios-onboarding.md](../ios-onboarding.md) and [android-onboarding.md](../android-onboarding.md) mention the palette and may need updating too.

---

# The map

Where everything is today.

## Colors

### The palette

It's named after a darkroom. Defined in [style.css](../../server/static/style.css), `:root`, and copied into Android's [Theme.kt](../../android/app/src/main/kotlin/io/napsack/app/Theme.kt).

| Name | Value | For | iPhone today |
|---|---|---|---|
| `--ink` | `#1b2822` | The base background | None: the system's background |
| `--deep` | `#15201b` | Recessed: inputs, the list pane | None |
| `--wash` | `#26372f` | Raised: hover, selection | None |
| `--paper` | `#e4ece6` | Main text | None: `.primary` |
| `--fixer` | `#9db3a6` | Secondary text | None: `.secondary` |
| `--sage` | `#93c5a3` | The accent: main actions, unopened pics | `AccentColor`, the same value |
| `--sage-hover` | `#a6d2b4` | Accent on hover | Not needed |
| `--on-sage` | `#12201a` | Text on the accent | None |
| `--danger` | `#e8a598` | Errors, destructive actions | None: the system's `.red` |
| `--rule` | `rgba(228, 236, 230, 0.12)` | Hairlines and borders | None |

### Web colors

The names above are used about 400 times, but some colors in `style.css` are still typed out. These should become names:

| Literal | Really is | Where it's used |
|---|---|---|
| `rgba(147, 197, 163, ...)` | `--sage`, faded | Hovers, `mark`, `.flash`, role and status chips |
| `rgba(228, 236, 230, ...)` | `--paper`, faded | Friend map lines, timers, swatches, skeletons |
| `rgba(38, 55, 47, 0.6)` | `--wash`, faded | Row hovers |
| `rgba(232, 165, 152, ...)` | `--danger`, faded | Danger hovers, error rows |
| `rgba(12, 20, 16, ...)` | A dark scrim with no name | Dialog backdrops, buttons over photos, text shadows |
| `#2f4a3c`, `#34505a`, `#4a4a36`, `#3e3a52`, `#503a3a`, `#2e4a4a` | The six avatar tints | `.avatar`, picked by `id % 6` in `app.js` |

Colors that are separate on purpose, and should stay out of the redesign's palette:

| What | Where | Why it's separate |
|---|---|---|
| Staging's marks: `--env-mark`, `--on-env-mark` | `style.css`, `env.js` | They go on top of the design, which never accounts for them |
| Charts and status: `--series-*`, `--status-*` | `style.css`, "admin: metrics" | Admins only |
| Friend map groups: `--gc0` to `--gcx` | `style.css`, "friend map" | Told apart by hue; the web's only use of these |
| Pen colors: `COLORS` | `draw.js` | Drawn into the photo's pixels, so they need to work on any picture. One of them is sage, typed by hand |
| Recording red: `#d94848`, `#b83b3b` | `style.css`, "short videos" | Means recording |
| The QR code: `#ffffff`, `#12201a` | `style.css`, `.invite-qr` | Must stay scannable ([qr.md](../implementation/qr.md)) |

### iPhone colors

The one defined color: [AccentColor](../../ios/Napsack/Assets.xcassets/AccentColor.colorset/Contents.json), set as the app's accent in `App.xcconfig`. It also tints links, toolbar buttons, the selected tab, and prominent buttons without any code asking it to.

Everything else is spread through the screens:

| Use | How it's written | Files with the most |
|---|---|---|
| Accent | `Color.accentColor`, often faded: my bubble 0.3, chosen reaction 0.25, avatar background 0.18 | `ChatScreen`, `ChatListScreen`, `Reactions` |
| Errors | `.foregroundStyle(.red)` | Most screens with a form: `SignInScreen`, `Passkeys`, `Moderation` |
| Over photos | `.white`, `.black.opacity(...)` from 0.25 to 0.6 | `Camera` (25 lines), `PicViewer` (11 lines) |
| Text | `.primary`, `.secondary` | Everywhere; these adapt on their own |
| Surfaces | `Color(.secondarySystemBackground)`, `.bar`, `.regularMaterial`, `.ultraThinMaterial` | `ChatScreen`, `ChatListScreen` |
| Swipe actions | `.tint(.yellow)` favorite, `.red` leave, `.blue` unhide, `.gray` hide, `.indigo` mute | `ChatListScreen` |
| Requests badge | White on `.red` | `ChatListScreen`, `chatsToolbar` |
| Others | `.yellow` flash and zoom on, `.orange` safety warning, the pen's red (`Pen.color`) | `Camera`, `SafetyCodeScreen`, `Drawing` |

No code on the iPhone reads the Reduce Transparency or Increase Contrast settings, which is worth remembering if the redesign leans on materials.

### Contrast

Measured from the values above. The usual minimums are 4.5:1 for text and 3:1 for large text and icons.

| Pair | Ratio | |
|---|---|---|
| `--paper` on `--ink` | 12.7:1 | Good |
| `--fixer` on `--ink` | 6.87:1 | Good |
| `--sage` on `--ink` | 7.83:1 | Good |
| `--on-sage` on `--sage` | 8.62:1 | Good |
| `--danger` on `--ink` | 7.48:1 | Good |
| Accent on black (iPhone, dark mode) | 10.76:1 | Good |
| **Accent on white (iPhone, light mode)** | **1.95:1** | **Fails:** "Tap to view pic", toolbar buttons, links |
| **Accent on its own 18% tint over white** | **1.75:1** | **Fails:** initials in avatars |

The palette works where it was designed to work. White labels on prominent buttons may have the same problem as the accent on white, in both modes: check it on a phone.

### Changing a color today

To show why step 4 is worth doing. A new **accent** means changing:

- `--sage`, `--sage-hover`, `--on-sage`, and every `rgba(147, 197, 163, ...)` in `style.css`, plus the near match `rgba(160, 196, 170, ...)` on the friend map
- `COLORS` in `draw.js`
- `AccentColor.colorset`
- `Theme.kt` and `colors.xml`
- `favicon.svg` and all four icon PNGs

A new **background** means changing:

- `--ink` in `style.css`
- `theme-color` in `index.html`, `admin.html`, `privacy.html`, and `support.html`
- `background_color` and `theme_color` in `manifest.webmanifest`
- `favicon.svg`, the icon PNGs, `Theme.kt`, and `colors.xml`
- `tests/e2e/test_environment.py`, which checks the value

On the iPhone, a new background has nothing to change: there's no place for one yet.

## Icons

### iPhone: SF Symbols

There are 64 of them, named as strings in the screens, with no list and no custom artwork. To see them all:

```sh
grep -nE 'systemName|systemImage|round\("|composerButton\("|icon: "|symbol: ' ios/Napsack/*.swift
```

To change one, find its string and replace it with another name from Apple's SF Symbols app. Keep the `accessibilityLabel`: VoiceOver reads it, and the UI tests find buttons by it, so swapping a picture breaks no tests.

Two helpers set their looks in one place: `round` in `Camera.swift` (21 points, semibold, on a dark circle) and `composerButton` in `ChatScreen.swift`.

| Where | What | Symbol | File |
|---|---|---|---|
| **Tabs** | Chats | `bubble.left.and.bubble.right` | `ChatListScreen` |
| | Camera | `camera` | `ChatListScreen` |
| | Profile | `person.crop.circle` | `ChatListScreen` |
| **Chat list** | Friends | `person.2` | `ChatListScreen` |
| | New group | `person.3` | `ChatListScreen` |
| | Row disclosure | `chevron.right` | `ChatListScreen` |
| | Favorite, Unfavorite | `star`, `star.slash` | `ChatListScreen` |
| | Hide, Unhide | `archivebox`, `tray.and.arrow.up` | `ChatListScreen` |
| | Mute, Unmute | `bell.slash`, `bell` | `ChatListScreen` |
| | Muted mark | `bell.slash.fill` | `ChatListScreen` |
| | Leave a group | `rectangle.portrait.and.arrow.right` | `ChatListScreen` |
| | Announcement | `megaphone` | `ChatListScreen` |
| | Reconnecting | `wifi.exclamationmark` | `ChatListScreen` |
| | Loading | `ellipsis` | `ChatListScreen`, `Moderation` |
| **Chat** | Encryption, key changed | `lock`, `lock.trianglebadge.exclamationmark` | `ChatScreen` |
| | Chat's menu | `ellipsis.circle` | `ChatScreen` |
| | New messages | `arrow.down` | `ChatScreen` |
| | Camera, choose a photo | `camera`, `photo.on.rectangle` | `ChatScreen` |
| | Send | `arrow.up.circle.fill` | `ChatScreen` |
| | Cancel reply or edit | `xmark` | `ChatScreen` |
| | Pic to open | `photo.fill`, `video.fill` | `ChatScreen` |
| | Pic opened | `photo`, `video` | `ChatScreen` |
| | Can't be read | `lock.trianglebadge.exclamationmark` | `ChatScreen` |
| | Reply, and the swipe's mark | `arrowshape.turn.up.left`, `.fill` | `ChatScreen` |
| | Copy, Edit, Edits | `doc.on.doc`, `pencil`, `clock.arrow.circlepath` | `ChatScreen` |
| | Any emoji | `plus` | `ChatScreen` |
| | No reactions | `face.smiling` | `Reactions` |
| **Camera** | Close, Retake | `xmark` | `Camera` |
| | Library | `photo.on.rectangle` | `Camera` |
| | Flip | `arrow.triangle.2.circlepath.camera` | `Camera` |
| | Flash off, auto, on | `bolt.slash.fill`, `bolt.badge.automatic.fill`, `bolt.fill` | `Camera` |
| | Undo, caption, pen | `arrow.uturn.backward`, `textformat`, `scribble` | `Camera` |
| | Sound on, off | `speaker.wave.2.fill`, `speaker.slash.fill` | `Camera` |
| | Send, add people | `paperplane.fill`, `plus` | `Camera` |
| | Picked, not picked | `checkmark.circle.fill`, `circle` | `Camera`, `Groups` |
| **Friends and people** | Scan a code | `qrcode.viewfinder` | `Friends`, `Links` |
| | Friend map | `point.3.connected.trianglepath.dotted` | `Friends` |
| | Share, copy link, copied | `square.and.arrow.up`, `link`, `checkmark` | `Friends`, `RecoveryKeyScreen` |
| | Add friend | `person.badge.plus` | `People` |
| | Report | `exclamationmark.bubble` | `ChatScreen`, `Groups`, `People`, `Profiles` |
| | Block, Unblock | `hand.raised`, `hand.raised.slash` | The same, and `Moderation` |
| | Reported | `checkmark.circle`, `checkmark` | `Moderation` |
| **Account** | Passkeys | `person.badge.key`, `.fill` | `SignInScreen`, `Passkeys` |
| | App locked | `lock.fill` | `AppLock` |
| | Safety codes | `lock` | `Profiles` |
| | Remove (a picture, a birthday) | `xmark.circle.fill` | `SettingsScreen` |
| | What deleting removes | `person.2`, `person.crop.circle`, `at`, and the chats icon | `SettingsScreen` |
| | Update needed | `arrow.down.app` | `UpdateScreen` |
| | "Couldn't load" | `exclamationmark.bubble` | `ChatScreen` |
| **Developer only** | Vector results | `checkmark.circle.fill`, `xmark.octagon.fill` | `VectorScreen` |

**Adding a custom icon:** in the SF Symbols app, export a symbol as a template SVG, draw in it, validate it by importing it back, and add it to `Assets.xcassets` as a Symbol Image Set. In code it's `Image("name")`, without `systemName:`. Done this way it scales with text like any other symbol. See Apple's [Creating custom symbol images](https://developer.apple.com/documentation/uikit/creating-custom-symbol-images-for-your-app).

### Web: inline SVG

The web's icons are its own line drawings, written into the page with no sprite and no icon file. Most are in [index.html](../../server/static/index.html), so a change has to be made at each copy: the close "x" appears 21 times and the camera 3.

**How they're styled:** one global rule at the top of `style.css`:

```css
svg { width: 1.5rem; height: 1.5rem; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
```

So a new icon should be drawn on a 24 × 24 grid as strokes, and it takes its color from the text around it. Anything that isn't an icon has to undo this rule, as the QR code and the metrics charts do.

| Icon | Used by (`id` or label) | Where |
|---|---|---|
| Close "x" | Every sheet's Close, `push-nudge-dismiss`, `announcement-close`, `reply-cancel`, Close camera | `index.html`, 21 times; `admin.html`, once (`u-close`) |
| Camera | `list-camera`, `tab-camera`, `camera-button` | `index.html` |
| Two people | `friends-button` | `index.html` |
| Plus | `start-button` (New group) | `index.html` |
| Gear | `admin-link` (System) | `index.html` |
| Chat bubble | `tab-chats` | `index.html` |
| Back chevron | `back-button` | `index.html` |
| Lock | `safety-button` | `index.html` |
| Network | `graph-open` (friend map) | `index.html` |
| Pen, sticker, undo | `draw-pen`, `draw-sticker`, `draw-undo` | `index.html` |
| Sound on and off | `video-sound` (two paths, CSS shows one) | `index.html` |
| Flash | `torch` (a slash path, CSS shows it) | `index.html` |
| Flip | `flip-camera` | `index.html` |
| Photo | Choose a photo | `index.html` |
| Shutter ring | `shutter` (not really an icon: a progress ring) | `index.html` |
| Star, archive, leave, bell, block | Row actions | `ROW_ICONS`, `app.js` |

The Profile tab shows your picture rather than an icon, on the web. On the iPhone it's still a symbol; "your picture as the Profile tab's icon" is noted as later in [plan-ios.md](../management/plan-ios.md).

A sprite would fix the copying: one set of `<symbol>`s at the top of `index.html`, and `<svg><use href="#close"/></svg>` at each use. It needs no build step and no change to the CSP, and suits this redesign if the web's icons change.

### Changing the app icon

The mark is an "n" in `--sage` on a dark background, a single arch with rounded ends. There's no generator in the repository: the PNGs are exported by hand.

| Platform | File | Notes |
|---|---|---|
| iPhone | [AppIcon.png](../../ios/Napsack/Assets.xcassets/AppIcon.appiconset/AppIcon.png) | 1024 × 1024, no transparency. iOS rounds the corners |
| Web, browser tab | [favicon.svg](../../server/static/favicon.svg) | The source of the shape, and the only vector besides Android's |
| Web, installed | `icon-192.png`, `icon-512.png` | "any maskable", so keep the mark inside the middle. Notifications also use `icon-192.png` (`sw.js`) |
| Web, iPhone Home Screen | `apple-touch-icon.png` | 180 × 180 |
| Android | `ic_launcher_foreground.xml`, `ic_launcher.xml`, `colors.xml` | The favicon's path, scaled |

These are compiled into the server by `web.rs`; a new file there needs a line there too. `tests/smoke_test.py` and `test_live.py` check that they're served.

The iPhone can also use a layered icon made in Apple's Icon Composer, which reacts to the system's glass look. Adding a `.icon` file replaces the asset catalog's icon, and Xcode generates a similar-looking version for older systems ([Apple's guide](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)). The app supports iOS 18 and up, so that fallback matters, and early reports of it were mixed: check it on an iOS 18 Simulator.

## Type

Both clients use the system font, and that's the only family anywhere.

| | Web | iPhone |
|---|---|---|
| Defined in | `--font`, `--step--1` (13px), `--step-0` (16px), `--step-1` (20px), `--step-2` (25px), `--step-5` (44 to 64px) | Text styles (`.headline`, `.subheadline`, `.caption`, `.footnote`, ...), which follow the person's text size |
| Bends the rule | Fixed sizes such as `0.75rem`, `0.7rem`, `11px`, `9px`: about 25 uses | `.system(size:)` only for icons, avatars' initials, large emoji, and captions |
| Wordmark | `.wordmark`, bold, in `--sage`, on the sign-in screen and the chat list | Only as the sign-in screen's title, as plain text. The chat list says "Chats" |

The iPhone's rule stays: use text styles, never a fixed size for words ([ios-onboarding.md](../ios-onboarding.md#screen-sizes-and-shapes)).

## Shapes and spacing

| | Web | iPhone |
|---|---|---|
| Small corners | `--radius-s` 6px: inputs, chips, cards | 10 to 12 points: notes on the camera, the QR code |
| Large corners | `--radius-m` 14px, in four places | 14 points: menus. 18 points: bubbles and the composer |
| Fully round | `999px` buttons, `50%` avatars and icon buttons | `Capsule()`, `Circle()` |
| A group's picture | A rounded square at 30% | A rounded square at 30% (aligned, Nate's pick, X17) |
| Spacing | `--pad` 1rem, `--bar-h` 3.5rem, `--tabs-h` 3.5rem | Typed in place, with system list spacing |
| Button height | 2.75rem | At least 44 points |

## Motion and feel

| | Web | iPhone |
|---|---|---|
| Opening a pic | 10 seconds; the bar drains and the photo blurs and sinks into the green. Taps move on | No timer or fade in `PicViewer.swift`: a photo stays until tapped |
| Everything else | Small transitions of 150 to 220ms: `transition` and `@keyframes` throughout `style.css` | `.easeOut` from 0.15 to 0.3 seconds, one spring on swipe to reply |
| Haptics | None | `.sensoryFeedback`: recording, a held message, a tap in a chat, a swipe, a new message |
| Reduced motion | Respected (`prefers-reduced-motion` blocks) | Nothing reads the setting, and any new fade must |

## Where the iPhone and web differ

Every row needs one of three answers: align them, keep the difference on purpose, or later.

| Thing | Web | iPhone |
|---|---|---|
| Appearance | Always dark | Follows the phone |
| Background | Forest green | System white or black |
| Messages | Transcript: left-aligned, 2px rule, sender's name above each run | Bubbles: mine on the right in accent at 30%, theirs in system gray |
| Waiting marker | Sage **square** for a pic, paper dot for a text | Accent **circle** for a pic, primary circle for a text |
| Pic in a chat | Bordered chip with the square marker | Accent label with a filled icon |
| Avatar with no picture | Paper initial on one of six muted tints | Accent initial on an accent tint, the same for everyone |
| Top of the chat list | Wordmark, then Friends and + on the right | "Chats", with Friends on the left and New group on the right |
| New group icon | Plus, on a soft circle | Three people |
| Requests badge | Sage | Red |
| Errors | Soft `--danger` | System red |
| Swipe actions | Words behind the row; on a computer, small round icons | Five system-tinted colors |
| Pen | Six colors, two widths, stickers | One red pen, one width, no stickers |
| A pic opening | Fade and timer | Neither; opens filling the screen ([X56](../management/plan.md#x56-pics-open-filling-the-screen)) |
| Layout | Two panes from 760px; tabs on phones | Tabs, always |

Already aligned: the accent's value, the system font, a group's shape, the words, and the caption's whole look.

## What the redesign can't change freely

**Rules that outlast any look:**

- **The caption is one look on every client:** the black strip at 55%, its size and padding, and its position. A sender's preview has to match what recipients see, so any change lands on every client together and has to keep working on pics already sent. Rule: [pic-framing.md](../implementation/pic-framing.md). Code: `CaptionLook` in `Framing.swift`, `.snap-caption` and `.viewer-caption` in `style.css`.
- **The word is "pic":** "snap" never shows in the interface, and `test_chat.py` checks. Internal names stay as they are.
- **Text is text:** user text renders with `textContent` on the web, and no decoration goes in through `innerHTML`.
- **The web's CSP and no build step:** no inline styles or scripts, no third-party fonts, scripts, or CDNs. A new file in `server/static/` needs a line in `web.rs`.
- **Every iPhone, at every text size:** 320 to 669 points wide, Dynamic Type, safe areas, 44-point tap targets, and no screen sizes in code ([the rules](../ios-onboarding.md#screen-sizes-and-shapes)).
- **Non-production marks** go on top of the design, which never accounts for them.

**Things that have to stay visible, because of a promise or a reviewer:**

- The encryption lock and safety codes; the warning when someone's key changes; the note in each group that its name, picture, and reactions aren't encrypted.
- Report and Block ([App Review 1.2](report-and-block.md)), Delete account, and the `@username` wherever a display name differs, so a name can't impersonate anyone.
- Status always has its icon and a label, never color alone ([metrics.md](../implementation/metrics.md)).

**Decisions already made, to reopen only on purpose:**

- A group's picture is a rounded square, a person's a circle (Nate, X17).
- The tabs are Chats, Camera, and Profile ([plan-ios.md](../management/plan-ios.md)).
- The camera's buttons are 48-point circles, with flip beside the shutter (Nate, 2026-11-03).
- Pics fill the screen when they open on the iPhone ([X56](../management/plan.md#x56-pics-open-filling-the-screen)).
- Emoji-only texts are large, with no bubble ([X53](../management/plan.md#x53-texts-of-only-emoji-large-and-without-a-bubble)).

**A small one:** the six quick reactions are a display list, but they live with the encryption code (`REACTIONS` in `crypto.js`, `reactions` in `Texts.swift`). Changing them needs no new message format, because any one emoji is a valid reaction, but change both.

## Tests that know what things look like

Most tests go by role and label, so a redesign won't disturb them. These check looks directly, and will fail if the thing they check changes on purpose. Update them in the same change; a failure anywhere else is a real one.

| Test | Checks |
|---|---|
| `test_environment.py` | `theme-color` is `#1b2822` in production |
| `test_groups.py`, `test_marks.py`, `test_profile.py` | Group 30% and person 50% corners |
| `test_pic_framing.py` | Emoji-only sizes (48, 36, 16px), and the transparent `border-left` on `.msg`, which goes if the web moves to bubbles |
| `test_draw.py`, `test_pic_framing.py` | Pen colors by their labels (`Color #ff4d4d`, `Color #ffd23f`) |
| `test_roles.py` | Two buttons sharing a color and height |
| `test_people.py` | Long names end in "…" |
| The pixel check in [qr.md](../implementation/qr.md) | The QR code's modules and quiet zone, on screen |
| `FramingTests`, `EmojiOnlyTests` (iPhone) | The caption's look, and which texts count as only emoji |
| `NapsackUITests` (iPhone) | Buttons by accessibility label: change the words, and these change too |

## How to see a change

- **Web:** debug builds reload when a file in `server/static/` changes ([onboarding.md](../onboarding.md)). Look at desktop and 390px, as every visible change needs.
- **iPhone, quickly:** a `#Preview` in Xcode; its Variants button shows every text size. Environment Overrides, in the bar above the console, changes text size and light or dark while the app runs.
- **iPhone, at both extremes:** the `*LookTests` above, which draw at the smallest and largest phones. [ios-onboarding.md](../ios-onboarding.md#how-to-check) has the rest.
- **System look:** the Mac tests on iOS 27 and 26, and the app supports back to 18. Standard bars, tabs, and sheets take on each system's own look without any code, so they won't look the same across those versions. Check it on the oldest as well as the newest.
