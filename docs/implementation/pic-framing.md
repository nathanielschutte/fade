# What you see is what they see: framing and captions

Nate (2026-11-05): what's on the sender's screen before sending is exactly what recipients see, the picture's framing and its caption both, on every client. This is the one rule; the rest is how each client keeps it. Plan: [X52](../management/plan.md#x52-a-photo-from-the-library-shows-whole-before-its-sent), [X54](../management/plan.md#x54-captions-look-the-same-everywhere).

No message format changes: a pic is still a photo (or video), a caption, and where the caption sits (`y`). Framing is done by cropping the photo before it's sealed, and the caption's look is a rule every client draws by.

## The picture

Recipients see the whole photo they're sent, as large as it fits (letterboxed on black), so the sender sends exactly what their screen shows:

- **A photo just taken** is shown as the camera showed it. Where that's the photo filling the screen (the iPhone: aspect fill), it's cropped to the screen's shape, centered, before it's sent. Where the camera shows the whole frame (the web: `object-fit: contain`), nothing's cut. It can't be zoomed or moved (Nate).
- **A photo from the library** starts whole, as large as it fits. A pinch zooms it, 1× to 4× (on a computer, the trackpad's pinch or Ctrl/⌘ with the scroll wheel), and once zoomed, a drag moves it, kept so no gap opens where the photo is larger than the screen. What's sent is the part of the photo on screen: where the photo and the screen overlap. Zoomed all the way out, that's the whole photo.
- **Drawing** (and stickers on the web) are kept in the photo's pixels, so they move with it as it's zoomed. They're flattened into the photo first, then it's cropped.
- What's sent is still at most 1280 pixels on its longest side; a crop is never scaled up. On the web it's cut from the picked file itself, not the smaller copy made when it was picked, so a zoomed-in crop stays sharp.
- **Videos** aren't cropped yet: the iPhone shows a video filling the screen but sends the whole frame (X55).

## The caption

One look on every client, set by the picture's width as shown (W) so it covers the same part of the picture at any size, on any screen:

| | |
|---|---|
| Strip | Across the picture's whole width, nothing past its edges; its middle at `y` × the picture's height (`y` 0 top, 1 bottom, kept between 0.08 and 0.92) |
| Background | black at 55% (`rgba(0, 0, 0, 0.55)`), square corners |
| Text | the system font (`-apple-system, system-ui, sans-serif` on the web), regular, white, centered |
| Size | 0.044 × W (17 points on a 390-point-wide picture); lines 1.25 × that apart |
| Padding | 0.5 × the size above and below, 1 × at the sides |
| Wrapping | at spaces; a word too long for a line breaks anywhere |
| Length | at most 5 lines as the sender writes it, and 200 characters. Return (Enter) finishes it; there are no line breaks in it |

Recipients draw every line it has (another system's font can wrap a little differently; nothing is cut off). While it's being written it's the same strip, the same size, with a cursor; it may be lifted above the keyboard while typing, and goes back to its place after.

The "picture" is the part of the photo on screen: for a photo shown whole, the photo; for a zoomed-in one, the part of the screen it covers. That part is what's sent, so the caption sits on the same part of the same picture for recipients.

Pics sent before this (with captions placed against the screen, or no `y`) are drawn by the same rule; where there's no `y`, at 0.8.
