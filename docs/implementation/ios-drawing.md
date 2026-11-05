# Drawing on a pic in the iOS app

[`ios/Napsack/Drawing.swift`](../../ios/Napsack/Drawing.swift) is the pen you draw on a photo with before sending it. It's under 120 lines, kept small on purpose so it's easy to build on (Nate, 2026-10-30: our own pen, not PencilKit). This is a jumping-off point for changing it: how it's laid out, the one idea that makes it work (points versus pixels), how to try a change quickly, and a few first projects. Read it with the file open. Xcode and SwiftUI basics are in [ios-onboarding.md](../ios-onboarding.md).

## Where it's used

After a capture, the camera screen ([`Camera.swift`](../../ios/Napsack/Camera.swift), `CameraScreen`) shows the photo frozen in place. The buttons on the right are **Aa** (a caption) and the **pen** (a squiggle). The pen turns drawing on: a finger draws red lines, **Done** turns it off, and the round arrow undoes the last line. **×** (Retake) throws everything away, and **Send** sends the photo with the lines in it.

Videos can't be drawn on, only photos (the web is the same).

## How the file is laid out

Three pieces, top to bottom:

| | What it is |
|---|---|
| `struct Stroke` | One line: the points the finger went through, and how thick it is. Both in the **photo's pixels** (next section). |
| `enum Pen` | The pen's settings (`color`, `width`) and the math: where a point on the screen is in the photo and back (`scale`, `toImage`, `toScreen`), a line through the points (`path`), and drawing the lines into the photo for sending (`flatten`). An `enum` with nothing in it is Swift's way of grouping functions under a name. |
| `struct PenLayer` | The SwiftUI view laid over the photo: it draws the lines, and while the pen is on, follows a finger to make more. |

**Where the strokes live.** `CameraScreen` keeps them: `@State private var strokes: [Stroke]`, and `penOn` for whether the pen is on. `@State` is a value SwiftUI keeps for the screen; when it changes, what shows it is drawn again. `CameraScreen` hands the strokes to `PenLayer` as `$strokes`, a **binding**: a way for a child view to change its parent's state. So:

- While a finger moves, `PenLayer` collects points in its own `@State var current` (the line being drawn) and draws it.
- When the finger lifts, it appends a `Stroke` to `strokes`, the parent's list.
- Undo is `strokes.popLast()`, and Retake sets `strokes = []` (both in `CameraScreen`).

`PenLayer` draws with a `Canvas`, SwiftUI's quick way to draw many shapes, and follows the finger with `DragGesture(minimumDistance: 0)`, a drag that starts the moment the finger touches (so a tap leaves a dot). With the pen off, the layer ignores touches (`allowsHitTesting(drawing)`), so taps reach the photo underneath (a tap there starts a caption).

## Points and pixels

SwiftUI measures the screen in **points**: an iPhone 16 Pro is 402 × 874 points, and 1206 × 2622 pixels (three per point each way). A photo is measured in **pixels**. On the camera screen a photo is kept at most 2880 pixels on its longest side (`Captured.photo`, in `Camera.swift`), so one from a 12-megapixel camera (3024 × 4032) is 2160 × 2880 there. (In code, `UIImage.size` is in points too, but these photos have a scale of 1, so their size is their pixels. That's why `flatten` and the compressor set `format.scale = 1`.)

On screen, a photo just taken fills the screen, cut off at two sides where its shape differs (aspect fill, as the camera shows it). A photo from the library is shown whole instead (X52): `CameraScreen.stage` gives the largest box of the photo's own shape that fits, and the pen draws in that box, where filling and fitting are the same thing. `Pen.scale(image:box:)` is how much it's shrunk: the larger of the two ratios, screen width over photo width and screen height over photo height. Say that 2160 × 2880 photo on a 390 × 844-point screen (an iPhone 17e):

- scale = max(390 / 2160, 844 / 2880) = max(0.181, 0.293) = **0.293**
- shown 633 points wide (2160 × 0.293): 121.5 points cut off each side
- a finger in the middle of the screen, (195, 422), is the middle of the photo: `Pen.toImage` gives pixel (1080, 1440)
- the pen's 6 points on screen are 6 / 0.293 ≈ **20 pixels** in the photo

Strokes are kept in the photo's pixels, not the screen's points, so they stay where they were drawn on any screen (an SE or a Pro Max), and they line up when they're drawn into the photo itself. `toImage` and `toScreen` undo each other; `DrawingTests` checks that.

## Into the photo, before it's encrypted

When you tap Send, `CameraScreen.sendTapped` hands the photo and the strokes to `ReadyToSend.prepare` (in `Camera.swift`), which, off the main thread so the screen never stalls:

1. **Flattens** them: `Pen.flatten(image, strokes:)` draws the photo at its own size into a new image, then each stroke on top (red, round ends and corners, its own width). The result is one plain picture: the lines are now pixels of the photo.
2. **Compresses** it: `Conversation.photoJPEG` makes a JPEG at most 1280 pixels on its longest side, under the server's limit. The lines shrink with the photo (20 pixels become about 9).
3. Then each chat it goes to **seals** its own copy of those same bytes (`Conversation.sendPhoto`, formats 6 and 7). Flattening and compressing happen once, however many chats it's sent to.

This must stay so. Nothing about the drawing travels on its own: whoever opens it, on the web, the iOS app, or Android later, just sees a photo. A drawing sent as a separate layer would be a new message format, which every client would have to learn before anyone could send it ([CLAUDE.md](../../CLAUDE.md), Code standards), and an app could show the photo without it. The web's pen works the same way (`server/static/draw.js`, `flatten`).

## Trying a change quickly

- **Xcode's canvas.** Open `Drawing.swift` and show the canvas (⌥⌘↩). Its `#Preview("Pen")` at the bottom is the pen on its own over a gray stand-in photo: draw on it with the mouse, and tap Undo. It updates as you edit, in a second or two, without running the app. Good for colors, widths, and how lines look.
- **The Simulator.** Run the app (⌘R) with your local server (ios-onboarding.md, "Pointing the app at your own server"). The Simulator has no camera, so open a chat and tap the **photo button** next to the message box, or the Camera tab's photo button, and pick one of the Simulator's sample photos. It opens frozen in place, ready to draw on. Send it to a second account in a browser to see what arrives.
- **The tests.** `DrawingTests.swift` has two: a stroke drawn on the screen lands in the photo where it was drawn (it reads a pixel's color), and screen and photo points map back and forth. `CameraSendTests` checks a stroke is still in the photo after it's compressed and sealed. Run them from Xcode (the diamond next to a test, or ⌘U for all), or:
  ```sh
  ONLY=NapsackTests/DrawingTests bash scripts/test-ios.sh
  ```
  Add a test next to them for anything new: draw, flatten, then read the pixel where it should be (`aStrokeIsFlattenedIntoThePhoto` shows how).

## Starter ideas

Each with where to make it. The web already has three of these (colors, two pen widths, and stickers, in `draw.js`), so its choices are a good place to start: both apps feel the same that way.

- **A color picker.** Give `Stroke` a color (`var color: UIColor`), and `PenLayer` the color to draw new strokes with; `Pen.color` becomes the default. In `CameraScreen.reviewControls`, while `penOn`, show a row of round swatches (at least 44 points each, like `CameraScreen.button`), keeping the picked one in a new `@State`. In `Pen.flatten`, set each stroke's own color inside the loop (`g.setStrokeColor(stroke.color.cgColor)`), and in `PenLayer`'s `Canvas` too. The web's six: white, near-black, red, yellow, sage green, and blue (`COLORS` in `draw.js`). Test: flatten a blue stroke and check the pixel is blue.
- **Pen width.** `Pen.width` is 6 points on screen. Each stroke already keeps its own width, so a thin and thick toggle only needs the width chosen in `CameraScreen` and handed to `PenLayer` (which divides by the scale, as it does now). The web's are 0.8% and 2% of the photo's width.
- **An eraser.** The web has none yet, so this one would be new on both apps (and the web's goes in [plan.md](../management/plan.md)). The simple kind removes whole lines: in eraser mode, a touch deletes any stroke with a point near the finger (closer than half its width, in the photo's pixels). Put the "which stroke is under this point" math in `Pen`, where a test can check it, and the mode in `PenLayer`. The kind that rubs out part of a line needs the lines on their own see-through layer, the eraser drawn with a clear blend mode (`.clear`), and that layer laid over the photo: erasing straight on the photo would erase the photo too. Undo then has to undo erasing as well: keep a list of what was done rather than just strokes, as `draw.js` does (`undo`).
- **Stickers.** An emoji you place, drag, and resize. A `struct Sticker` (the emoji, its center and size in the photo's pixels, like strokes), shown over the photo as `Text(emoji)` at `Pen.toScreen(center, ...)`, moved by a `DragGesture` (divide the finger's movement by the scale), resized by a `MagnifyGesture` (a pinch), and drawn into the photo in `Pen.flatten` (an `NSAttributedString` of the emoji, `draw(at:)`). The web's: 😂 😍 🔥 ✨ 👀 🎉 ❤️ 🌲.
- **Smoother lines.** `Pen.path` joins the points with straight lines, which shows when you draw fast. Curving through the midpoints between points (`addQuadCurve(to:control:)`) looks smoother.

## Rules that apply

- **Our own pen, not PencilKit** (Nate's decision).
- **Flattened into the photo before it's sealed**, always (above). No new message format for drawing.
- **Strokes in the photo's pixels**, so they land where they were drawn on any phone.
- **Off the main thread.** Drawing on screen is the interface, so it stays on the main thread, but keep it light: the `Canvas` draws every stroke again on each change, fine for hundreds. Heavy work (flattening, compressing) happens once in `ReadyToSend.prepare`, off it.
- **Big enough to hit.** New buttons are at least 44 points with room around them (Apple's guidelines), round and dark so they show on any photo (`CameraScreen.round`).
- **Tests and a look.** New logic gets a test ([CLAUDE.md](../../CLAUDE.md), "How every change is tested"), and anything you can see gets looked at on a small phone and a large one. `make ios` before pushing.
- **Every client.** The web's [`draw.js`](../../server/static/draw.js) is the other pen. Something new on one is considered for the other (and Android later), and what the other still needs goes in the plan ([plan-ios.md](../management/plan-ios.md), [plan.md](../management/plan.md)).
- **The words.** People see "pic", never "snap".
