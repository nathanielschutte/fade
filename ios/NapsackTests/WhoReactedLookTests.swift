import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Pictures of who reacted (F21): a group's message with four emoji and
/// five people (friends with pictures, a long name, someone who isn't a
/// friend, me), on one emoji and on All, from the narrowest iPhone to the
/// largest, and with the largest text. Only with `NAPSACK_SHOTS` set:
///   TEST_RUNNER_NAPSACK_SHOTS=/tmp/shots ONLY=NapsackTests/OnScreen/WhoReactedLookTests bash scripts/test-ios.sh
extension OnScreen {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_SHOTS"] != nil))
    struct WhoReactedLookTests {
        let sending = SendingTests()  // I'm Bob (3)

        /// Road trip (12): Alice's text, reacted to by everyone.
        func chat() async throws -> Conversation {
            let reactions: [(Int64, String)] = [(7, "😂"), (8, "😂"), (20, "🦊"), (3, "😂"), (9, "👍🏽"), (21, "🇳🇿")]
            let text = json([sending.list.groupMessage(body: "who's driving?", extra: [
                "group_id": 12, "reactions": reactions.map { ["message_id": 50, "user_id": $0.0, "emoji": $0.1, "created_at": 1] }])])
            let server = StubServer { request in
                switch request.url?.path ?? "" {
                case "/api/groups/12/messages": return (200, text)
                case "/api/groups/12/reads":
                    return (200, json([3, 7, 8, 9].map { ["user_id": $0, "username": "u\($0)", "last_read_id": 50] }
                                      + [["user_id": 20, "username": "cal_who_isnt_your_friend_yet", "last_read_id": 50]]))
                default: return (404, json(["error": "Not found."]))
                }
            }
            var reader = sending.reader
            reader.friends = try PeopleLookTests().friends()
            let chat = Conversation(.group(try sending.list.group(nil)), account: sending.account, reader: reader, transport: server)
            try await chat.loadNewest()
            await chat.loadGroupReads()
            return chat
        }

        @Test func theSheet() async throws {
            let chat = try await chat()
            let pictures = Pictures(account: sending.account, transport: PeopleLookTests().server)
            for (showing, name) in [("😂", "one"), (nil, "all")] as [(String?, String)] {
                for (big, text) in [("", DynamicTypeSize.large), ("-big-text", .accessibility3)] {
                    for (size, phone) in [("narrow", ModerationLookTests.narrow), ("small", Phone.small), ("large", Phone.large)] {
                        let sheet = WhoReactedSheet(conversation: chat, message: 50, account: sending.account, showing: showing, react: { _, _ in })
                        let host = try Hosted(sheet.environment(Session(store: MemoryStore())).environment(pictures).environment(\.dynamicTypeSize, text),
                                              size: phone.size, insets: phone.insets)
                        try await Task.sleep(for: .milliseconds(800))  // pictures only: let them load and draw
                        try host.save("who-reacted-\(name)\(big)-\(size)")
                        host.close()
                    }
                }
            }
        }
    }
}
