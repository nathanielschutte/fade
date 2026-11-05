import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// See who reacted (F21): what the sheet a reaction opens shows, worked out
/// from a message's reactions, and who each person is, against a stand-in
/// server with the vectors' people (ChatListTests): I'm Bob (3), Alice (7) a
/// friend I call "Al", Cal (20) in the group but not a friend.
@MainActor @Suite struct WhoReactedTests {
    let sending = SendingTests()
    var list: ChatListTests { sending.list }

    /// A group's text (50, from Alice) with these reactions.
    func groupText(_ reactions: [(Int64, String)]) -> [String: Any] {
        list.groupMessage(body: "who's driving?", extra: [
            "group_id": 12, "reactions": reactions.map { ["message_id": 50, "user_id": $0.0, "emoji": $0.1, "created_at": 1] }])
    }

    /// The group "Road trip" (12), its one text, and how far each member has read (with their usernames).
    func groupChat(_ reactions: [(Int64, String)]) async throws -> Conversation {
        let text = json([groupText(reactions)])
        let server = StubServer { request in
            switch request.url?.path ?? "" {
            case "/api/groups/12/messages": return (200, text)
            case "/api/groups/12/reads":
                return (200, json([["user_id": 3, "username": "bob", "last_read_id": 50], ["user_id": 7, "username": "alice", "last_read_id": 50],
                                   ["user_id": 20, "username": "cal", "last_read_id": 50]]))
            default: return (404, json(["error": "Not found."]))
            }
        }
        let chat = sending.chat(.group(try list.group(nil)), server: server)
        try await chat.loadNewest()
        await chat.loadGroupReads()
        return chat
    }

    @Test func eachEmojiInTheOrderFirstGivenWithMeFirst() {
        let reactions: [Bubble.Reaction] = [.init(user: 7, emoji: "😂"), .init(user: 9, emoji: "👍🏽"), .init(user: 3, emoji: "😂"),
                                            .init(user: 8, emoji: "😂")]
        let summary = ReactionSummary(reactions, me: 3)
        #expect(summary.entries == [.init(emoji: "😂", people: [3, 7, 8]), .init(emoji: "👍🏽", people: [9])])
        #expect(summary.total == 4)
        // One emoji: who gave it. All: everyone, each with theirs, emoji by emoji.
        #expect(summary.rows("👍🏽") == [.init(user: 9, emoji: "👍🏽")])
        #expect(summary.rows(nil) == [.init(user: 3, emoji: "😂"), .init(user: 7, emoji: "😂"), .init(user: 8, emoji: "😂"),
                                      .init(user: 9, emoji: "👍🏽")])
        // The pills under a message: the same order and counts (nobody's first).
        #expect(ReactionSummary(reactions).entries.map(\.emoji) == ["😂", "👍🏽"])
        #expect(ReactionSummary(reactions).entries[0].people == [7, 3, 8])
        #expect(ReactionSummary([], me: 3).isEmpty && ReactionSummary([], me: 3).total == 0)
    }

    /// The emoji tapped stays shown while anyone has it; once nobody does, All.
    @Test func theEmojiShownBecomesAllOnceNobodyHasIt() {
        let summary = ReactionSummary([.init(user: 7, emoji: "👍")], me: 3)
        #expect(summary.showing("👍") == "👍")
        #expect(summary.showing("❤️") == nil)
        #expect(summary.showing(nil) == nil)
    }

    /// The button under the list: react with the emoji shown, or take mine back (the one shown, or on All).
    @Test func theButtonReactsWithTheEmojiShownOrTakesMineBack() {
        #expect(ReactionSummary.offer(showing: "👍", mine: nil)?.words == "React 👍")
        #expect(ReactionSummary.offer(showing: "👍", mine: "😂")?.words == "React 👍 instead")
        #expect(ReactionSummary.offer(showing: "👍", mine: "👍")?.words == "Take back your 👍")
        #expect(ReactionSummary.offer(showing: nil, mine: "😂").map { [$0.emoji, $0.words] } == ["😂", "Take back your 😂"])
        #expect(ReactionSummary.offer(showing: nil, mine: nil) == nil)  // All, and nothing of mine
    }

    /// Who reacted, named the one way (X47): a friend by what I call them, me as
    /// myself, a group member who isn't a friend by username, and someone not
    /// known here (left the group, nothing of theirs loaded) as nobody to open.
    @Test func whoReactedIsNamedAsEverywhere() async throws {
        let chat = try await groupChat([(20, "😂"), (7, "😂"), (3, "👍")])
        let summary = ReactionSummary(try #require(chat.bubble(50)).reactions, me: 3)
        #expect(summary.entries == [.init(emoji: "😂", people: [20, 7]), .init(emoji: "👍", people: [3])])
        let alice = try #require(chat.person(7))
        #expect(alice.name == "Al" && alice.handle == "@alice" && alice.friend != nil)
        let cal = try #require(chat.person(20))
        #expect(cal.name == "cal" && cal.handle == nil && cal.friend == nil)
        #expect(chat.person(3)?.id == 3 && chat.person(3)?.username == "bob")  // PersonLink shows me as "You"
        #expect(chat.person(99) == nil)

        // A direct chat: the two of us.
        let direct = sending.chat(.friend(sending.alice), server: StubServer { _ in (404, json(["error": "Not found."])) })
        #expect(direct.person(7)?.name == "Al" && direct.person(3)?.username == "bob" && direct.person(20) == nil)
    }

    /// The sheet reads the message from the chat, so a reaction arriving while
    /// it's open shows in it: here Cal's changes, and Alice's goes.
    @Test func aReactionArrivingChangesWhatsShown() async throws {
        let chat = try await groupChat([(20, "😂"), (7, "😂")])
        #expect(ReactionSummary(try #require(chat.bubble(50)).reactions, me: 3).entries == [.init(emoji: "😂", people: [20, 7])])
        chat.arrived(try ChatListTests.decode(GroupMessage.self, groupText([(7, "😂"), (20, "🦊")])))
        let now = ReactionSummary(try #require(chat.bubble(50)).reactions, me: 3)
        #expect(now.entries == [.init(emoji: "😂", people: [7]), .init(emoji: "🦊", people: [20])])
        chat.arrived(try ChatListTests.decode(GroupMessage.self, groupText([(20, "🦊")])))
        let later = ReactionSummary(try #require(chat.bubble(50)).reactions, me: 3)
        #expect(later.showing("😂") == nil && later.rows(nil) == [.init(user: 20, emoji: "🦊")])
    }
}
