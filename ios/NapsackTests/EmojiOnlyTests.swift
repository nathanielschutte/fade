import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// A text of one to four emoji is shown large, without a bubble (X53);
/// anything else is an ordinary text.
struct EmojiOnlyTests {
    @Test func oneToFourEmojiAreShownLarge() {
        #expect(BubbleView.emojiOnly("😂") == 1)
        #expect(BubbleView.emojiOnly("❤️") == 1)
        #expect(BubbleView.emojiOnly("👍🏽👍🏽") == 2)
        #expect(BubbleView.emojiOnly("🇳🇿 🏴󠁧󠁢󠁳󠁣󠁴󠁿") == 2)  // flags, spaced
        #expect(BubbleView.emojiOnly("👨‍👩‍👧‍👦1️⃣🦊") == 3)  // a family is one, a keycap is one
        #expect(BubbleView.emojiOnly(" 🎉🎉🎉🎉\n") == 4)
    }

    @Test func anythingElseIsAnOrdinaryText() {
        #expect(BubbleView.emojiOnly("🎉🎉🎉🎉🎉") == nil)  // more than four
        #expect(BubbleView.emojiOnly("ok 👍") == nil)
        #expect(BubbleView.emojiOnly("👍!") == nil)
        #expect(BubbleView.emojiOnly("") == nil)
        #expect(BubbleView.emojiOnly("   ") == nil)
        #expect(BubbleView.emojiOnly("1") == nil)
        #expect(BubbleView.emojiOnly("©") == nil)  // usually a plain symbol
        #expect(BubbleView.emojiOnly("™") == nil)
        #expect(BubbleView.emojiOnly("❤") == nil)  // without its emoji form
    }

    @Test func aPhotoShownWholeFitsTheScreen() {
        let screen = CGSize(width: 390, height: 844)
        let wide = Captured.photo(TestPicture.photo(size: CGSize(width: 1600, height: 900)))
        #expect(CameraScreen.stage(wide, whole: true, screen: screen) == CGSize(width: 390, height: 219))
        let tall = Captured.photo(TestPicture.photo(size: CGSize(width: 900, height: 3000)))
        #expect(CameraScreen.stage(tall, whole: true, screen: screen) == CGSize(width: 253, height: 844))
        // Just taken, it fills the screen, as the camera showed it.
        #expect(CameraScreen.stage(wide, whole: false, screen: screen) == screen)
    }
}

/// Pictures of texts of emoji beside ordinary ones, mine and a friend's, a
/// reply, and with reactions, at the smallest and largest iPhones and the
/// largest text. Only with `NAPSACK_SHOTS` set:
///   TEST_RUNNER_NAPSACK_SHOTS=/tmp/shots ONLY=NapsackTests/OnScreen/EmojiOnlyLookTests bash scripts/test-ios.sh
extension OnScreen {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_SHOTS"] != nil))
    struct EmojiOnlyLookTests {
        static func bubble(_ id: Int64, _ mine: Bool, _ text: String, reactions: [Bubble.Reaction] = []) -> Bubble {
            Bubble(id: id, mine: mine, sender: nil, content: .text(text, edited: false), replyTo: nil, time: .now, reactions: reactions)
        }

        @Test func emojiTexts() async throws {
            let rows: [(Bubble, String?)] = [
                (Self.bubble(1, false, "dinner tonight?"), nil),
                (Self.bubble(2, true, "😋"), nil),
                (Self.bubble(3, false, "🍕🍣🌮", reactions: [.init(user: 3, emoji: "😂")]), nil),
                (Self.bubble(4, true, "🎉🎉🎉🎉"), "🍕🍣🌮"),
                (Self.bubble(5, false, "🎉🎉🎉🎉🎉"), nil),
                (Self.bubble(6, true, "see you at 7 👍"), nil),
            ]
            for (big, text) in [("", DynamicTypeSize.large), ("-big-text", .accessibility3)] {
                for (size, phone) in [("small", Phone.small), ("large", Phone.large)] {
                    let list = ScrollView {
                        VStack(spacing: 8) {
                            ForEach(rows, id: \.0.id) { row in BubbleView(bubble: row.0, quote: row.1) }
                        }
                        .padding(12)
                    }
                    let host = try Hosted(list.environment(\.dynamicTypeSize, text), size: phone.size, insets: phone.insets)
                    try await Task.sleep(for: .milliseconds(300))  // pictures only: let it draw
                    try host.save("emoji-texts\(big)-\(size)")
                    host.close()
                }
            }
        }
    }
}
