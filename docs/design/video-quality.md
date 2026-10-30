# Video quality (decision)

Status: **needs a decision from Nate** ([F20](../management/plan.md#f20-better-video-quality)). Researched and measured 2026-10-30.

Nate (2026-10-29): "the video quality is pretty low." This page puts the options next to numbers so the call can be made. It covers the web app (desktop and phone) and the iOS app; Android, when it comes, gets whatever is chosen here.

## The short version

1. **The iOS app sends far worse video than the web.** Its export preset (`AVAssetExportPresetMediumQuality`, [Camera.swift](../../ios/Napsack/Camera.swift)) makes **568×320** video at about 0.75 Mbit/s. That's measured, not guessed. It scores 9–22 on VMAF, where the web's 720p scores 47–57. No one has the app yet, so nobody has received one of these, but it must be fixed before TestFlight.
2. **The web uses half the size it's allowed.** 10 seconds at 1.5 Mbit/s plus sound is about 1.9 MB, against a 4 MB cap. Production's six videos so far are 1.1–1.7 MB.
3. **The web asks for the weakest H.264 profile** (Baseline, `avc1.42E01E`). High plays on every device that plays MP4, and is better at the same size. Level 3.0 is also technically too low for 720p (3.1 is right).
4. **Doubling to about 3 Mbit/s at 720p is the step a person notices.** It adds about 9–12 VMAF points, which is 1.5–2 "just noticeable differences". Most of that gain arrives by 2.5 Mbit/s.
5. **1080p doesn't help at these sizes.** Below about 4.5 Mbit/s it looks the same as 720p or worse.
6. **Stay on H.264 in MP4.** It's the only format that records in Safari and Chrome and plays everywhere. HEVC and AV1 leave some people unable to play what they're sent.

**Suggested:** ship 1 to 3 below now. None needs the server. Then decide on 4, raising the cap to 6 MB so both apps can use about 3 Mbit/s with room to spare. Details are under [Suggestion](#suggestion).

## Today

| | Web (desktop and phone) | iOS app |
|---|---|---|
| How | Camera → `<video>` → canvas (zoom, mirroring, scaling) → `MediaRecorder` ([app.js](../../server/static/app.js), `startRecording`) | AVFoundation records a movie, then `AVAssetExportSession` with the MediumQuality preset turns it into MP4 |
| Size | Longest edge 1280 px (720p from a landscape or portrait camera), 30 fps | **568×320** |
| Format | H.264 **Baseline** + AAC in MP4 (Safari, newer Chrome); VP8 + Opus in WebM otherwise (Firefox) | H.264 Main + AAC in MP4 |
| Bitrate | 1.5 Mbit/s video, 64 kbit/s sound | About 0.75 Mbit/s (fixed by the preset) |
| 10 seconds | About 1.9 MB | About 0.9 MB |

The server's limits are `FADE_VIDEO_MAX_KB` (4096, so 4 MiB) and `FADE_VIDEO_MAX_SECONDS` (10), sent to every app in `/api/config`. Videos are end-to-end encrypted, so the server can't re-encode or strip anything. Every choice here happens on the sender's device, and the re-encode is also what strips the camera's metadata.

**In production (read-only, 2026-10-30):** 6 videos in all, 1.1–1.7 MB (median 1.48 MB); photos have a median of about 150 KB. The data volume is 960 MB, 8% used. Uploads stop when less than 150 MB is free (`guard.rs`), which leaves about 738 MB for pics and videos waiting to be opened.

## How the numbers were made

VMAF (v0.6.1, Netflix's measure of how a video looks against the original) was run on three standard 1080p test clips, chosen to cover easy to hard:
- *town* (old_town_cross): still, fine detail;
- *jelly* (Jellyfish): texture and gentle motion;
- *crowd* (crowd_run): extreme motion and detail, the worst case.

Each was encoded with **VideoToolbox**, Apple's hardware encoder (the one behind Safari's `MediaRecorder`, iOS's exporter, and `AVAssetWriter`), through ffmpeg on a Mac. The outputs were scaled back to 1080p and scored.
- **Scale:** 100 means indistinguishable from the original. About 6 points is one "just noticeable difference" ([Ozer, on Netflix's VMAF](https://streaminglearningcenter.com/blogs/finding-the-just-noticeable-difference-with-netflix-vmaf.html)).
- **The phone model:** VMAF also has a phone model for small screens, which is closer to how napsack is watched. It is shown in parentheses where it was run.
- **The iOS presets:** these were measured by running the real `AVAssetExportSession` presets (macOS uses the same presets as iOS) on a 1080p30 H.264 source.

Treat these as comparisons between options, not absolute scores:
- A browser's real-time recorder is probably a little worse than ffmpeg's VideoToolbox.
- Scoring against 1080p is harsh for a phone screen.
- Nothing here replaces looking at clips on a real iPhone and a real Android phone.

## Measurements

### 720p, by bitrate and format

VMAF for *jelly / town / crowd*. Higher is better.

| 720p | 1.5 Mbit/s | 2.5 | 3.0 | 4.5 | 6.0 |
|---|---|---|---|---|---|
| H.264 **Baseline** (the web today) | 46.7 / 55.1 / 19.9 | 58.1 / 63.2 / 26.8 | 61.4 / 65.2 / 30.8 | 66.7 / 68.4 / 40.2 | 69.4 / – / – |
| H.264 **High** | 52.1 / 56.9 / 22.3 | 61.7 / 64.4 / 29.9 | 64.2 / 66.3 / 34.2 | 68.3 / 69.2 / 43.1 | 70.4 / 70.8 / 49.2 |
| H.264 High, phone model | (69.5 / 76.2 / 36.2) | (76.7 / 82.2 / 46.1) | (78.2 / 83.6 / 51.3) | (80.3 / 85.6 / 61.1) | |
| HEVC | 51.0 / 65.8 / 41.0\* | 61.5 / – / – | 65.1 / 72.1 / 43.5\* | 68.5 / – / – | |
| AV1 (software encoder) | 60.6 / 72.3 / 34.7 | 66.5 / – / – | 67.8 / 73.1 / 45.9 | | |
| VP8 (Firefox's fallback) | 39.1 / 26.2 / 32.1\* | 54.5 / – / – | 60.6 / 40.7 / 33.2\* | | |

\* The encoder went well over the bitrate it was given (see [Overshoot](#overshoot)), so this score was bought with a bigger file.

What it says:
- **Baseline → High** at 1.5 Mbit/s: +2 to +5 points, at no cost in size.
- **1.5 → 3 Mbit/s** (High): +12 / +9 / +12 points, about two noticeable steps. 2.5 Mbit/s gets most of the way.
- **Diminishing returns:** VideoToolbox's H.264 levels off. *Jelly* at 720p reaches only 74 even at 20 Mbit/s, so past about 4.5 Mbit/s more bits buy little.
- **HEVC** depends on the content: about half the bits for the same look on *town*, no saving on *jelly*.
- **VP8** (what Firefox sends) is clearly the worst. It can't be avoided there: Firefox records only WebM.

### 720p or 1080p

| H.264 High, *jelly / town / crowd* | 1.5 Mbit/s | 3.0 | 4.5 | 6.0 |
|---|---|---|---|---|
| 720p | 52.1 / 56.9 / 22.3 | 64.2 / 66.3 / 34.2 | 68.3 / 69.2 / 43.1 | 70.4 / 70.8 / 49.2 |
| 1080p | 45.9 / 55.8 / 35.4\* | 61.4 / 68.1 / 35.7\* | – / 71.5 / 40.3 | – / 73.3 / 46.9 |

At the same bitrate, 1080p is worse on *jelly* and only slightly better on *town* until 4.5–6 Mbit/s. On *crowd*, the 1080p encoder overshot 1.5 Mbit/s to 3.9 (+160%). Others have seen the same: Hotstar found 1080p fell below 720p under about 2.4 Mbit/s ([Hotstar](https://blog.hotstar.com/video-encoding-recipes-for-live-cricket-21f875080932)).

### The iOS export presets

| Preset | Output | Bitrate | 10 seconds | VMAF *town / jelly* |
|---|---|---|---|---|
| LowQuality | 224×128 | 0.13 Mbit/s | 0.16 MB | |
| **MediumQuality (today)** | **568×320, H.264 Main** | **0.71–0.75** | **0.9 MB** | **8.8 (16.2) / 21.6 (35.2)** |
| 640x480 | 640×360 | 2.4 | 3.0 MB | 13.6 / 32.8 |
| 960x540 | 960×540 | 4.8 | 6.0 MB (over the cap) | |
| 1280x720 | 1280×720 | 7.4–7.6 | 9.3 MB (over the cap) | 64.3 (81.5) / – |
| 1920x1080, HighestQuality | 1080p H.264 | 10.5–10.8 | 13 MB | |
| HEVC1920x1080, HEVCHighestQuality | 1080p HEVC | 8.7–9.2 | 11 MB | |

Notes on the presets:
- **No bitrate control.** Each preset picks its own bitrate; Apple doesn't document what each one produces ([export presets](https://developer.apple.com/documentation/avfoundation/export-presets)).
- **What fits the cap:** only the three smallest fit 4 MB in 10 seconds.
- **`fileLengthLimit`:** it cuts the file at a size; it doesn't lower the quality to fit.

**The fix is to encode it ourselves:** `AVAssetReader` + `AVAssetWriter`, with H.264 at 1280×720, High profile (`AVVideoProfileLevelH264HighAutoLevel`), `AVVideoAverageBitRateKey` set explicitly, and AAC at 64 kbit/s. It's the same hardware encoder as the "720p H.264 High" row above: about 61–66 instead of 9–22. The bitrate must be set explicitly, because the writer's defaults are far above our cap ([Apple forums](https://developer.apple.com/forums/thread/90902)).

The iPhone's own camera records 1080p30 at about 17 Mbit/s (H.264) or 8 Mbit/s (HEVC), so the source is excellent. All the loss is in the export.

## What each browser can do

### Recording (`MediaRecorder`)

| | Formats it records | Choosing the H.264 profile | Does it keep to the bitrate? |
|---|---|---|---|
| **Safari, iPhone and Mac** | MP4 (H.264 + AAC). From 18.4 (March 2025) also WebM (VP8/VP9) and MP4 with HEVC or AV1 (AV1 only with hardware) ([WebKit 18.4](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/)) | Yes: `avc1.64…` gives High, `avc1.4D…` Main; the default is Baseline ([WebKit bug 226219](https://bugs.webkit.org/show_bug.cgi?id=226219)) | Yes, lands 10–13% under. With no bitrate set, about 10 Mbit/s ([addpipe](https://blog.addpipe.com/mediarecorder-video-bitrates/)) |
| **Chrome, desktop (126+)** | MP4 (H.264 + AAC, VP9, AV1), WebM (VP8, VP9, AV1) ([blink-dev](https://groups.google.com/a/chromium.org/g/blink-dev/c/YJ1QijNiHeM)) | Yes, passed to the hardware encoder. The software fallback (OpenH264) is Baseline only | Yes, within about 10% |
| **Chrome, Android** | The same, through the phone's hardware encoder | The same | **No: overshoots.** 1.5 asked gave 2.0 (+35%); 7 asked gave 9.6 at 1080p ([addpipe](https://blog.addpipe.com/mediarecorder-video-bitrates/)) |
| **Firefox** | WebM only (VP8/VP9 + Opus); no MP4 ([bug 1631143](https://bugzilla.mozilla.org/show_bug.cgi?id=1631143)) | – | Yes |

When Chrome is asked for a plain `video/mp4` and has no hardware H.264 that matches, it records VP9 in MP4. Today's list asks for `video/mp4` second, so a Chrome without hardware H.264 sends VP9.

### Playing

| | iPhone and Mac Safari | Chrome (desktop, Android) | Firefox |
|---|---|---|---|
| H.264 (any profile, High included), MP4 | Yes | Yes | Yes |
| HEVC | Yes (iOS 11+, macOS 13+) | Only with a hardware decoder | Recent, depends on the system ([caniuse](https://caniuse.com/hevc)) |
| VP8/VP9 WebM | iOS 17.4+ fully ([caniuse](https://caniuse.com/webm)) | Yes | Yes |
| AV1 | Only with hardware: iPhone 15 Pro and later, M3 Macs and later ([caniuse](https://caniuse.com/av1)) | Yes | Yes |

**H.264 in MP4 is the only format that every sender can make and every recipient can play.** Sending HEVC or AV1 would need each sender to know what every recipient can play, groups included.

## Size, the cap, and length

Each cell is what fits per second: **total bitrate / video bitrate**, in Mbit/s. "Video" leaves 64 kbit/s for sound and **20% headroom** for overshoot. Caps are in MiB, as `FADE_VIDEO_MAX_KB` counts them.

| Cap | 10 seconds | 15 s | 20 s | 30 s |
|---|---|---|---|---|
| 4 MB (today) | 3.36 / **2.7** | 2.24 / 1.8 | 1.68 / 1.3 | 1.12 / 0.9 |
| 6 MB | 5.03 / **4.1** | 3.36 / 2.7 | 2.52 / 2.0 | 1.68 / 1.3 |
| 8 MB | 6.71 / **5.5** | 4.47 / 3.7 | 3.36 / 2.7 | 2.24 / 1.8 |
| 12 MB | 10.07 / **8.3** | 6.71 / 5.5 | 5.03 / 4.1 | 3.36 / 2.7 |

| Video bitrate (H.264, 720p) | Looks | Smallest cap, 10 seconds | 30 seconds |
|---|---|---|---|
| 1.5 Mbit/s | Today's web | 4 MB | 12 MB |
| 2.5–3 | Good; the noticeable step up | 4 MB (tight at 3) or 6 MB (comfortable) | Over 12 MB |
| 4.5–6 | Near the encoder's ceiling | 8 MB | Over 12 MB |

**Longer videos and better videos pull against each other.** At today's 4 MB, 30 seconds would mean 0.9 Mbit/s: worse than now.

### Overshoot

Encoders go over their bitrate on hard, fast-moving scenes:
- **Measured here:** at 720p, +37% at a 1.5 Mbit/s target (*crowd*), and at most +4% from 2.5 Mbit/s up. At 1080p, +160% at 1.5 Mbit/s.
- **Chrome on Android:** +35% in published tests. Android 12 and later keep a quality floor that ignores the bitrate when the picture gets hard ([MediaCodec](https://developer.android.com/reference/android/media/MediaCodec)).

A file over the cap is refused, and today the web says "too large to send". So any increase needs headroom, or a second try at a lower bitrate when the file comes out too big (see [option 9](#options)).

**On the web, Chrome and Android run two encoders at once.** A silent copy records alongside the main one so "send without sound" is instant (X37; not on iPhones, `ONE_RECORDER`). A higher bitrate doubles that encoder load too. That's worth watching on slow Android phones, and is one more reason to test on one.

## Upload time and cost

| Size | 5 Mbit/s upload | 10 Mbit/s | 25 Mbit/s |
|---|---|---|---|
| 2 MB (the web today) | 3.4 s | 1.7 s | 0.7 s |
| 4 MB | 6.7 s | 3.4 s | 1.3 s |
| 6 MB | 10.1 s | 5.0 s | 2.0 s |
| 8 MB | 13.4 s | 6.7 s | 2.7 s |
| 12 MB | 20.1 s | 10.1 s | 4.0 s |

The best US carrier's median mobile upload is about 12 Mbit/s (T-Mobile, second half of 2025, [RCR Wireless](https://www.rcrwireless.com/?p=428028)). A typical phone falls between the 5 and 10 columns, and worse on a weak signal.

**Money barely matters. Disk does.**
- **Egress:** each video is downloaded once per recipient (more in a group). At $0.09/GB that's $0.38 per 1,000 4 MB videos, or $0.57 at 6 MB. The first 100 GB of egress each month is free ([EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/)), so napsack's real cost is $0.
- **The disk:** an EBS gp3 volume costs about $0.08 per GB-month, billed for its whole size whether it's full or not. The limit is room, not money.

| Unopened at once | 4 MB videos | 6 MB | 8 MB | 12 MB |
|---|---|---|---|---|
| Fit in today's ~738 MB of room | ~180 | ~120 | ~90 | ~60 |
| In a 5 GB volume (~$0.40/month) | ~1,200 | ~800 | ~600 | ~400 |

Videos wait at most 30 days, and are discarded when opened. A group video is stored once for the whole group ([group-encryption.md](../implementation/group-encryption.md)), but it's downloaded once per member. With the six videos sent so far, there's no pressure today.

**Growing the volume** is an in-place change to `aws_ebs_volume.data` plus growing the filesystem. Under Rule 1 that means the full procedure (snapshot, read the plan, check the row counts), and it's Nate's decision. It isn't needed for a 6 MB cap at today's use.

## The canvas

The web draws each camera frame onto a canvas (for zoom, mirroring the front camera, and scaling to 1280) and records the canvas. That costs some quality:
- **Extra conversions** of every frame, and a downscale with the browser's default "low" smoothing, which softens or jags edges.
- **Frame timing:** `requestAnimationFrame` follows the screen and slows when the page is busy or the phone saves power, so frames get dropped or repeated against the 30 fps recording.
- **Fragility:** WebKit has had canvas-recording bugs ([WebKit bug 229611](https://bugs.webkit.org/show_bug.cgi?id=229611)), and napsack's `ONE_RECORDER` workaround shows the iPhone home-screen path is delicate.

There are three ways forward:
- **Cheap: improve the canvas.** Set `imageSmoothingQuality = "high"` and draw on `requestVideoFrameCallback` (once per camera frame). This should be sharper and smoother; it wasn't measured here.
- **Bigger: record the camera directly** when there's no digital zoom and no mirroring. The frames go straight to the hardware encoder. Mirroring would then become a flag every app has to honor on playback, iOS included.
- **WebCodecs:** full control (exact profile, bitrate mode, size), but it needs an MP4 muxer dependency, and iOS Safari supported it only partly until 26 ([caniuse](https://caniuse.com/webcodecs)). Later, if ever.

## Options

Cheapest and safest first.

| # | Option | Gain | Risk | Work |
|---|---|---|---|---|
| 1 | **iOS: our own encode** (`AVAssetWriter`, 720p H.264 High, about 2.5 Mbit/s) | Very large: 320p → 720p, +40–50 VMAF | Very low; H.264 plays everywhere | iOS only; about 3.3 MB per 10 s, inside today's cap |
| 2 | **Web: ask for High first** (`avc1.64001F`, then `avc1.4D401F`, then `avc1.42E01F`, then today's list) | +2–5 VMAF, free | Very low; the list falls back | One line |
| 3 | **Web: canvas smoothing and frame timing** | Sharper, steadier (not measured) | Low | A few lines; check on an iPhone home-screen app |
| 4 | **Raise the cap to 6 MB and aim for about 3 Mbit/s** (web and iOS) | +9–12 VMAF over today's web (two noticeable steps), with room for overshoot | Low; server first (the API only grows) | `FADE_VIDEO_MAX_KB=6144`, then both apps read `video_max_bytes` and aim under it |
| 5 | **About 2.5 Mbit/s inside today's 4 MB** | +7–10 VMAF | Some "too large" on Android or fast motion | One number per app |
| 6 | **Record the camera directly** when there's no zoom or mirroring | Smoother, sharper | Medium: the iPhone recorder's history; mirroring needs every app | Moderate; real phones needed |
| 7 | **1080p at 4.5–6 Mbit/s** | Only on still, detailed scenes | Low | An 8 MB cap; twice the upload time |
| 8 | **HEVC, AV1, or VP9 for sending** | 0–45% fewer bits | High: some recipients can't play it | Needs knowing what each recipient plays |
| 9 | **A second try when too big:** re-encode once at a lower bitrate instead of refusing | Fewer failed sends with any of the above | Low | iOS: easy (a second `AVAssetWriter` pass). Web: needs WebCodecs or re-recording, so maybe iOS only |
| 10 | **Longer videos** (15–30 s) | – | Low | Each step costs quality unless the cap grows with it |

## Suggestion

1. **Now, without asking the server for anything:** 1, 2, and 3.
   - These bring the iOS app from far behind the web to a little ahead, and give the web its free improvements.
   - The iOS app aims for about 2.5 Mbit/s so it fits today's 4 MB with headroom.
2. **Then, if the result still looks low:** 4.
   - Release the server with `FADE_VIDEO_MAX_KB=6144` first.
   - Then both apps aim for about 3 Mbit/s, worked out from `video_max_bytes` and `video_max_seconds` in `/api/config` rather than a fixed number. That way the cap can change later without a client release.
   - Today's disk holds about 120 unopened 6 MB videos, far more than today's use. Grow the volume only when the Metrics tab shows the need.
3. **Stay on 720p and H.264.** Look at 1080p or HEVC again only if longer videos or caps of 8 MB and up are wanted.
4. **Whatever is chosen, test on real phones:**
   - an iPhone (Safari and the home-screen app) and an Android phone, recording something fast-moving;
   - check the sizes stay under the cap;
   - add a browser check that the chosen `mimeType` and bitrate are the ones used (`test_video.py`).

## Decisions for Nate

- **Go ahead with 1–3?** None of them changes the server or the cap.
- **Raise the cap to 6 MB (option 4)?** It's a setting (`FADE_VIDEO_MAX_KB`), not a migration. It needs a release before the apps can use it.
- **Keep 10 seconds?** Longer clips trade directly against quality at any cap (the size table).
- **When to grow the data volume:** not needed for this. When it is, it follows the Rule 1 procedure.
