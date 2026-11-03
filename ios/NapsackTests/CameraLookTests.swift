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
                let live = try Hosted(CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .pick([], { _, _ in }, done: { _ in })),
                                      size: phone.size, insets: phone.insets)
                try await Task.sleep(for: .milliseconds(500))
                try live.save("camera-live-\(name)")
                live.close()
            }
        }
    }
}
