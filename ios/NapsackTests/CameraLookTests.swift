import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Pictures of the camera screen at the smallest and largest iPhones, to look
/// at (the Simulator has no camera): live, and with a photo to send. Only with
/// `NAPSACK_SHOTS` set to a folder for them:
///   TEST_RUNNER_NAPSACK_SHOTS=/tmp/shots ONLY=NapsackTests/OnScreen/CameraLookTests bash scripts/test-ios.sh
extension OnScreen {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_SHOTS"] != nil))
    struct CameraLookTests {
        @Test func theCameraAtEachSize() async throws {
            for (name, phone) in [("small", Phone.small), ("large", Phone.large)] {
                let review = try Hosted(CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .chat("Ben") { _ in }, start: .photo(TestPicture.photo())),
                                        size: phone.size, insets: phone.insets)
                try await Task.sleep(for: .milliseconds(500))  // pictures only: let it draw
                try review.save("camera-review-\(name)")
                review.close()
                // A wide photo from the library: whole, then zoomed in, each with a
                // long caption; and what each sends, as the friend sees it (X52, X54).
                let photo = TestPicture.photo(size: CGSize(width: 1600, height: 900))
                let words = "The sun came out just as we got to the top, and the whole valley lit up green. Worth every step of that climb!"
                var zoomed = Framing(whole: true)
                zoomed.zoom = 2.4
                zoomed.offset = CGSize(width: -60, height: 0)
                for (shown, framing) in [("wide", Framing(whole: true)), ("zoomed", zoomed)] {
                    let review = try Hosted(CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .chat("Ben") { _ in }, start: .photo(photo),
                                                         caption: (words, 0.7), framing: framing.kept(image: photo.size, screen: phone.size)),
                                            size: phone.size, insets: phone.insets)
                    try await Task.sleep(for: .milliseconds(500))
                    try review.save("camera-review-\(shown)-\(name)")
                    review.close()
                    let crop = framing.kept(image: photo.size, screen: phone.size).crop(image: photo.size, screen: phone.size)
                    let sent = Framing.cropped(photo, to: crop)
                    let opened = try Hosted(ZStack { Color.black.ignoresSafeArea(); OpenedPhoto(photo: sent, caption: words, y: 0.7, tapped: {}) },
                                            size: phone.size, insets: phone.insets)
                    try await Task.sleep(for: .milliseconds(500))
                    try opened.save("camera-review-\(shown)-\(name)-as-opened")
                    opened.close()
                }
                let live = try Hosted(CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .pick([], { _, _ in }, done: { _ in })),
                                      size: phone.size, insets: phone.insets)
                try await Task.sleep(for: .milliseconds(500))
                try live.save("camera-live-\(name)")
                live.close()
                // In the Camera tab, the tab bar stays: the shutter and flip sit above it.
                for (shown, start) in [("live", nil), ("review", Captured.photo(TestPicture.photo()))] {
                    let tab = try Hosted(CameraTabStandIn(start: start), size: phone.size, insets: phone.insets)
                    try await Task.sleep(for: .milliseconds(500))
                    try tab.save("camera-tab-\(shown)-\(name)")
                    tab.close()
                }
            }
        }
    }
}

/// The Camera tab as ChatListScreen shows it: the camera, with the tab bar under it.
private struct CameraTabStandIn: View {
    let start: Captured?
    @State private var tab = ChatListScreen.HomeTab.camera

    var body: some View {
        TabView(selection: $tab) {
            Color.white.tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }.tag(ChatListScreen.HomeTab.chats)
            CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .pick([], { _, _ in }, done: { _ in }), start: start, close: {})
                .tabItem { Label("Camera", systemImage: "camera") }.tag(ChatListScreen.HomeTab.camera)
            Color.white.tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(ChatListScreen.HomeTab.profile)
        }
    }
}
