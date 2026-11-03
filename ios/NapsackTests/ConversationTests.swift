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

    /// A page already on screen (the kept copy, then the server's answer) is
    /// merged, not replaced: the same messages again change nothing, so a
    /// scroll under way isn't stopped as the chat opens (D17); a new one is added.
    @Test func thePageOnScreenIsMergedNotReplaced() async throws {
        final class Newest: @unchecked Sendable { var id: Int64 = 60 }
        let newest = Newest()
        let all = (1...61).map { String(decoding: json(list.message(from: 7, to: 3, kind: "snap", snap: "opened", id: Int64($0))), as: UTF8.self) }
        let server = StubServer { request in
            if request.url!.path.hasSuffix("/read") { return (200, json(["ok": true])) }
            let page = all[Int(newest.id) - 50..<Int(newest.id)]
            return (200, Data("[\(page.joined(separator: ","))]".utf8))
        }
        let account = Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: "", privateKey: reader.identity.derRepresentation)
        let chat = Conversation(.friend(alice), account: account, reader: reader, transport: server)
        try await chat.loadNewest()
        #expect(chat.bubbles.map(\.id) == Array(11...60))

        let changed = Newest()  // (a box the observation can write to: 0 untouched, 1 changed)
        changed.id = 0
        withObservationTracking { _ = chat.bubbles } onChange: { changed.id = 1 }
        try await chat.loadNewest()
        #expect(changed.id == 0, "the same page again left the list alone")

        newest.id = 61
        try await chat.loadNewest()
        #expect(chat.bubbles.map(\.id) == Array(11...61), "the new one added; what was shown stays")
    }

    /// Each key is an ECDH: a chat works one out per person and key, not one
    /// (or three) per message, and what it opens is the same as before.
    @Test func keysAreWorkedOutOncePerChat() throws {
        let key = try list.pairKey
        let ring = KeyRing()
        var messages: [DirectMessage] = []
        for n in Int64(1)...20 {
            let sealed = try E2E.encryptText2(key, "number \(n)", replyTo: nil, sender: n % 2 == 0 ? 3 : 7, recipient: n % 2 == 0 ? 7 : 3)
            var m = list.message(from: n % 2 == 0 ? 3 : 7, to: n % 2 == 0 ? 7 : 3, ciphertext: sealed, format: 2,
                                 edit: n == 4 ? try E2E.encryptEdit(key, "number 4, edited", sender: 3, recipient: 7, message: 4) : nil, id: n)
            m["reactions"] = [["message_id": n, "sender_id": 7, "format": 2, "created_at": 1,
                               "ciphertext": try E2E.encryptReaction(key, E2E.reactions[0], sender: 7, recipient: 3, message: n)]]
            messages.append(try ChatListTests.decode(DirectMessage.self, m))
        }
        let kept = messages.map { reader.bubble($0, with: alice, ring: ring) }
        #expect(ring.count == 1, "one key for Alice, for every text, edit, and reaction")
        #expect(kept == messages.map { reader.bubble($0, with: alice) }, "the same as with a key worked out each time")
        #expect(kept[3].content == .text("number 4, edited", edited: true) && kept[3].original == "number 4")
        #expect(kept.allSatisfy { $0.reactions == [E2E.reactions[0]] })

        // A group: one wrap key per sender, however many messages.
        let t = list.vg["text"] as! [String: Any]
        let sealed = try ChatListTests.decode(GroupMessage.self, list.groupMessage(format: 3, sender: list.vg["sender"] as! Int64, extra: [
            "client_id": t["client_id"]!, "recipients": t["recipients"]!, "content": t["content"]!,
            "key": (t["wraps"] as! [String: Any])["3"]!, "sender_public_key": list.alice["spki"]!]))
        let groupRing = KeyRing()
        let opened = (0..<5).map { _ in reader.bubble(sealed, ring: groupRing) }
        #expect(groupRing.count == 1 && opened.allSatisfy { $0.content == .text(t["text"] as! String, edited: false) })
    }

    @Test func messagesAreFoundByHalving() {
        func bubbles(_ ids: [Int64]) -> [Bubble] {
            ids.map { Bubble(id: $0, mine: false, sender: nil, content: .text("", edited: false), replyTo: nil, time: .now, reactions: []) }
        }
        #expect([Bubble]().slot(of: 5) == (0, false))
        let some = bubbles([2, 4, 6])
        #expect(some.slot(of: 1) == (0, false) && some.slot(of: 2) == (0, true) && some.slot(of: 5) == (2, false))
        #expect(some.slot(of: 6) == (2, true) && some.slot(of: 7) == (3, false))
    }

    /// A page with messages in between and after what's shown joins in id
    /// order; an older one that changed (a reaction) changes in place.
    @Test func pagesJoinInOrder() async throws {
        let pages = Pages([pics([1, 2, 4, 5]), pics([3, 4, 5, 6]), pics([3, 4, 5, 6])])
        let account = Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: "", privateKey: reader.identity.derRepresentation)
        let chat = Conversation(.friend(alice), account: account, reader: reader, transport: StubServer { _ in (200, pages.next()) })
        try await chat.loadNewest()
        try await chat.catchUp()
        #expect(chat.bubbles.map(\.id) == [1, 2, 3, 4, 5, 6])

        final class Box: @unchecked Sendable { var changed = false }
        let box = Box()
        withObservationTracking { _ = chat.bubbles } onChange: { box.changed = true }
        try await chat.catchUp()  // the same again
        #expect(!box.changed, "nothing changed on screen")

        var opened = list.message(from: 7, to: 3, kind: "snap", snap: "opened", id: 2)
        opened["snap_state"] = "expired"
        chat.arrived(try ChatListTests.decode(DirectMessage.self, opened))
        #expect(chat.bubbles.map(\.id) == [1, 2, 3, 4, 5, 6] && chat.bubble(2)?.content == .media("Pic expired"))
    }

    func pics(_ ids: [Int64]) -> Data {
        json(ids.map { list.message(from: 7, to: 3, kind: "snap", snap: "opened", id: $0) })
    }

    /// A group member seen for the first time is pinned before their messages
    /// are read: one sent with another key (the server's say-so, message by
    /// message) can't be read, the first open and every open after the same.
    @Test func newMembersArePinnedBeforeTheirMessagesAreRead() async throws {
        let first = P256.KeyAgreement.PrivateKey(), second = P256.KeyAgreement.PrivateKey()
        let groupId = list.vg["group_id"] as! Int64
        func sealed(_ id: Int64, by key: P256.KeyAgreement.PrivateKey) throws -> [String: Any] {
            let spki = E2E.toB64(key.publicKey.derRepresentation)
            let wraps: [Int64: SymmetricKey] = [3: try E2E.groupWrapKey(mine: key, theirs: list.bob["spki"] as! String, myId: 9, theirId: 3),
                                                9: try E2E.groupWrapKey(mine: key, theirs: spki, myId: 9, theirId: 9)]
            let m = try E2E.encryptGroupText("number \(id)", replyTo: nil, groupId: groupId, senderId: 9, wrapKeys: wraps)
            var json = list.groupMessage(format: 3, sender: 9, extra: [
                "client_id": m.clientId, "recipients": m.recipients, "content": E2E.toB64(m.content), "key": m.wraps[3]!,
                "sender_public_key": spki])
            json["id"] = id
            return json
        }
        let page = json([try sealed(1, by: first), try sealed(2, by: second)])
        let summary = try ChatListTests.decode(GroupSummary.self, [
            "id": groupId, "name": "Road trip", "role": "member", "member_count": 2, "last_message": NSNull(), "unread": 0,
            "favorite": false, "muted": false, "muted_until": NSNull(), "avatar_id": NSNull(), "encrypted": true])
        let account = Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: "", privateKey: reader.identity.derRepresentation)
        let book = PinBook(account: 3, store: MemoryPinStore())
        for open in ["first", "again"] {
            let chat = Conversation(.group(summary), account: account, reader: reader, pinBook: book,
                                    transport: StubServer { _ in (200, page) })
            try await chat.loadNewest()
            #expect(chat.bubbles.map(\.content) == [.text("number 1", edited: false), .unreadable(Reader.cantOpen)], "\(open)")
        }
    }

    /// The newest page coming back as you sign out (or as the server ends the
    /// session) isn't kept: signing out has wiped the kept chats, and a write
    /// that started before the wipe doesn't put one back. Signed in again, the
    /// chat is kept as before.
    @Test func aPageThatComesBackAfterSigningOutIsntKept() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "napsack-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: "", privateKey: reader.identity.derRepresentation)
        let page = pics([1, 2, 3])
        let gate = Gate(holds: { _ in true }) { _, _ in page }
        let chat = Conversation(.friend(alice), account: account, reader: reader, cache: ResponseCache(account: 3, root: root), transport: gate)
        let loading = Task { try await chat.loadNewest() }
        await gate.someoneWaiting()
        ResponseCache.wipeAll(root: root)  // signed out meanwhile
        await gate.open()
        try await loading.value
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: root.path())) ?? []
        #expect(left.isEmpty, "nothing of the account came back")

        let again = Conversation(.friend(alice), account: account, reader: reader, cache: ResponseCache(account: 3, root: root),
                                 transport: StubServer { _ in (200, page) })
        try await again.loadNewest()
        #expect(ResponseCache(account: 3, root: root).read("chat-d-7") != nil)
    }

    /// A chat kept on the phone long ago opens with that copy, then the
    /// server's newest page is a whole page newer: the chat starts again from
    /// the newest rather than showing the old page above it with everything in
    /// between missing (older pages come from before the oldest shown, so the
    /// gap would never fill), and there's more to load above.
    @Test func aKeptPageFromLongAgoGivesWayToTheNewest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "napsack-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: "", privateKey: reader.identity.derRepresentation)
        for kept in [Array(Int64(1)...50), Array(Int64(1)...30)] {  // a full page kept, and the whole of a short chat
            let cache = ResponseCache(account: 3, root: root)
            cache.write(pics(kept), "chat-d-7")
            let newest = pics(Array(200...249))
            let chat = Conversation(.friend(alice), account: account, reader: reader, cache: cache,
                                    transport: StubServer { _ in (200, newest) })
            try await chat.loadNewest()
            #expect(chat.bubbles.map(\.id) == Array(200...249) && !chat.reachedStart, "kept \(kept.count)")
        }
    }


    /// The page before the oldest comes back after the chat started again from
    /// the newest (catching up after a long time away): it no longer belongs
    /// above what's shown, so it's dropped.
    @Test func anOlderPageThatNoLongerFitsIsDropped() async throws {
        func page(_ ids: ClosedRange<Int64>) -> Data { json(ids.map { list.message(from: 7, to: 3, kind: "snap", snap: "opened", id: $0) }) }
        let older = page(1...50), newest = page(51...100), muchNewer = page(200...249)
        let gate = Gate(holds: Gate.older) { request, call in
            if Gate.older(request) { return older }
            return call == 0 ? newest : muchNewer  // then a whole page newer than what's shown
        }
        let account = Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: "", privateKey: reader.identity.derRepresentation)
        let chat = Conversation(.friend(alice), account: account, reader: reader, transport: gate)
        try await chat.loadNewest()
        let loading = Task { try await chat.loadOlder() }
        await gate.someoneWaiting()
        try await chat.catchUp()  // started again from the newest
        await gate.open()
        try await loading.value
        #expect(chat.bubbles.map(\.id) == Array(200...249) && !chat.reachedStart)
    }
}

/// A server whose answers to some requests wait until the test lets them go,
/// for settling which comes first on purpose.
actor Gate: Transport {
    typealias Answer = @Sendable (URLRequest, _ call: Int) -> Data
    private let holds: @Sendable (URLRequest) -> Bool
    private let answer: Answer
    private var calls = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watching: [CheckedContinuation<Void, Never>] = []

    init(holds: @escaping @Sendable (URLRequest) -> Bool, answer: @escaping Answer) {
        self.holds = holds
        self.answer = answer
    }

    /// A request for a page before some message.
    static let older: @Sendable (URLRequest) -> Bool = { request in
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "before" } == true
    }

    /// Returns once a request is being held.
    func someoneWaiting() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { watching.append($0) }
    }

    /// Lets the held requests go.
    func open() {
        held.forEach { $0.resume() }
        held = []
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = calls
        calls += 1
        if holds(request) {
            await withCheckedContinuation { waiting in
                held.append(waiting)
                watching.forEach { $0.resume() }
                watching = []
            }
        }
        return (answer(request, call), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
