import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// An open chat: each message as a bubble, and its history page by page. The
/// people and keys are the vectors' (ChatListTests): I'm Bob (3), Alice (7) a friend.
@MainActor @Suite struct ConversationTests {
    let list = try! ChatListTests()
    var reader: Reader { list.reader }
    var alice: Friend { reader.friends[7]! }

    func bubble(_ m: [String: Any]) throws -> Bubble {
        reader.bubble(try ChatListTests.decode(DirectMessage.self, m), with: alice)
    }

    @Test func textsRepliesAndEdits() throws {
        let text = list.v["text"] as! [String: Any]
        let theirs = try bubble(list.message(from: 7, to: 3, ciphertext: text["ciphertext"] as? String))
        #expect(theirs.content == .text(text["plaintext"] as! String, edited: false) && !theirs.mine && theirs.replyTo == nil)

        let key = try list.pairKey
        let reply = try E2E.encryptText2(key, "yes, 8 works", replyTo: 100, sender: 3, recipient: 7)
        let edit = try E2E.encryptEdit(key, "yes, 8:30 works", sender: 3, recipient: 7, message: 101)
        let mine = try bubble(list.message(from: 3, to: 7, ciphertext: reply, format: 2, edit: edit, id: 101))
        #expect(mine.content == .text("yes, 8:30 works", edited: true) && mine.mine && mine.replyTo == 100)
    }

    @Test func whatCantBeReadSaysWhy() throws {
        let sent = try E2E.encryptText2(list.pairKey, "hi", replyTo: nil, sender: 3, recipient: 7)
        #expect(try bubble(list.message(from: 3, to: 7, ciphertext: sent, format: 11)).content == .unreadable("Update napsack to read this"))
        #expect(try bubble(list.message(from: 7, to: 3, ciphertext: sent, format: 2)).content == .unreadable("This message couldn't be decrypted"))
    }

    @Test func picsInWordsAndReactionsDecrypted() throws {
        #expect(try bubble(list.message(from: 7, to: 3, kind: "snap", format: 2, snap: "pending")).content == .media("New pic"))
        #expect(try bubble(list.message(from: 3, to: 7, kind: "snap", format: 4, snap: "opened")).content == .media("Video opened"))
        // Alice reacted to my message (100): encrypted to me, bound to the message.
        let love = try E2E.encryptReaction(list.pairKey, E2E.reactions[0], sender: 7, recipient: 3, message: 100)
        let elsewhere = try E2E.encryptReaction(list.pairKey, E2E.reactions[1], sender: 7, recipient: 3, message: 99)
        var m = list.message(from: 3, to: 7, kind: "snap", snap: "opened")
        m["reactions"] = [["message_id": 100, "sender_id": 7, "ciphertext": love, "format": 2, "created_at": 1],
                          ["message_id": 100, "sender_id": 7, "ciphertext": elsewhere, "format": 2, "created_at": 2]]
        #expect(try bubble(m).reactions == [E2E.reactions[0]])  // the one moved from another message doesn't open
    }

    @Test func groupMessagesAsBubbles() throws {
        func group(_ m: [String: Any]) throws -> Bubble { reader.bubble(try ChatListTests.decode(GroupMessage.self, m)) }
        let t = list.vg["text"] as! [String: Any]
        let sealed = try group(list.groupMessage(format: 3, sender: list.vg["sender"] as! Int64, extra: [
            "client_id": t["client_id"]!, "recipients": t["recipients"]!, "content": t["content"]!,
            "key": (t["wraps"] as! [String: Any])["3"]!, "sender_public_key": list.alice["spki"]!]))
        #expect(sealed.content == .text(t["text"] as! String, edited: false))
        #expect(sealed.replyTo == t["reply_to"] as? Int64 && sealed.sender == "Al")
        #expect(try group(list.groupMessage(kind: "event", body: #"{"type":"left"}"#)).content == .event("Al left"))
        #expect(try group(list.groupMessage(format: 9)).content == .unreadable("Update napsack to read this"))
        let plain = try group(list.groupMessage(body: "old style", extra: ["reply_to": 40, "reactions": [["message_id": 50, "user_id": 3, "emoji": "👍", "created_at": 1]]]))
        #expect(plain.content == .text("old style", edited: false) && plain.replyTo == 40 && plain.reactions == ["👍"])
    }

    @Test func pagesBackToTheBeginning() async throws {
        // 80 pics (no keys needed): the server answers 50 at a time, oldest first, like the real one.
        let all = (1...80).map { (Int64($0), json(list.message(from: 7, to: 3, kind: "snap", snap: "opened", id: Int64($0)))) }
        let server = StubServer { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if request.url!.path.hasSuffix("/read") { return (200, json(["ok": true])) }
            let limit = Int(items.first { $0.name == "limit" }?.value ?? "") ?? 0
            let before = Int64(items.first { $0.name == "before" }?.value ?? "") ?? Int64.max
            let page = all.filter { $0.0 < before }.suffix(limit).map(\.1)
            return (200, Data("[".utf8) + Data(page.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",").utf8) + Data("]".utf8))
        }
        let account = Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: "", privateKey: reader.identity.derRepresentation)
        let chat = Conversation(.friend(alice), account: account, reader: reader, transport: server)

        try await chat.loadNewest()
        #expect(chat.bubbles.map(\.id) == Array(31...80) && !chat.reachedStart)
        try await chat.loadOlder()
        #expect(chat.bubbles.map(\.id) == Array(1...80) && chat.reachedStart)
        try await chat.loadOlder()  // nothing more to ask for
        await chat.markRead()

        let sent = await server.requests.map { $0.url!.absoluteString }
        #expect(sent == ["https://napsack.test/api/chats/7/messages?limit=50",
                         "https://napsack.test/api/chats/7/messages?limit=50&before=31",
                         "https://napsack.test/api/chats/7/read"])
        #expect(chat.beginning == "This is the beginning of your chat with Al.")
    }
}
