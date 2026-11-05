import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// See who reacted (F21) against a real napsack server (a local one; it makes
/// accounts): in a direct chat, Ana and Ben each react, encrypted, and each
/// side works out who gave what; in a group, Ben sees Cal, who isn't his
/// friend, by username, and a change of hers once he catches up. Runs only
/// with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveWhoReactedTests {
    let live = LiveChatListTests()

    struct Emoji: Encodable { let emoji: String? }

    func lists(_ account: Account) async throws -> ChatList {
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account)
        return list
    }

    func befriend(_ a: Account, _ b: Account) async throws {
        let server = try Server(live.address)
        _ = try await server.send("friends/requests", method: "POST", token: a.token, json: LiveChatListTests.Request(username: b.user.username))
        _ = try await server.send("friends/requests", method: "POST", token: b.token, json: LiveChatListTests.Request(username: a.user.username))
    }

    @Test func whoReactedWithWhatOnBothSides() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben"), cal = try await live.newAccount("cal")
        try await befriend(ana, ben)
        try await befriend(ana, cal)
        let server = try Server(live.address)

        // A direct chat: Ben writes, Ana reacts 👍, Ben ❤️.
        let bens = try await lists(ben)
        let toAna = Conversation(.friend(try #require(bens.reader?.friends[ana.user.id])), account: ben,
                                 reader: try #require(bens.reader), pinBook: bens.pinBook)
        try await toAna.loadNewest()
        await toAna.send("lunch at noon?", replyTo: nil)
        let text = try #require(toAna.bubbles.last)
        let anas = try await lists(ana)
        let fromBen = Conversation(.friend(try #require(anas.reader?.friends[ben.user.id])), account: ana,
                                   reader: try #require(anas.reader), pinBook: anas.pinBook)
        try await fromBen.loadNewest()
        try await fromBen.react(try #require(fromBen.bubble(text.id)), "👍")
        try await toAna.catchUp()
        try await toAna.react(try #require(toAna.bubble(text.id)), "❤️")
        try await fromBen.catchUp()

        let anaSees = ReactionSummary(try #require(fromBen.bubble(text.id)).reactions, me: ana.user.id)
        #expect(anaSees.entries == [.init(emoji: "👍", people: [ana.user.id]), .init(emoji: "❤️", people: [ben.user.id])])
        #expect(fromBen.person(ben.user.id)?.name == ben.user.username && fromBen.person(ben.user.id)?.friend != nil)
        #expect(ReactionSummary.offer(showing: "❤️", mine: fromBen.bubble(text.id)?.myReaction)?.words == "React ❤️ instead")
        // Ben's changes to a 👍: two of them now, Ana first on her side.
        try await toAna.react(try #require(toAna.bubble(text.id)), "👍")
        try await fromBen.catchUp()
        #expect(ReactionSummary(try #require(fromBen.bubble(text.id)).reactions, me: ana.user.id).entries
                == [.init(emoji: "👍", people: [ana.user.id, ben.user.id])])
        #expect(ReactionSummary(try #require(toAna.bubble(text.id)).reactions, me: ben.user.id).entries
                == [.init(emoji: "👍", people: [ben.user.id, ana.user.id])])

        // A group of the three: Ana writes; Cal and Ben react, Ben and Cal aren't friends.
        let created = try Server.decoder.decode(LiveChatListTests.Created.self, from: await server.send(
            "groups", method: "POST", token: ana.token, json: LiveChatListTests.NewGroup(name: "Who reacted", memberIds: [ben.user.id, cal.user.id])))
        let anas2 = try await lists(ana)
        let anaGroup = Conversation(.group(try #require(anas2.groups[created.id])), account: ana, reader: try #require(anas2.reader),
                                    pinBook: anas2.pinBook)
        try await anaGroup.loadNewest()
        await anaGroup.send("who's driving?", replyTo: nil)
        let asked = try #require(anaGroup.bubbles.last)
        _ = try await server.send("groups/\(created.id)/messages/\(asked.id)/reaction", method: "PUT", token: cal.token, json: Emoji(emoji: "😂"))

        let bens2 = try await lists(ben)
        let benGroup = Conversation(.group(try #require(bens2.groups[created.id])), account: ben, reader: try #require(bens2.reader),
                                    pinBook: bens2.pinBook)
        try await benGroup.loadNewest()
        await benGroup.loadGroupReads()
        try await benGroup.react(try #require(benGroup.bubble(asked.id)), "😂")
        let benSees = ReactionSummary(try #require(benGroup.bubble(asked.id)).reactions, me: ben.user.id)
        #expect(benSees.entries == [.init(emoji: "😂", people: [ben.user.id, cal.user.id])])
        let calToBen = try #require(benGroup.person(cal.user.id))
        #expect(calToBen.name == cal.user.username && calToBen.handle == nil && calToBen.friend == nil)
        #expect(benGroup.person(ana.user.id)?.friend != nil)

        // Cal changes hers; Ben catches up.
        _ = try await server.send("groups/\(created.id)/messages/\(asked.id)/reaction", method: "PUT", token: cal.token, json: Emoji(emoji: "🦊"))
        try await benGroup.catchUp()
        #expect(ReactionSummary(try #require(benGroup.bubble(asked.id)).reactions, me: ben.user.id).entries
                == [.init(emoji: "😂", people: [ben.user.id]), .init(emoji: "🦊", people: [cal.user.id])])
    }
}
