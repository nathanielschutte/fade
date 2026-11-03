import AVKit
import SwiftUI

/// A pic or video sent to you, shown once (app.js, the viewer): full screen,
/// its caption where the sender put it. It counts as opened only once it's
/// been shown; closing it before then leaves it unopened. Nothing is saved:
/// a video plays from a temporary file that's deleted when it closes.
struct PicPage: View {
    let pic: PicToOpen
    let conversation: Conversation
    /// Who sent it, and where it is in the run ("2 of 3"), over the top.
    var from = ""
    var place: String?
    /// It's on screen: from now on it counts as opened.
    var onShown: () -> Void = {}
    /// Closes the viewer while it's still opening (a slow connection): it stays unopened.
    var close: (() -> Void)?
    /// Shown, and tapped past (or a video's end): on to the next, or closed.
    let next: () -> Void
    @State private var opened: OpenedPic?
    @State private var problem: String?
    @State private var player: AVPlayer?
    @State private var shownAt: Date?

    /// Taps this soon after a pic appears don't count: a quick double tap
    /// shouldn't skip past a pic nobody saw (app.js, TAP_GUARD_MS).
    static let tapGuard: TimeInterval = 0.6

    /// The caption where the sender put it on the picture (0 top, 1 bottom).
    @ViewBuilder private func caption(_ opened: OpenedPic) -> some View {
        if !opened.caption.isEmpty {
            GeometryReader { geo in
                Text(opened.caption)
                    .font(.title3).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .frame(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: geo.size.height * CGFloat(opened.y ?? 0.8))
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let opened {
                Group {
                    if let data = opened.image, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .overlay { caption(opened) }  // placed on the picture, as the sender saw it
                    } else if let player {
                        VideoPlayer(player: player).disabled(true)
                            .overlay { caption(opened) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem {
                VStack(spacing: 12) {
                    Text(problem).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Close") { next() }.buttonStyle(.bordered).tint(.white)
                }
                .padding()
            } else {
                Opening(close: close)
            }
        }
        .overlay(alignment: .top) { PicHeader(from: from, place: place) }
        .contentShape(Rectangle())
        .onTapGesture {
            if let shownAt, Date().timeIntervalSince(shownAt) < Self.tapGuard { return }
            if opened != nil || problem != nil { next() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap for the next one, or to close. It can't be opened again.")
        .statusBarHidden()
        .task {
            do {
                let pic = try await conversation.open(pic)
                opened = pic
                shownAt = Date()
                onShown()
                if let url = pic.video {
                    let player = AVPlayer(url: url)
                    self.player = player
                    player.play()
                    // Closes when it ends, as on the web.
                    for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem) {
                        next()
                        break
                    }
                }
            } catch ServerError.refused(_, status: let status) where [404, 410].contains(status) {
                // Opened on another device, or expired, since: on to the next (app.js, `openPic`).
                next()
            } catch {
                Reporter.shared.report(.warn, "opening a pic failed", Reporter.fields(error, ["video": String(pic.isVideo)]))
                problem = error.localizedDescription
            }
        }
        .onDisappear {
            player?.pause()
            if let url = opened?.video { try? FileManager.default.removeItem(at: url) }
            if shownAt != nil { Task { await conversation.confirmOpened(pic) } }
        }
    }
}

/// "Opening…", with Close beneath it: a slow connection mustn't keep you on a
/// black screen (a full-screen cover can't be swiped away).
struct Opening: View {
    let close: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView("Opening…").tint(.white).foregroundStyle(.white)
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
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
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
    @State private var index = 0
    @State private var shown: Set<Int64> = []
    @State private var problem: String?

    init(pics: [PicToOpen], conversation: Conversation, done: @escaping (Set<Int64>) -> Void = { _ in }) {
        _pics = State(initialValue: pics)
        self.conversation = conversation
        self.done = done
    }

    /// From the chat list: the chat's waiting pics, loaded first.
    init(waitingIn conversation: Conversation, nothingWaiting: @escaping () -> Void = {}, done: @escaping (Set<Int64>) -> Void = { _ in }) {
        _pics = State(initialValue: nil)
        self.conversation = conversation
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
                            place: pics.count > 1 ? "\(index + 1) of \(pics.count)" : nil,
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
                            Button("Close") { dismiss() }.buttonStyle(.bordered).tint(.white)
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
                .task {
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

extension PicToOpen {
    /// The message it came in.
    var messageId: Int64 {
        switch self {
        case .direct(let m): m.id
        case .group(let m): m.id
        }
    }
}
