import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// The live connection's events, and what an open chat does with them, with
/// the vectors' people (ChatListTests): I'm Bob (3), Alice (7) a friend.
@MainActor @Suite struct LiveTests {
    let list = try! ChatListTests()
    var reader: Reader { list.reader }
    var alice: Friend { reader.friends[7]! }
    var account: Account {
        Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: list.bob["spki"] as! String,
                privateKey: reader.identity.derRepresentation)
    }

    @Test func eventsAreReadForWhatTheAppUses() throws {
        func event(_ object: [String: Any]) -> LiveEvent { LiveEvent.decode(json(object)) }
        guard case .ready = event(["type": "ready"]), case .authFailed = event(["type": "auth_failed"]),
              case .pong = event(["type": "pong"]) else { Issue.record("plain events"); return }
        guard case .message(let m) = event(["type": "message_updated", "message": list.message(from: 7, to: 3, id: 41)]), m.id == 41
        else { Issue.record("a direct message"); return }
        guard case .groupMessage(let g) = event(["type": "group_message", "group_id": 12, "message": list.groupMessage(body: "hi")]), g.id == 50
        else { Issue.record("a group message"); return }
        for type in ["friends_changed", "groups_changed", "read", "group_read"] {
            guard case .listChanged = event(["type": type]) else { Issue.record("\(type)"); return }
        }
        guard case .other = event(["type": "typing", "from": 7]), case .other = LiveEvent.decode(Data("not json".utf8)),
              case .other = event(["type": "message", "message": ["id": "broken"]]) else { Issue.record("the rest"); return }
    }

    @Test func theSocketIsOnTheServersAddress() {
        #expect(Live.socketURL("https://staging.napsack.io")?.absoluteString == "wss://staging.napsack.io/api/ws")
        #expect(Live.socketURL("http://Nates-Laptop.local:8080")?.absoluteString == "ws://Nates-Laptop.local:8080/api/ws")
    }

    func opened(_ pages: Pages) async throws -> Conversation {
        let server = StubServer { request in
            if request.httpMethod == "POST" { return (200, SendingTests.stored(request, id: 900)) }
            return (200, pages.next())
        }
        let chat = Conversation(.friend(alice), account: account, reader: reader, transport: server)
        chat.retryDelays = [.zero, .zero]
        try await chat.loadNewest()
        return chat
    }

    func pics(_ ids: ClosedRange<Int64>) -> Data {
        json(ids.map { list.message(from: 7, to: 3, kind: "snap", snap: "opened", id: $0) })
    }

    @Test func messagesArriveInTheOpenChat() async throws {
        let chat = try await opened(Pages([pics(1...3)]))
        let text = list.v["text"] as! [String: Any]
        let theirs = try ChatListTests.decode(DirectMessage.self, list.message(from: 7, to: 3, ciphertext: text["ciphertext"] as? String, id: 4))
        #expect(chat.arrived(theirs))  // new, from her: mark it read
        #expect(chat.bubbles.map(\.id) == [1, 2, 3, 4] && chat.bubble(4)?.content == .text(text["plaintext"] as! String, edited: false))
        #expect(!chat.arrived(theirs))  // the same again (updated): not new
        #expect(chat.bubbles.count == 4)
        var elsewhere = list.message(from: 8, to: 3, id: 5)
        elsewhere["recipient_id"] = 3
        #expect(!chat.arrived(try ChatListTests.decode(DirectMessage.self, elsewhere)) && chat.bubbles.count == 4)  // another chat's

        // My own text, back over the socket before the send's answer: it settles the outbox.
        let id = chat.queue("on my way", replyTo: nil)
        var mine = list.message(from: 3, to: 7, ciphertext: try E2E.encryptText2(list.pairKey, "on my way", replyTo: nil, sender: 3, recipient: 7), format: 2, id: 6)
        mine["client_id"] = id
        #expect(!chat.arrived(try ChatListTests.decode(DirectMessage.self, mine)))
        #expect(chat.outbox.isEmpty && chat.bubble(6)?.content == .text("on my way", edited: false))
    }

    @Test func catchingUpMergesOrStartsOverAfterAGap() async throws {
        let chat = try await opened(Pages([pics(1...3), pics(2...4), pics(100...149)]))
        try await chat.catchUp()  // missed one: merged in
        #expect(chat.bubbles.map(\.id) == [1, 2, 3, 4] && chat.reachedStart)
        try await chat.catchUp()  // missed a whole page and more: from the newest again
        #expect(chat.bubbles.map(\.id) == Array(100...149) && !chat.reachedStart)
    }

    @Test func textsThatFailedOfflineGoWhenTheConnectionIsBack() async throws {
        let online = Counter()
        let server = StubServer { request in
            if request.httpMethod == "GET" { return (200, json([])) }
            if online.value == 0 { throw URLError(.networkConnectionLost) }
            return (200, SendingTests.stored(request))
        }
        let chat = Conversation(.friend(alice), account: account, reader: reader, transport: server)
        chat.retryDelays = [.zero, .zero]
        try await chat.loadNewest()
        await chat.send("still there?", replyTo: nil)
        #expect(chat.outbox.map(\.status) == [.failed("Not sent: no connection.")])
        online.add()
        await chat.flush()  // reconnected
        #expect(chat.outbox.isEmpty && chat.bubbles.count == 1)
    }
}

/// Answers in turn; the last one again once they run out.
final class Pages: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Data]
    init(_ answers: [Data]) { self.answers = answers }
    func next() -> Data { lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] } }
}

/// The live connection against a real napsack server (a local one; it makes
/// accounts): Ben's socket signs in, and Ana's text reaches his open chat as
/// it's sent. Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil))
struct LiveSocketTests {
    let live = LiveChatListTests()

    @Test func aTextArrivesLive() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        let server = try Server(live.address)
        _ = try await server.send("friends/requests", method: "POST", token: ana.token, json: LiveChatListTests.Request(username: ben.user.username))
        _ = try await server.send("friends/requests", method: "POST", token: ben.token, json: LiveChatListTests.Request(username: ana.user.username))
        let bens = ChatList(pinStore: MemoryPinStore())
        try await bens.load(ben)
        let chat = Conversation(.friend(try #require(bens.reader?.friends[ana.user.id])), account: ben, reader: try #require(bens.reader))
        try await chat.loadNewest()

        let (events, arriving) = AsyncStream.makeStream(of: LiveEvent.self)
        let socket = Live(account: ben)
        socket.onEvent = { arriving.yield($0) }
        socket.start()
        defer { socket.stop() }
        let giveUp = Task { try? await Task.sleep(for: .seconds(10)); arriving.finish() }  // whichever comes first
        defer { giveUp.cancel() }
        var heard = events.makeAsyncIterator()
        var ready = false
        while !ready, let e = await heard.next() { if case .ready = e { ready = true } }
        try #require(ready)

        // Ana sends; Ben's socket says so, and his open chat shows it opened.
        let key = try E2E.pairKey(mine: ana.identity(), theirs: ben.publicKey, myId: ana.user.id, theirId: ben.user.id)
        let sealed = try E2E.encryptText2(key, "live from the server ⚡️", replyTo: nil, sender: ana.user.id, recipient: ben.user.id)
        _ = try await server.sendText(to: ben.user.id, ciphertext: sealed, clientId: Conversation.newClientId(), token: ana.token)
        var arrived: DirectMessage?
        while arrived == nil, let e = await heard.next() { if case .message(let m) = e { arrived = m } }
        #expect(chat.arrived(try #require(arrived)))
        #expect(chat.bubbles.last?.content == .text("live from the server ⚡️", edited: false))
    }
}
