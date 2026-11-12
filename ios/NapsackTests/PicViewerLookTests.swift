import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Pictures of the pic viewer at the smallest and largest iPhones, to look at:
/// a pic with its time running down across the top (X58), greying as it ends,
/// opening on a slow connection (how much has come), and one that couldn't
/// open, with Try again (D26). Only with `NAPSACK_SHOTS` set to a folder:
///   TEST_RUNNER_NAPSACK_SHOTS=/tmp/shots ONLY=NapsackTests/OnScreen/PicViewerLookTests bash scripts/test-ios.sh
extension OnScreen {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_SHOTS"] != nil))
    struct PicViewerLookTests {
        let sending = SendingTests()

        @Test func theViewerAtEachSize() async throws {
            for (name, phone) in [("small", Phone.small), ("large", Phone.large)] {
                for (shown, greyed) in [("running", false), ("greying", true)] {
                    let viewer = try Hosted(
                        ZStack {
                            Color.black.ignoresSafeArea()
                            OpenedPhoto(photo: TestPicture.photo(), caption: "Look who's here", y: 0.7, greyed: greyed, tapped: {})
                        }
                        .overlay(alignment: .top) { PicHeader(from: "Ana", place: "1 of 2") }
                        .overlay(alignment: .top) { PicTimer(seconds: 10) },
                        size: phone.size, insets: phone.insets)
                    try await Task.sleep(for: .milliseconds(1500))  // a little of its time gone
                    try viewer.save("viewer-\(shown)-\(name)")
                    viewer.close()
                }
                let opening = try Hosted(ZStack { Color.black.ignoresSafeArea(); Opening(close: {}, part: 0.42) }
                                            .overlay(alignment: .top) { PicHeader(from: "Ana", place: nil) },
                                         size: phone.size, insets: phone.insets)
                try await Task.sleep(for: .milliseconds(500))
                try opening.save("viewer-opening-slowly-\(name)")
                opening.close()

                // The server can't be reached: after its tries, Try again beside Close.
                let server = StubServer { request in
                    request.url!.path.hasSuffix("/messages") ? (200, json([BadConnectionTests.pendingPic()])) : (503, json(["error": "busy"]))
                }
                let chat = sending.chat(.friend(sending.alice), server: server)
                try await chat.loadNewest()
                let pic = try #require(chat.bubbles.first?.opening)
                let failed = try Hosted(PicPage(pic: pic, conversation: chat, from: "Alice", close: {}) {}, size: phone.size, insets: phone.insets)
                try await Task.sleep(for: .milliseconds(1500))
                try failed.save("viewer-couldnt-open-\(name)")
                failed.close()
            }
        }
    }
}
