import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Sending against a real napsack server (a local one; it makes accounts):
/// Ben sends Ana a text and a group text from the app's own code, edits and
/// reacts to them, and Ana's side opens all of it. Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveSendingTests {
    let live = LiveChatListTests()

    func lists(_ account: Account) async throws -> ChatList {
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account)
        return list
    }

    @Test func sentTextsArriveOpened() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        let server = try Server(live.address)
        _ = try await server.send("friends/requests", method: "POST", token: ana.token, json: LiveChatListTests.Request(username: ben.user.username))
        _ = try await server.send("friends/requests", method: "POST", token: ben.token, json: LiveChatListTests.Request(username: ana.user.username))
        let created = try Server.decoder.decode(LiveChatListTests.Created.self, from: await server.send(
            "groups", method: "POST", token: ana.token, json: LiveChatListTests.NewGroup(name: "Sent from Swift", memberIds: [ben.user.id])))

        // Ben writes to Ana, and to the group, replying to his own text.
        let bens = try await lists(ben)
        let toAna = Conversation(.friend(try #require(bens.reader?.friends[ana.user.id])), account: ben,
                                 reader: try #require(bens.reader), pinBook: bens.pinBook)
        try await toAna.loadNewest()
        await toAna.send("sent from the iPhone ✈️", replyTo: nil)
        #expect(toAna.outbox.isEmpty)
        let first = try #require(toAna.bubbles.last)
        await toAna.send("and a reply", replyTo: first.id)
        #expect(toAna.bubbles.map(\.content) == [.text("sent from the iPhone ✈️", edited: false), .text("and a reply", edited: false)])

        let toGroup = Conversation(.group(try #require(bens.groups[created.id])), account: ben, reader: try #require(bens.reader), pinBook: bens.pinBook)
        try await toGroup.loadNewest()
        await toGroup.send("the group, from the app", replyTo: nil)
        #expect(toGroup.outbox.isEmpty)

        // Ana's side opens both.
        let anas = try await lists(ana)
        #expect(anas.rows.first { $0.kind == .friend(ben.user.id) }?.preview == "and a reply")
        #expect(anas.rows.first { $0.kind == .group(created.id) }?.preview.hasSuffix(": the group, from the app") == true)
        let fromBen = Conversation(.friend(try #require(anas.reader?.friends[ben.user.id])), account: ana, reader: try #require(anas.reader))
        try await fromBen.loadNewest()
        #expect(fromBen.bubbles.last?.replyTo == first.id)
        let group = Conversation(.group(try #require(anas.groups[created.id])), account: ana, reader: try #require(anas.reader), pinBook: anas.pinBook)
        try await group.loadNewest()
        #expect(group.bubbles.last?.content == .text("the group, from the app", edited: false))

        // Ben edits his text and reacts to it; Ana sees both. Then he takes the reaction back.
        let reply = try #require(toAna.bubbles.last)
        try await toAna.edit(reply, to: "and a reply, edited")
        try await toAna.react(try #require(toAna.bubble(reply.id)), "😮")
        try await toGroup.edit(try #require(toGroup.bubbles.last), to: "the group, edited")
        try await toGroup.react(try #require(toGroup.bubbles.last), "👍")
        try await fromBen.catchUp()
        try await group.catchUp()
        #expect(fromBen.bubble(reply.id)?.content == .text("and a reply, edited", edited: true))
        #expect(fromBen.bubble(reply.id)?.reactions == ["😮"])
        #expect(group.bubbles.last?.content == .text("the group, edited", edited: true) && group.bubbles.last?.reactions == ["👍"])
        try await toAna.react(try #require(toAna.bubble(reply.id)), "😮")
        try await fromBen.catchUp()
        #expect(fromBen.bubble(reply.id)?.reactions == [])

        // Sending the same client id again (a dropped answer) returns what's stored, not a copy.
        struct Raw: Decodable { let id: Int64; let clientId: String?; let ciphertext: String? }
        let stored = try Server.decoder.decode([Raw].self, from: await server.send("chats/\(ana.user.id)/messages", token: ben.token))
        let last = try #require(stored.last)
        let again = try await server.sendText(to: ana.user.id, ciphertext: try #require(last.ciphertext), clientId: try #require(last.clientId), token: ben.token)
        #expect(again.id == last.id)
        #expect(try Server.decoder.decode([Raw].self, from: await server.send("chats/\(ana.user.id)/messages", token: ben.token)).count == 2)
    }
}
