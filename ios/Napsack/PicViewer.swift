import AVKit
import SwiftUI

/// A pic or video sent to you, shown once (app.js, the viewer): full screen,
/// its caption where the sender put it; a photo zooms and pans (OpenedPhoto).
/// It counts as opened the moment it's shown (Conversation.opened); closing
/// it before then leaves it unopened. Then its time runs (X58): a photo 10
/// seconds, a video its length, with a bar across the top running down and,
/// for a photo, a fade at the end, as on the web; then on to the next, or
/// closed. A tap moves on sooner. Nothing is saved: a video plays from a
/// temporary file that's deleted when it closes.
struct PicPage: View {
    let pic: PicToOpen
    let conversation: Conversation
    /// Who sent it, and where it is in the run ("2 of 3"), over the top.
    var from = ""
    var place: String?
    /// The longest a video can be (the server's `video_max_seconds`): one shows no longer.
    var longest: Double = PicPage.photoSeconds
    /// It's on screen: from now on it counts as opened.
    var onShown: () -> Void = {}
    /// Closes the viewer while it's still opening (a slow connection): it stays unopened.
    var close: (() -> Void)?
    /// Shown, and its time up, tapped past, or a video's end: on to the next, or closed.
    let next: () -> Void
    @State private var opened: OpenedPic?
    /// A photo's picture, decoded once it's opened.
    @State private var photo: UIImage?
    @State private var problem: String?
    @State private var player: AVPlayer?
    /// The app's audio is set for this video (VideoSound, D25), to put back as it closes.
    @State private var sounding = false
    /// A video's picture size, upright: its caption sits on the video, not the screen.
    @State private var videoSize: CGSize?
    @State private var shownAt: Date?
    /// How long it shows, once its time is running.
    @State private var showing: Double?
    /// Fading away at the end of its time, as on the web (a photo; not with Reduce Motion).
    @State private var greyed = false
    @State private var faded = false
    /// How much of it has come while it opens.
    @State private var arriving = Arriving()
    /// Each Try again: a new request.
    @State private var attempt = 0
    /// Moved on already (its time and a tap can end it together).
    @State private var ended = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Taps this soon after a pic appears don't count: a quick double tap
    /// shouldn't skip past a pic nobody saw (app.js, TAP_GUARD_MS).
    static let tapGuard: TimeInterval = 0.6
    /// How long a photo shows (app.js, VIEW_MS).
    static let photoSeconds: Double = 10
    /// A video moves on at its end; this long after its time, if it stalls (app.js).
    static let videoGrace: Double = 3

    /// How long it shows: a photo 10 seconds; a video its length, but no longer
    /// than the longest a video can be (a video that doesn't say runs that long).
    static func showFor(video duration: Double?, longest: Double) -> Double {
        guard let duration else { return photoSeconds }
        return duration.isFinite && duration > 0 ? min(duration, longest) : longest
    }

    /// A tap (once it's been on screen a moment): on to the next, or closed.
    private func tap() {
        if let shownAt, Date().timeIntervalSince(shownAt) < Self.tapGuard { return }
        if opened != nil || problem != nil { moveOn() }
    }

    private func moveOn() {
        guard !ended else { return }
        ended = true
        next()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let opened {
                Group {
                    if let photo {
                        OpenedPhoto(photo: photo, caption: opened.caption, y: opened.y, greyed: greyed, faded: faded, tapped: tap)
                    } else if let player {
                        // Videos don't zoom: they're short, and close at their end.
                        VideoPlayer(player: player).disabled(true)
                            .overlay {
                                if let videoSize {
                                    Color.clear.aspectRatio(videoSize, contentMode: .fit)  // the video's own place
                                        .overlay { PicCaption(text: opened.caption, y: opened.y) }
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem {
                VStack(spacing: 12) {
                    Text(problem).foregroundStyle(.white).multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        // A new request, on a new connection if the last one went bad (D26).
                        Button("Try again") { tryAgain() }.buttonStyle(.borderedProminent)
                        Button("Close") { moveOn() }.buttonStyle(.bordered).tint(.white)
                    }
                }
                .padding()
            } else {
                Opening(close: close, part: arriving.part)
            }
        }
        .overlay(alignment: .top) { PicHeader(from: from, place: place) }
        .overlay(alignment: .top) {
            if let showing { PicTimer(seconds: showing) }
        }
        .contentShape(Rectangle())
        // A photo takes its own taps (a double tap zooms, so a single one waits to be sure).
        .gesture(TapGesture().onEnded { tap() }, isEnabled: photo == nil)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap for the next one, or to close. It can't be opened again.")
        .accessibilityAction { tap() }
        .accessibilityIdentifier("pic-viewer")
        .statusBarHidden()
        .task(id: attempt) { await open() }
        .task(id: showing) {
            // Its time: then on, as if tapped (a stalled video a moment after its end).
            guard let showing else { return }
            try? await Task.sleep(for: .seconds(showing + (player == nil ? 0 : Self.videoGrace)))
            if !Task.isCancelled { moveOn() }
        }
        .onDisappear {
            player?.pause()
            if sounding {
                sounding = false
                VideoSound.shared.end()  // paused first, so it can be let go and the music comes back up
            }
            if let url = opened?.video { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func tryAgain() {
        problem = nil
        arriving = Arriving()
        attempt += 1
    }

    /// Fetches it, shows it (opened from then on), and starts its time.
    private func open() async {
        guard opened == nil else { return }
        do {
            let arriving = arriving, started = ContinuousClock.now
            // After a moment, how much has come: a slow connection that's moving shows it is.
            let got = try await TransferWatch.$watcher.withValue({ transfer in
                guard ContinuousClock.now - started > .seconds(1), let part = transfer.receivedPart else { return }
                Task { @MainActor in arriving.part = part }
            }) {
                try await conversation.open(pic)
            }
            if let data = got.image, let image = UIImage(data: data) {
                photo = await image.byPreparingForDisplay() ?? image  // decoded off the main thread, before it shows
            }
            guard !Task.isCancelled else {  // closed while it decoded: still unopened
                if let url = got.video { try? FileManager.default.removeItem(at: url) }
                return
            }
            opened = got
            shownAt = Date()
            conversation.opened(pic)
            onShown()
            if let url = got.video {
                videoSize = await VideoEncoder.uprightSize(url)
                let duration = try? await AVURLAsset(url: url).load(.duration).seconds
                guard !Task.isCancelled else { return }  // closed meanwhile: nothing to play, nothing to put back
                let player = AVPlayer(url: url)
                self.player = player
                // Heard, even with the ring switch on silent; music lowers meanwhile (D25).
                VideoSound.shared.begin()
                sounding = true
                player.play()
                showing = Self.showFor(video: duration, longest: longest)
                // Closes when it ends, as on the web.
                for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem) {
                    moveOn()
                    break
                }
            } else {
                let seconds = Self.showFor(video: nil, longest: longest)
                showing = seconds
                if !reduceMotion {  // the web's dissolve: grey from 30% of its time, gone by the end
                    withAnimation(.linear(duration: seconds * 0.7).delay(seconds * 0.3)) { greyed = true }
                    withAnimation(.linear(duration: seconds * 0.45).delay(seconds * 0.55)) { faded = true }
                }
            }
        } catch ServerError.refused(_, status: let status) where [404, 410].contains(status) {
            // Opened on another device, or expired, since: on to the next (app.js, `openPic`).
            moveOn()
        } catch {
            guard !Task.isCancelled else { return }  // closed while it opened: it stays unopened
            Reporter.shared.report(.warn, "opening a pic failed", Reporter.fields(error, ["video": String(pic.isVideo)]))
            problem = (error as? ServerError)?.retryable == true
                ? "Couldn't load this pic. It's still unopened: try again when your connection is better."  // the web's words
                : error.localizedDescription
        }
    }
}

/// How much of a pic has come while it opens (0 to 1), once it's taken a moment.
@MainActor @Observable final class Arriving {
    var part: Double?
}

/// The time a pic has left, running down across the top (app.js, `.viewer-timer`).
struct PicTimer: View {
    let seconds: Double
    @State private var left = 1.0

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.2))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * left)
                }
            }
            .frame(height: 3)
            .clearOfWindowControls(sizeToFit: true)
            .padding(.horizontal, 16).padding(.top, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { withAnimation(.linear(duration: seconds)) { left = 0 } }
    }
}

/// An opened photo, to look at closely (ZoomablePhoto: pinch, drag, double
/// tap), across the whole screen, with its caption where the sender put it
/// on the picture. It opens filling the screen when that cuts off only a
/// little, and zooms out to the whole photo (ZoomView.opening). The caption
/// hides while it's zoomed in: it would cover what you're looking at, and no
/// longer sit where they put it.
struct OpenedPhoto: View {
    let photo: UIImage
    let caption: String
    let y: Double?
    /// Its time running out: the picture goes grey, then fades and blurs away (the caption stays, as on the web).
    var greyed = false
    var faded = false
    /// A tap at the size it opened at (zoomed in or out, a tap goes back to it instead).
    let tapped: () -> Void
    @State private var zoomed = false
    @State private var picture: CGRect = .zero

    var body: some View {
        GeometryReader { screen in
            ZStack {
                ZoomablePhoto(image: photo, captionSpan: caption.isEmpty ? nil : CaptionLook.span(caption),
                              zoomed: $zoomed, picture: $picture, tapped: tapped)
                    .saturation(greyed ? 0 : 1)
                    .blur(radius: faded ? 18 : 0)
                    .brightness(faded ? -0.2 : 0)
                    .opacity(faded ? 0 : 1)
                if !caption.isEmpty, picture.width > 0 {
                    PlacedCaption(text: caption, y: y, picture: picture, safe: screen.safeAreaInsets)
                        .opacity(zoomed ? 0 : 1)
                        .animation(.easeOut(duration: 0.15), value: zoomed)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// A photo's caption on the picture where it is on screen (`picture`, as it's
/// zoomed), drawn as it was written (CaptionLook): its size goes with the
/// picture's. Where the picture runs past the screen's top or bottom (it
/// opened filling the screen), the caption stays on what shows, clear of the
/// screen's edges (`safe`).
struct PlacedCaption: View {
    let text: String
    let y: Double?
    let picture: CGRect
    let safe: EdgeInsets

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .captionStrip(width: picture.width)
                .position(x: picture.midX, y: Self.middle(text, y: y, picture: picture, screen: geo.size, safe: safe))
        }
    }

    /// Where the strip's middle goes: its place on the picture (CaptionLook.middle), kept
    /// on the part of the picture that's on screen.
    static func middle(_ text: String, y: Double?, picture: CGRect, screen: CGSize, safe: EdgeInsets) -> CGFloat {
        let h = CaptionLook.height(text, width: picture.width)
        let placed = picture.minY + CaptionLook.middle(y ?? CaptionLook.unplaced, text: text, picture: picture.size)
        let top = max(picture.minY, safe.top) + h / 2, bottom = min(picture.maxY, screen.height - safe.bottom) - h / 2
        return top <= bottom ? min(max(placed, top), bottom) : (top + bottom) / 2
    }
}

/// A pic's caption where the sender put it (0 top, 1 bottom; CaptionLook's
/// place if nil), drawn as it was written (CaptionLook), in a box the
/// picture's size.
struct PicCaption: View {
    let text: String
    let y: Double?

    var body: some View {
        if !text.isEmpty {
            GeometryReader { geo in
                Text(text)
                    .captionStrip(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: CaptionLook.middle(y ?? CaptionLook.unplaced, text: text, picture: geo.size))
            }
        }
    }
}

/// "Opening…", with Close beneath it: a slow connection mustn't keep you on a
/// black screen (a full-screen cover can't be swiped away).
struct Opening: View {
    let close: (() -> Void)?
    /// How much has come (0 to 1), when it's taking a while.
    var part: Double? = nil

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(part.map { "Opening… \(Int(($0 * 100).rounded(.down)))%" } ?? "Opening…")
                .tint(.white).foregroundStyle(.white)
            if let close {
                Button("Close", action: close).buttonStyle(.bordered).tint(.white)
            }
        }
    }
}

/// Over the top of a pic: who sent it, and "2 of 3" when there are more.
struct PicHeader: View {
    let from: String
    let place: String?

    var body: some View {
        if !from.isEmpty || place != nil {
            HStack {
                Text(from).font(.headline).lineLimit(1)
                Spacer(minLength: 12)
                if let place { Text(place).font(.subheadline.monospacedDigit()) }
            }
            .clearOfWindowControls(sizeToFit: true)  // the name moves over; "2 of 3" stays at the edge
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)  // under the timer (PicTimer)
            .background(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Waiting pics and videos, opened back to back (app.js, `openPics`): each
/// counts as opened once shown; tapping goes on to the next, then closes.
/// From a chat, the ones it shows; from the chat list (`waitingIn`), every
/// one waiting in the chat's newest page, oldest first, once the server has
/// said which are still waiting.
struct PicViewer: View {
    @Environment(\.dismiss) private var dismiss
    /// Taken once, when it opens (or once loaded): the chat refreshes as each
    /// is confirmed, and the run mustn't move under it.
    @State private var pics: [PicToOpen]?
    let conversation: Conversation
    /// When it closes: the messages shown (each now opened).
    var done: (Set<Int64>) -> Void = { _ in }
    /// From the list, when nothing turns out to be waiting (opened on another
    /// device meanwhile): the tap opens the chat instead.
    var nothingWaiting: () -> Void = {}
    /// The longest a video can be (the server's): one shows no longer.
    var longest: Double = PicPage.photoSeconds
    @State private var index = 0
    @State private var shown: Set<Int64> = []
    @State private var problem: String?
    /// Each Try again, from the list: asked for again.
    @State private var attempt = 0

    init(pics: [PicToOpen], conversation: Conversation, longest: Int? = nil, done: @escaping (Set<Int64>) -> Void = { _ in }) {
        _pics = State(initialValue: pics)
        self.conversation = conversation
        self.longest = longest.map(Double.init) ?? PicPage.photoSeconds
        self.done = done
    }

    /// From the chat list: the chat's waiting pics, loaded first.
    init(waitingIn conversation: Conversation, longest: Int? = nil, nothingWaiting: @escaping () -> Void = {},
         done: @escaping (Set<Int64>) -> Void = { _ in }) {
        _pics = State(initialValue: nil)
        self.conversation = conversation
        self.longest = longest.map(Double.init) ?? PicPage.photoSeconds
        self.nothingWaiting = nothingWaiting
        self.done = done
    }

    /// The pics waiting in a chat, oldest first, as the server says now
    /// (what was kept may be out of date: one opened on another device).
    static func waiting(in conversation: Conversation) async throws -> [PicToOpen] {
        if conversation.loaded { try await conversation.catchUp() } else { try await conversation.loadNewest() }
        return conversation.bubbles.compactMap(\.opening)
    }

    var body: some View {
        Group {
            if let pics {
                if index < pics.count {
                    let pic = pics[index]
                    PicPage(pic: pic, conversation: conversation, from: sender(pic),
                            place: pics.count > 1 ? "\(index + 1) of \(pics.count)" : nil, longest: longest,
                            onShown: { shown.insert(pic.messageId) }, close: { dismiss() }) {
                        if index + 1 < pics.count { index += 1 } else { dismiss() }
                    }
                    .id(index)  // a fresh page (and its own opening) for each
                }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let problem {
                        VStack(spacing: 12) {
                            Text(problem).foregroundStyle(.white).multilineTextAlignment(.center)
                            HStack(spacing: 12) {
                                Button("Try again") {
                                    self.problem = nil
                                    attempt += 1
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Close") { dismiss() }.buttonStyle(.bordered).tint(.white)
                            }
                        }
                        .padding()
                    } else {
                        Opening { dismiss() }
                    }
                }
                .overlay(alignment: .top) { PicHeader(from: conversation.title, place: nil) }
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }  // nothing's shown yet, so nothing is opened
                .statusBarHidden()
                .task(id: attempt) {
                    do {
                        let waiting = try await Self.waiting(in: conversation)
                        if waiting.isEmpty {  // opened elsewhere meanwhile: the chat, as any other row
                            nothingWaiting()
                            return dismiss()
                        }
                        pics = waiting
                    } catch {
                        Reporter.shared.report(.warn, "opening pics from the list failed", Reporter.fields(error))
                        problem = "Couldn't load this pic. It's still unopened: try again when your connection is better."
                    }
                }
            }
        }
        .onDisappear { done(shown) }
    }

    /// Who sent it: the friend, or in a group, the member (as I call them).
    private func sender(_ pic: PicToOpen) -> String {
        switch pic {
        case .direct: conversation.title
        case .group(let m): conversation.friendsById[m.senderId]?.name ?? m.senderName
        }
    }
}

extension View {
    /// Out from under iPadOS's window controls: the dots at a window's top
    /// leading corner, which an iPhone app run on an iPad has too (App Review
    /// uses iPads sometimes). Toolbars move by themselves; buttons and words
    /// placed there by hand need this. Elsewhere, and before iOS 26, nothing.
    /// `sizeToFit` narrows the view by as much instead of moving all of it.
    @ViewBuilder func clearOfWindowControls(sizeToFit: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            containerCornerOffset(.leading, sizeToFit: sizeToFit)
        } else {
            self
        }
    }
}

extension PicToOpen {
    /// The message it came in.
    var messageId: Int64 {
        switch self {
        case .direct(let m): m.id
        case .group(let m): m.id
        }
    }

    /// How the session's memo knows it (direct and group messages are numbered apart).
    var memoKey: String {
        switch self {
        case .direct(let m): "d\(m.id)"
        case .group(let m): "g\(m.id)"
        }
    }
}
