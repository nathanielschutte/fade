import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// A chat, as far as handing a picked photo to the camera goes (ChatScreen):
/// the photo picker is a sheet that closes as a photo is chosen, and the
/// camera opens on that photo while it's still closing.
@MainActor @Observable private final class ChatHandOff {
    var picking = false
    var camera: CameraOpening?
}

private struct ChatStandIn: View {
    @Bindable var chat: ChatHandOff

    var body: some View {
        Color.white
            .sheet(isPresented: $chat.picking) { Color.blue }
            .fullScreenCover(item: $chat.camera) { opening in
                CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .chat("Ben") { _ in }, start: opening.start)
            }
    }
}

extension OnScreen {
    /// Handing a photo picked in a chat to the camera.
    @MainActor @Suite struct CameraHandOffTests {
        /// Nate (2026-11-03): a photo picked with a chat's photo button opened the
        /// live camera instead of the photo. The camera went up while the picker
        /// was still closing, and SwiftUI told the camera screen it had
        /// disappeared (and appeared again) as it did; the screen threw its
        /// capture away on disappearing. It has to stay, frozen in place.
        @Test func aPhotoPickedInAChatOpensFrozenInTheCamera() async throws {
            let chat = ChatHandOff()
            let host = try Hosted(ChatStandIn(chat: chat))
            defer { host.close() }

            chat.picking = true
            try await host.until("the picker is up") { host.presented.map { !$0.isBeingPresented } ?? false }
            let picker = try #require(host.presented)
            chat.picking = false  // a photo's chosen: the picker goes...
            // Closing, or (on a slow machine, between two looks) already closed.
            try await host.until("the picker is closing") { picker.isBeingDismissed || host.presented !== picker }
            chat.camera = CameraOpening(start: .photo(TestPicture.plain(.green)))  // ...and the camera opens on it meanwhile
            try await host.until("the camera is up") {
                guard let camera = host.presented, [.fullScreen, .overFullScreen].contains(camera.modalPresentationStyle) else { return false }
                return !camera.isBeingPresented && !camera.isBeingDismissed && camera.transitionCoordinator == nil
            }

            let middle = CGPoint(x: host.window.bounds.midX, y: host.window.bounds.midY)
            let seen = try host.color(at: middle)
            try host.save("hand-off")
            #expect(seen[1] > 200 && seen[0] < 60 && seen[2] < 60, "the picked photo, not the live camera: \(seen)")
        }
    }
}
