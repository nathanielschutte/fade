import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Reacting and editing against a stand-in server, with the vectors' people
/// (ChatListTests): I'm Bob (3), Alice (7) a friend. What's sent is opened as
/// Alice would, so the sealing is proven, not just the request.
@MainActor @Suite struct ReactionsAndEditsTests {
    let sending = SendingTests()
    var list: ChatListTests { sending.list }
    var alice: Friend { sending.alice }
    var aliceKey: SymmetricKey { try! E2E.pairKey(mine: sending.aliceIdentity, theirs: sending.account.publicKey, myId: 7, theirId: 3) }

    /// My text 100 to Alice, and what the server answers once it's changed.
    nonisolated static func myText(_ sealed: String, reaction: Any = NSNull(), edit: Any = NSNull()) -> [String: Any] {
        ["id": 100, "sender_id": 3, "recipient_id": 7, "kind": "text", "ciphertext": sealed, "format": 2,
         "snap_state": NSNull(), "created_at": Int(Date().timeIntervalSince1970) - 60, "read_at": NSNull(), "client_id": "c",
         "edit_ciphertext": edit, "edit_format": NSNull(), "edited_at": NSNull(),
         "reactions": reaction is NSNull ? [] : [["message_id": 100, "sender_id": 3, "ciphertext": reaction, "format": 2, "created_at": 1]]]
    }

    func myBubble(_ sealed: String) throws -> Bubble {
        sending.reader.bubble(try ChatListTests.decode(DirectMessage.self, Self.myText(sealed)), with: alice)
    }

    @Test func aReactionIsEncryptedAndTheSameAgainTakesItBack() async throws {
        let sealed = try E2E.encryptText2(list.pairKey, "dinner?", replyTo: nil, sender: 3, recipient: 7)
        let server = StubServer { request in
            (200, json(Self.myText(sealed, reaction: body(request)["ciphertext"] ?? NSNull())))
        }
        let chat = sending.chat(.friend(alice), server: server)
        let text = try myBubble(sealed)
        try await chat.react(text, "😂")
        let sent = try #require(await server.requests.last)
        #expect(sent.httpMethod == "PUT" && sent.url!.path == "/api/chats/7/messages/100/reaction")
        let ciphertext = try #require(body(sent)["ciphertext"] as? String)
        #expect(try E2E.decryptReaction(aliceKey, ciphertext, sender: 3, recipient: 7, message: 100) == "😂")
        let reacted = try #require(chat.bubble(100))
        #expect(reacted.reactions == ["😂"] && reacted.myReaction == "😂")

        try await chat.react(reacted, "😂")  // again: taken back, sent as null
        let back = String(decoding: try #require(await server.requests.last?.httpBody), as: UTF8.self)
        #expect(back.contains(#""ciphertext":null"#))
        #expect(chat.bubble(100)?.reactions == [] && chat.bubble(100)?.myReaction == nil)
    }

    @Test func groupReactionsAreTheEmojiItself() async throws {
        let base = json(list.groupMessage(body: "hello all"))
        let server = StubServer { request in
            let emoji = body(request)["emoji"]
            var m = try JSONSerialization.jsonObject(with: base) as! [String: Any]
            m["reactions"] = emoji is String ? [["message_id": 50, "user_id": 3, "emoji": emoji!, "created_at": 1]] : []
            return (200, json(m))
        }
        let chat = sending.chat(.group(try list.group(nil)), server: server)
        let theirs = sending.reader.bubble(try ChatListTests.decode(GroupMessage.self, list.groupMessage(body: "hello all")))
        try await chat.react(theirs, "👍")
        #expect(body(try #require(await server.requests.last))["emoji"] as? String == "👍")
        #expect(chat.bubble(50)?.myReaction == "👍")
        try await chat.react(try #require(chat.bubble(50)), "👍")
        #expect(String(decoding: try #require(await server.requests.last?.httpBody), as: UTF8.self) == #"{"emoji":null}"#)
    }

    @Test func anEditIsSealedForTheFriendAndRetriedAsOne() async throws {
        let sealed = try E2E.encryptText2(list.pairKey, "at 8", replyTo: 40, sender: 3, recipient: 7)
        let tries = Counter()
        let server = StubServer { request in
            if tries.add() == 0 { return (503, json(["error": "busy"])) }
            return (200, json(Self.myText(sealed, edit: body(request)["ciphertext"]!)))
        }
        let chat = sending.chat(.friend(alice), server: server)
        try await chat.edit(try myBubble(sealed), to: "at 8:30")
        let requests = await server.requests
        #expect(requests.count == 2 && requests[0].url!.path == "/api/chats/7/messages/100/edit")
        #expect(Set(requests.map { body($0)["client_id"] as! String }).count == 1)  // a retry, not a second edit
        let edit = try #require(body(requests[1])["ciphertext"] as? String)
        #expect(try E2E.decryptEdit(aliceKey, edit, sender: 3, recipient: 7, message: 100) == "at 8:30")
        #expect(chat.bubble(100)?.content == .text("at 8:30", edited: true) && chat.bubble(100)?.replyTo == 40)
    }

    @Test func aGroupEditIsSealedForTheTextsOwnMembers() async throws {
        let bob = sending.account.publicKey, aliceSpki = list.alice["spki"] as! String
        let carl = E2E.toB64(P256.KeyAgreement.PrivateKey().publicKey.derRepresentation)
        // The text went to Bob and Alice; Carl joined since, and Alice has left.
        let original = try E2E.encryptGroupText("ready at 6", replyTo: nil, groupId: 12, senderId: 3, wrapKeys: [
            3: try E2E.groupWrapKey(mine: sending.reader.identity, theirs: bob, myId: 3, theirId: 3),
            7: try E2E.groupWrapKey(mine: sending.reader.identity, theirs: aliceSpki, myId: 3, theirId: 7)])
        var m = list.groupMessage(format: 3, sender: 3, extra: [
            "client_id": original.clientId, "recipients": [3, 7], "content": E2E.toB64(original.content),
            "key": original.wraps[3]!, "sender_public_key": bob])
        m["created_at"] = Int(Date().timeIntervalSince1970) - 60
        m["group_id"] = 12
        let mine = json(m)
        let server = StubServer { request in
            if request.httpMethod == "GET" {
                return (200, json(["id": 12, "name": "Road trip", "members": [SendingTests.member(3, bob), SendingTests.member(9, carl)]]))
            }
            let b = body(request)
            var edited = try JSONSerialization.jsonObject(with: mine) as! [String: Any]
            edited["edit_content"] = b["content"]!
            edited["edit_client_id"] = b["client_id"]!
            edited["edit_key"] = (b["wraps"] as! [String: Any])["3"]!
            return (200, json(edited))
        }
        var reader = sending.reader
        _ = reader.pins.see(7, aliceSpki)  // pinned while she was in the group
        let chat = sending.chat(.group(try list.group(nil)), reader: reader, server: server)
        let text = reader.bubble(try ChatListTests.decode(GroupMessage.self, m))
        #expect(text.canEdit && text.recipients == [3, 7])
        try await chat.edit(text, to: "ready at 6:30")

        let b = body(try #require(await server.requests.last))
        #expect(b["recipients"] as? [Int64] == [3, 7])  // not Carl: he wasn't there for it
        let opening = E2E.GroupOpening(groupId: 12, senderId: 3, myId: 7, clientId: b["client_id"] as! String, recipients: [3, 7],
                                       wrapKey: try E2E.groupWrapKey(mine: sending.aliceIdentity, theirs: bob, myId: 7, theirId: 3))
        #expect(try E2E.decryptGroupEdit(E2E.fromB64(b["content"] as! String), wrap: (b["wraps"] as! [String: String])["7"]!, message: 50, opening) == "ready at 6:30")
        #expect(chat.bubble(50)?.content == .text("ready at 6:30", edited: true))
    }

    @Test func onlyMyRecentEncryptedTextsCanBeEdited() throws {
        let sealed = try E2E.encryptText2(list.pairKey, "hi", replyTo: nil, sender: 3, recipient: 7)
        #expect(try myBubble(sealed).canEdit)
        var old = Self.myText(sealed)
        old["created_at"] = Int(Date().timeIntervalSince1970) - 16 * 60
        #expect(!sending.reader.bubble(try ChatListTests.decode(DirectMessage.self, old), with: alice).canEdit)  // past 15 minutes
        let theirs = list.message(from: 7, to: 3, ciphertext: (list.v["text"] as! [String: Any])["ciphertext"] as? String)
        #expect(!sending.reader.bubble(try ChatListTests.decode(DirectMessage.self, theirs), with: alice).canEdit)
        var plain = list.groupMessage(body: "old style", sender: 3)
        plain["created_at"] = Int(Date().timeIntervalSince1970)
        #expect(!sending.reader.bubble(try ChatListTests.decode(GroupMessage.self, plain)).canEdit)  // format 0 can't be
    }
}
