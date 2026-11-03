import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// How the chat list keeps current without reloading itself (ChatList.heard):
/// a message changes its own row, reads change nothing in the list, and what
/// only the server knows reloads just the list it's in, once for a burst. An
/// answer asked for before a live message never undoes it. The people are the
/// vectors' (ChatListTests): I'm Bob (3), Alice (7) a friend, Road trip (12) a group.
@MainActor @Suite struct ListUpdatesTests {
    let t = try! ChatListTests()
    var account: Account {
        Account(server: "https://napsack.test", token: "t", user: t.reader.me, publicKey: t.bob["spki"] as! String,
                privateKey: t.reader.identity.derRepresentation)
    }

    /// A server with Alice (her newest message `last`) and the group, answering everything a list asks.
    func server(last: [String: Any], group: [String: Any]? = nil) -> StubServer {
        let friends = json([ChatListTests.friendJSON(alice: t.alice, nickname: "Al", last: last)])
        let groups = json([["id": 12, "name": "Road trip", "role": "member", "member_count": 4, "last_message": group.map { $0 as Any } ?? NSNull(),
                            "unread": 0, "favorite": false, "muted": false, "muted_until": NSNull(), "avatar_id": NSNull(), "encrypted": false]])
        return StubServer { request in
            switch request.url!.path {
            case "/api/friends": return (200, friends)
            case "/api/groups": return (200, groups)
            case "/api/friends/requests": return (200, json(["incoming": [["id": 9, "username": "zed", "created_at": 1]], "outgoing": []]))
            case "/api/announcement": return (200, json(["announcement": NSNull()]))
            default: return (200, json(["ok": true]))
            }
        }
    }

    func text(_ words: String, id: Int64, from: Int64 = 7) throws -> DirectMessage {
        let (sender, recipient): (Int64, Int64) = from == 7 ? (7, 3) : (3, 7)
        let sealed = try E2E.encryptText2(t.pairKey, words, replyTo: nil, sender: sender, recipient: recipient)
        return try ChatListTests.decode(DirectMessage.self, t.message(from: sender, to: recipient, ciphertext: sealed, format: 2, id: id))
    }

    /// The paths asked for since `from`.
    func asked(_ server: StubServer, since from: Int) async -> [String] {
        Array(await server.requests.dropFirst(from).map { "\($0.httpMethod ?? "") \($0.url!.path)" })
    }

    @Test func aMessageChangesItsOwnRowWithoutAReload() async throws {
        let server = server(last: t.message(from: 7, to: 3, read: true, id: 100))
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account, transport: server)
        let before = await server.requests.count
        #expect(list.incoming == 1)

        // Alice sends a text: her row shows it, unread, at the top; nothing is asked for.
        list.heard(.message(try text("are you there?", id: 101)), account: account, transport: server)
        await list.quiet()
        let row = try #require(list.rows.first)
        #expect(row.kind == .friend(7) && row.preview == "are you there?" && row.waiting == .text)
        #expect(list.waitingCount == 1)
        // My answer from another device: "You: ...", nothing waiting.
        list.heard(.message(try text("yes", id: 102, from: 3)), account: account, transport: server)
        await list.quiet()
        #expect(list.rows.first?.preview == "You: yes" && list.rows.first?.waiting == nil && list.waitingCount == 0)
        // An older message changing (a reaction) leaves the row as it is.
        list.heard(.message(try text("are you there?", id: 101)), account: account, transport: server)
        await list.quiet()
        #expect(list.rows.first?.preview == "You: yes")
        #expect(await asked(server, since: before).isEmpty)

        // A pic from her: it waits, and a tap shows it from the list.
        let pic = try ChatListTests.decode(DirectMessage.self, t.message(from: 7, to: 3, kind: "snap", format: 6, snap: "pending", id: 103))
        list.heard(.message(pic), account: account, transport: server)
        await list.quiet()
        #expect(list.rows.first?.waiting == .snap && list.rows.first?.opensPics == true)

        // Someone the list doesn't have yet (a friendship just made): the friends list reloads, and only it.
        var stranger = t.message(from: 8, to: 3, id: 104)
        stranger["recipient_id"] = 3
        list.heard(.message(try ChatListTests.decode(DirectMessage.self, stranger)), account: account, transport: server)
        await list.quiet()
        #expect(await asked(server, since: before) == ["GET /api/friends"])
    }

    @Test func readsDontReloadTheListAndChangesReloadOnlyTheirOwn() async throws {
        let server = server(last: t.message(from: 7, to: 3, read: true, id: 100))
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account, transport: server)
        var before = await server.requests.count

        // Alice read my texts; everyone in a big group read a message: the list doesn't show either.
        list.heard(.read(by: 7, at: 1_793_300_500), account: account, transport: server)
        for member in 1...31 { list.heard(.groupRead(group: 12, user: Int64(100 + member), last: 60), account: account, transport: server) }
        list.heard(.typing(from: 7, group: nil), account: account, transport: server)
        await list.quiet()
        #expect(await asked(server, since: before).isEmpty)

        // I read a chat on another device (the event doesn't say which): the friends list, only.
        list.heard(.read(by: 3, at: 1_793_300_500), account: account, transport: server)
        await list.quiet()
        #expect(await asked(server, since: before) == ["GET /api/friends"])
        before = await server.requests.count

        // A burst of friend changes: one reload of friends and requests.
        for _ in 1...5 { list.heard(.friendsChanged, account: account, transport: server) }
        await list.quiet()
        #expect(Set(await asked(server, since: before)) == ["GET /api/friends", "GET /api/friends/requests"])
        #expect(await asked(server, since: before).count == 2)
        before = await server.requests.count

        list.heard(.groupsChanged(12), account: account, transport: server)
        await list.quiet()
        #expect(await asked(server, since: before) == ["GET /api/groups"])
        before = await server.requests.count

        // Back from a dropped connection: everything.
        list.heard(.ready, account: account, transport: server)
        await list.quiet()
        #expect(Set(await asked(server, since: before)) == ["GET /api/friends", "GET /api/groups", "GET /api/friends/requests", "GET /api/announcement"])
    }

    @Test func aGroupMessageChangesItsRowAndCountsAsUnread() async throws {
        let server = server(last: t.message(from: 7, to: 3, read: true, id: 100), group: t.groupMessage(body: "first", sender: 3))
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account, transport: server)
        let before = await server.requests.count
        var m = t.groupMessage(body: "who's driving?")
        m["id"] = 51
        m["group_id"] = 12
        m["created_at"] = 1_793_400_000
        list.heard(.groupMessage(try ChatListTests.decode(GroupMessage.self, m)), account: account, transport: server)
        await list.quiet()
        let row = try #require(list.rows.first)
        #expect(row.kind == .group(12) && row.preview == "Al: who's driving?" && row.waiting == .text && list.groups[12]?.unread == 1)
        // Someone else seeing it (the same message again, changed): no more unread than before.
        list.heard(.groupMessage(try ChatListTests.decode(GroupMessage.self, m)), account: account, transport: server)
        await list.quiet()
        #expect(list.groups[12]?.unread == 1)
        // A group not in the list yet: the groups list reloads, and only it.
        var elsewhere = m
        elsewhere["group_id"] = 13
        list.heard(.groupMessage(try ChatListTests.decode(GroupMessage.self, elsewhere)), account: account, transport: server)
        await list.quiet()
        #expect(await asked(server, since: before) == ["GET /api/groups"])
    }

    /// An answer the server gave before a live message reached the phone mustn't undo it.
    @Test func anAnswerOlderThanALiveMessageDoesntUndoIt() async throws {
        /// What the server answers for friends (changed as the test goes).
        final class Answer: @unchecked Sendable { var friends = Data() }
        let answer = Answer()
        func newest(_ m: [String: Any]) { answer.friends = json([ChatListTests.friendJSON(alice: t.alice, nickname: "Al", last: m)]) }
        newest(t.message(from: 7, to: 3, ciphertext: try E2E.encryptText2(t.pairKey, "old news", replyTo: nil, sender: 7, recipient: 3),
                         format: 2, read: true, id: 100))
        let stub = StubServer { request in
            switch request.url!.path {
            case "/api/friends": return (200, answer.friends)
            case "/api/groups": return (200, json([]))
            default: return (200, json(["incoming": [], "outgoing": []]))
            }
        }
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account, transport: stub)
        let gate = Gate()
        let slow = Held(gate: gate, inner: stub) { $0.url!.path == "/api/friends" }

        // Asked, not yet answered, when the message comes: the answer (without it) doesn't take the row back.
        let reloading = Task { try await list.load(account, .friends, transport: slow) }
        await gate.someoneWaiting()
        list.heard(.message(try text("this is newer", id: 101)), account: account, transport: stub)
        await list.settled()
        #expect(list.rows.first?.preview == "this is newer")
        await gate.open()
        try await reloading.value
        await list.settled()
        #expect(list.rows.first?.preview == "this is newer")

        // Asked after it: the server's word is taken as it is (here, one newer still).
        newest(t.message(from: 3, to: 7, ciphertext: try E2E.encryptText2(t.pairKey, "newest of all", replyTo: nil, sender: 3, recipient: 7),
                         format: 2, id: 102))
        try await list.load(account, .friends, transport: stub)
        #expect(list.rows.first?.preview == "You: newest of all")
    }

    @Test func rowActionsShowAtOnceWithoutAReload() async throws {
        let server = server(last: t.message(from: 7, to: 3, read: true, id: 100))
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account, transport: server)
        let before = await server.requests.count
        let alice = try #require(list.rows.first { $0.kind == .friend(7) })
        try await list.setFavorite(alice, true, account: account, transport: server)
        #expect(list.favorites.map(\.kind) == [.friend(7)])
        try await list.setMuted(alice, true, hours: 8, account: account, transport: server)
        #expect(list.rows.first { $0.kind == .friend(7) }?.muted == true)
        try await list.setHidden(alice, true, account: account, transport: server)
        #expect(list.hiddenRows.map(\.kind) == [.friend(7)])
        let group = try #require(list.rows.first { $0.kind == .group(12) })
        try await list.leave(group, account: account, transport: server)
        #expect(!list.rows.contains { $0.kind == .group(12) } && list.groups[12] == nil)
        // Only the actions themselves went (the server's own event then reloads the list).
        #expect(await asked(server, since: before) == ["PUT /api/chats/7/favorite", "PUT /api/chats/7/mute", "PUT /api/chats/7/hidden",
                                                        "DELETE /api/groups/12/members/3"])
    }

    @Test func searchFindsNamesUsernamesAndNewestMessagesAtOnce() async throws {
        let sealed = try E2E.encryptText2(t.pairKey, "pizza tonight?", replyTo: nil, sender: 7, recipient: 3)
        let server = server(last: t.message(from: 7, to: 3, ciphertext: sealed, format: 2, read: true, id: 100))
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account, transport: server)
        #expect(list.search("al").map(\.kind) == [.friend(7)])  // her nickname
        #expect(list.search("ALICE").map(\.kind) == [.friend(7)])  // her username
        #expect(list.search("pizza").map(\.kind) == [.friend(7)])  // her newest message
        #expect(list.search("road").map(\.kind) == [.group(12)])
        #expect(list.search("   ").isEmpty && list.search("nothing like it").isEmpty)
    }
}

/// Holds requests until let through: a slow server, on purpose.
actor Gate {
    private var opened = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watching: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        if opened { return }
        await withCheckedContinuation { c in
            held.append(c)
            watching.forEach { $0.resume() }
            watching = []
        }
    }

    /// Returns once a request is being held.
    func someoneWaiting() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { watching.append($0) }
    }

    func open() {
        opened = true
        held.forEach { $0.resume() }
        held = []
    }
}

/// A stand-in server whose answers to some requests wait at a gate.
struct Held: Transport {
    let gate: Gate
    let inner: StubServer
    let holds: @Sendable (URLRequest) -> Bool

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if holds(request) { await gate.pass() }
        return try await inner.send(request)
    }
}
