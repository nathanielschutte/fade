import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// The chat list against a real napsack server (a local one; it makes
/// accounts). Two new accounts become friends; Ana sends Ben a text and a group
/// text, each sealed here in Swift; Ben's list shows both, decrypted. Runs only
/// with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveChatListTests {
    let address = ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] ?? ""
    let invite = ProcessInfo.processInfo.environment["NAPSACK_TEST_INVITE"] ?? "letmein"

    func newAccount(_ name: String) async throws -> Account {
        let session = Session(store: MemoryStore())
        try await session.signUp(server: address, username: "\(name)_\(UUID().uuidString.prefix(6).lowercased())",
                                 password: "correct horse battery", inviteCode: invite)
        return try #require(session.account)
    }

    struct Request: Encodable { let username: String }
    struct Text: Encodable { let ciphertext: String; let format: Int }
    struct NewGroup: Encodable { let name: String; let memberIds: [Int64] }
    struct Created: Decodable { let id: Int64 }
    struct Sealed: Encodable {
        let format: Int
        let content: String
        let clientId: String
        let recipients: [Int64]
        let wraps: [String: String]
    }

    @Test func showsWhatFriendsSentDecrypted() async throws {
        let ana = try await newAccount("ana"), ben = try await newAccount("ben")
        let server = try Server(address)
        // Each asks the other: the second request accepts the first.
        _ = try await server.send("friends/requests", method: "POST", token: ana.token, json: Request(username: ben.user.username))
        _ = try await server.send("friends/requests", method: "POST", token: ben.token, json: Request(username: ana.user.username))

        // A direct text, format 2, sealed here.
        let key = try E2E.pairKey(mine: ana.identity(), theirs: ben.publicKey, myId: ana.user.id, theirId: ben.user.id)
        let text = try E2E.encryptText2(key, "hello from the iPhone 🌿", replyTo: nil, sender: ana.user.id, recipient: ben.user.id)
        _ = try await server.send("chats/\(ben.user.id)/messages", method: "POST", token: ana.token, json: Text(ciphertext: text, format: 2))

        // A group text, format 3: sealed once, its key wrapped for both of them.
        let created = try Server.decoder.decode(Created.self, from: await server.send(
            "groups", method: "POST", token: ana.token, json: NewGroup(name: "Swift and back", memberIds: [ben.user.id])))
        let wrapKeys = [
            ana.user.id: try E2E.groupWrapKey(mine: ana.identity(), theirs: ana.publicKey, myId: ana.user.id, theirId: ana.user.id),
            ben.user.id: try E2E.groupWrapKey(mine: ana.identity(), theirs: ben.publicKey, myId: ana.user.id, theirId: ben.user.id),
        ]
        let sealed = try E2E.encryptGroupText("the group, sealed in Swift", replyTo: nil, groupId: created.id, senderId: ana.user.id, wrapKeys: wrapKeys)
        _ = try await server.send("groups/\(created.id)/messages", method: "POST", token: ana.token, json: Sealed(
            format: 3, content: E2E.toB64(sealed.content), clientId: sealed.clientId, recipients: sealed.recipients,
            wraps: Dictionary(uniqueKeysWithValues: sealed.wraps.map { (String($0.key), $0.value) })))

        // Ben's list: both, opened on his side.
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(ben)
        let direct = try #require(list.rows.first { $0.kind == .friend(ana.user.id) })
        #expect(direct.preview == "hello from the iPhone 🌿")
        #expect(direct.waiting == .text)
        let group = try #require(list.rows.first { $0.kind == .group(created.id) })
        #expect(group.preview == "\(ana.user.username): the group, sealed in Swift")
        #expect(group.waiting == .text)

        // Opening them: the group's history (from its start) and the direct chat, paged.
        let reader = try #require(list.reader)
        let groupChat = Conversation(.group(try #require(list.groups[created.id])), account: ben, reader: reader)
        try await groupChat.loadNewest()
        #expect(groupChat.bubbles.last?.content == .text("the group, sealed in Swift", edited: false))
        #expect(groupChat.reachedStart)
        for n in 1...55 {
            let c = try E2E.encryptText2(key, "number \(n)", replyTo: nil, sender: ana.user.id, recipient: ben.user.id)
            _ = try await server.send("chats/\(ben.user.id)/messages", method: "POST", token: ana.token, json: Text(ciphertext: c, format: 2))
        }
        let chat = Conversation(.friend(try #require(reader.friends[ana.user.id])), account: ben, reader: reader)
        try await chat.loadNewest()
        #expect(chat.bubbles.count == 50 && !chat.reachedStart)
        #expect(chat.bubbles.last?.content == .text("number 55", edited: false))
        try await chat.loadOlder()
        #expect(chat.bubbles.count == 56 && chat.reachedStart)
        #expect(chat.bubbles.first?.content == .text("hello from the iPhone 🌿", edited: false))

        // Read: the list says so.
        await chat.markRead()
        await groupChat.markRead()
        try await list.load(ben)
        #expect(list.rows.allSatisfy { $0.waiting == nil })
    }
}
