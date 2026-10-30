import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Sending texts against a stand-in server, with the vectors' people
/// (ChatListTests): I'm Bob (3), Alice (7) a friend. Each check opens what was
/// sent as Alice would, so the sealing is proven, not just the request.
@MainActor @Suite struct SendingTests {
    let list = try! ChatListTests()
    var reader: Reader { list.reader }
    var alice: Friend { reader.friends[7]! }
    var account: Account {
        Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: list.bob["spki"] as! String,
                privateKey: reader.identity.derRepresentation)
    }
    var aliceIdentity: P256.KeyAgreement.PrivateKey {
        try! P256.KeyAgreement.PrivateKey(derRepresentation: E2E.fromB64(list.alice["pkcs8"] as! String))
    }

    func chat(_ kind: Conversation.Chat, reader: Reader? = nil, server: StubServer) -> Conversation {
        let chat = Conversation(kind, account: account, reader: reader ?? self.reader, transport: server)
        chat.retryDelays = [.zero, .zero]
        return chat
    }

    /// The server's copy of a sent direct text, as it answers.
    nonisolated static func stored(_ request: URLRequest, id: Int64 = 200) -> Data {
        let b = body(request)
        return json(["id": id, "sender_id": 3, "recipient_id": 7, "kind": "text", "ciphertext": b["ciphertext"]!, "format": b["format"]!,
                     "snap_state": NSNull(), "created_at": 1_793_300_000, "read_at": NSNull(), "client_id": b["client_id"]!,
                     "edit_ciphertext": NSNull(), "edit_format": NSNull(), "edited_at": NSNull(), "reactions": []])
    }

    @Test func aTextIsSealedForTheFriendAndJoinsTheChat() async throws {
        let server = StubServer { request in (200, Self.stored(request)) }
        let chat = chat(.friend(alice), server: server)
        await chat.send("dinner at 8?", replyTo: 150)

        let sent = try #require(await server.requests.first)
        #expect(sent.httpMethod == "POST" && sent.url!.path == "/api/chats/7/messages")
        let b = body(sent)
        #expect(b["format"] as? Int == 2)
        // Alice opens it with her side of the pair key.
        let key = try E2E.pairKey(mine: aliceIdentity, theirs: account.publicKey, myId: 7, theirId: 3)
        let opened = try E2E.decryptAnyText(key, b["ciphertext"] as! String, format: 2, sender: 3, recipient: 7)
        #expect(opened.text == "dinner at 8?" && opened.replyTo == 150)
        #expect(chat.outbox.isEmpty)
        #expect(chat.bubbles.map(\.content) == [.text("dinner at 8?", edited: false)] && chat.bubbles[0].mine && chat.bubbles[0].replyTo == 150)
    }

    @Test func aBadConnectionIsTriedAgainWithTheSameMessage() async throws {
        let tries = Counter()
        let server = StubServer { request in
            tries.add() < 2 ? (503, json(["error": "busy"])) : (200, Self.stored(request))
        }
        let chat = chat(.friend(alice), server: server)
        await chat.send("hello?", replyTo: nil)
        let requests = await server.requests
        #expect(requests.count == 3)
        // The same id and bytes every time: the server stores it once.
        #expect(Set(requests.map { body($0)["client_id"] as! String }).count == 1)
        #expect(Set(requests.map { body($0)["ciphertext"] as! String }).count == 1)
        #expect(chat.outbox.isEmpty && chat.bubbles.count == 1)
    }

    @Test func whatCantGoWaitsAsNotSent() async throws {
        let online = Counter()
        let server = StubServer { request in
            if online.value == 0 { throw URLError(.notConnectedToInternet) }
            return (200, Self.stored(request))
        }
        let chat = chat(.friend(alice), server: server)
        await chat.send("you there?", replyTo: nil)
        #expect(chat.outbox.map(\.status) == [.failed("Not sent: no connection.")] && chat.bubbles.isEmpty)
        #expect(await server.requests.count == 3)

        online.add()  // back online: Try again
        await chat.retry(try #require(chat.outbox.first).id)
        #expect(chat.outbox.isEmpty && chat.bubbles.map(\.content) == [.text("you there?", edited: false)])

        // The server's own reason, and Remove gives the text back.
        let refusing = StubServer { _ in (400, json(["error": "That message is too long."])) }
        let other = self.chat(.friend(alice), server: refusing)
        await other.send("words", replyTo: nil)
        #expect(other.outbox.map(\.status) == [.failed("Not sent: That message is too long.")])
        #expect(await refusing.requests.count == 1)  // not the connection: no point trying again
        #expect(other.discard(other.outbox[0].id) == "words" && other.outbox.isEmpty)
    }

    @Test func aChangedKeyOrAClosedAccountSendsNothing() async throws {
        let server = StubServer { request in (200, request.httpMethod == "GET" ? json([]) : Self.stored(request)) }
        var changed = reader
        changed.changed = [7]
        let blocked = chat(.friend(alice), reader: changed, server: server)
        try await blocked.loadNewest()  // (the stand-in answers anything; loading just has to finish)
        #expect(!blocked.canSend)
        await blocked.send("hi", replyTo: nil)
        #expect(blocked.outbox.map(\.status) == [.failed("Not sent: alice's safety code changed. Messages are blocked.")])
        #expect(await server.requests.allSatisfy { $0.httpMethod == "GET" })

        let off = try list.direct(list.message(from: 7, to: 3, read: true), extra: ["deactivated": true])
        #expect(chat(.friend(off), server: server).blockedNote == "This account has been turned off. You can read your chat, but nothing new can be sent.")
        let team = try list.direct(list.message(from: 7, to: 3, read: true), extra: ["system": true])
        #expect(chat(.friend(team), server: server).blockedNote?.hasPrefix("Messages from Team Napsack") == true)
    }

    // ---------- groups ----------

    nonisolated static func member(_ id: Int64, _ key: String) -> [String: Any] {
        ["id": id, "username": id == 3 ? "bob" : "user\(id)", "public_key": key, "role": "member", "joined_at": 0, "added_by": NSNull()]
    }

    /// The server's copy of a sent group text, as Bob receives it (his own wrap).
    nonisolated static func storedGroup(_ request: URLRequest, senderKey: String) -> Data {
        let b = body(request)
        return json(["id": 60, "group_id": 12, "sender_id": 3, "sender_name": "bob", "kind": "text", "body": "", "format": 3,
                     "created_at": 1_793_300_000, "pic_id": NSNull(), "reply_to": NSNull(), "pic": NSNull(), "reactions": [],
                     "client_id": b["client_id"]!, "recipients": b["recipients"]!, "content": b["content"]!,
                     "key": (b["wraps"] as! [String: Any])["3"]!, "sender_public_key": senderKey])
    }

    @Test func aGroupTextIsSealedForEveryMemberAndResealedWhenTheyChange() async throws {
        let bobKey = account.publicKey, aliceKey = list.alice["spki"] as! String
        let carl = E2E.toB64(P256.KeyAgreement.PrivateKey().publicKey.derRepresentation)
        let posts = Counter()
        let server = StubServer { request in
            if request.httpMethod == "GET" {
                // Carl joins after the first seal.
                let members = [Self.member(3, bobKey), Self.member(7, aliceKey)] + (posts.value > 0 ? [Self.member(9, carl)] : [])
                return (200, json(["id": 12, "name": "Road trip", "members": members]))
            }
            if posts.add() == 0 { return (409, json(["error": "The group changed. Try again."])) }
            return (200, Self.storedGroup(request, senderKey: bobKey))
        }
        let chat = chat(.group(try list.group(nil)), server: server)
        await chat.send("who's driving?", replyTo: 50)

        let sends = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(sends.count == 2)
        let first = body(sends[0]), second = body(sends[1])
        #expect(first["recipients"] as? [Int64] == [3, 7] && second["recipients"] as? [Int64] == [3, 7, 9])
        #expect(first["client_id"] as? String != second["client_id"] as? String)  // sealed anew for the new members
        // Alice opens the one that went, with her own wrap.
        let opening = E2E.GroupOpening(groupId: 12, senderId: 3, myId: 7, clientId: second["client_id"] as! String,
                                       recipients: [3, 7, 9], wrapKey: try E2E.groupWrapKey(mine: aliceIdentity, theirs: bobKey, myId: 7, theirId: 3))
        let opened = try E2E.decryptGroupText(E2E.fromB64(second["content"] as! String), wrap: (second["wraps"] as! [String: String])["7"]!, opening)
        #expect(opened.text == "who's driving?" && opened.replyTo == 50)
        #expect(chat.outbox.isEmpty && chat.bubbles.map(\.content) == [.text("who's driving?", edited: false)])
    }

    @Test func aMembersChangedKeyBlocksTheGroup() async throws {
        let bobKey = account.publicKey
        let server = StubServer { _ in
            (200, json(["id": 12, "name": "Road trip", "members": [Self.member(3, bobKey), Self.member(7, E2E.toB64(P256.KeyAgreement.PrivateKey().publicKey.derRepresentation))]]))
        }
        var pinned = reader
        _ = pinned.pins.see(7, list.alice["spki"] as! String)
        let chat = chat(.group(try list.group(nil)), reader: pinned, server: server)
        await chat.send("hi all", replyTo: nil)
        #expect(chat.outbox.map(\.status) == [.failed("Not sent: Al's safety code changed, so napsack won't send to this group. If you're friends, check it in your chat with them.")])
        #expect(await server.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}

/// A count the stand-in server's answers can share.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    /// Adds one; returns the count before.
    @discardableResult func add() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
