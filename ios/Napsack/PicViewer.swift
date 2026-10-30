import AVKit
import SwiftUI

/// A pic or video sent to you, shown once (app.js, the viewer): full screen,
/// its caption where the sender put it. It counts as opened only once it's
/// been shown; closing it before then leaves it unopened. Nothing is saved:
/// a video plays from a temporary file that's deleted when it closes.
struct PicViewer: View {
    @Environment(\.dismiss) private var dismiss
    let pic: PicToOpen
    let conversation: Conversation
    @State private var opened: OpenedPic?
    @State private var problem: String?
    @State private var player: AVPlayer?
    @State private var shown = false

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
                    Button("Close") { dismiss() }.buttonStyle(.bordered).tint(.white)
                }
                .padding()
            } else {
                ProgressView("Opening…").tint(.white).foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if opened != nil || problem != nil { dismiss() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap to close. It can't be opened again.")
        .statusBarHidden()
        .task {
            do {
                let pic = try await conversation.open(pic)
                opened = pic
                shown = true
                if let url = pic.video {
                    let player = AVPlayer(url: url)
                    self.player = player
                    player.play()
                    // Closes when it ends, as on the web.
                    for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem) {
                        dismiss()
                        break
                    }
                }
            } catch {
                Reporter.shared.report(.warn, "opening a pic failed", Reporter.fields(error, ["video": String(pic.isVideo)]))
                problem = error.localizedDescription
            }
        }
        .onDisappear {
            player?.pause()
            if let url = opened?.video { try? FileManager.default.removeItem(at: url) }
            if shown { Task { await conversation.confirmOpened(pic) } }
        }
    }
}
