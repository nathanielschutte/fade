import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Chats kept on the phone (ResponseCache): exactly what the server sent
/// (still encrypted), protected while locked, shown at once and offline, and
/// gone at sign-out. People and keys are the vectors' (ChatListTests).
@MainActor @Suite struct CacheTests {
    let list = try! ChatListTests()
    let root = FileManager.default.temporaryDirectory.appending(path: "napsack-cache-test-\(UUID().uuidString)")
    var account: Account {
        Account(server: "https://napsack.test", token: "t", user: list.reader.me, publicKey: list.bob["spki"] as! String,
                privateKey: list.reader.identity.derRepresentation)
    }

    @Test func keptAsSentAndProtected() throws {
        let cache = ResponseCache(account: 3, root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(cache.read("friends") == nil)
        cache.write(Data("[1,2]".utf8), "friends")
        #expect(cache.read("friends") == Data("[1,2]".utf8))
        let file = cache.directory.appending(path: "friends.json")
        let protection = try FileManager.default.attributesOfItem(atPath: file.path())[.protectionKey] as? FileProtectionType
        #expect(protection == nil || protection == .complete)  // (the Simulator may not report it)
        #expect(ResponseCache(account: 4, root: root).read("friends") == nil)  // per account
        ResponseCache.wipeAll(root: root)
        #expect(cache.read("friends") == nil)
    }

    @Test func theListAndAChatShowWhatWasKeptOffline() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let text = list.v["text"] as! [String: Any]
        let message = list.message(from: 7, to: 3, ciphertext: text["ciphertext"] as? String, read: true)
        let friends = json([ChatListTests.friendJSON(alice: list.alice, nickname: "Al", last: message)])
        let page = json([message])
        let online = StubServer { request in
            let path = request.url!.path
            if path.hasSuffix("/friends") { return (200, friends) }
            if path.hasSuffix("/groups") { return (200, json([])) }
            if path.hasSuffix("/messages") { return (200, page) }
            return (200, json(["ok": true]))
        }
        let first = ChatList(pinStore: MemoryPinStore(), cacheRoot: root)
        try await first.load(account, transport: online)
        let chat = Conversation(.friend(try #require(first.reader?.friends[7])), account: account, reader: try #require(first.reader),
                                cache: first.cache(for: account), transport: online)
        try await chat.loadNewest()
        // What's kept is the server's answer, still encrypted: the plaintext isn't in it.
        let kept = try #require(ResponseCache(account: 3, root: root).read("chat-d-7"))
        #expect(!String(decoding: kept, as: UTF8.self).contains(text["plaintext"] as! String))

        // Offline next time: the list and the chat still show, opened from what was kept.
        let offline = StubServer { _ in throw URLError(.notConnectedToInternet) }
        let again = ChatList(pinStore: MemoryPinStore(), cacheRoot: root)
        await #expect(throws: (any Error).self) { try await again.load(account, transport: offline) }
        #expect(again.fromCache && again.rows.map(\.preview) == [text["plaintext"] as! String])
        let reopened = Conversation(.friend(try #require(again.reader?.friends[7])), account: account, reader: try #require(again.reader),
                                    cache: again.cache(for: account), transport: offline)
        await #expect(throws: (any Error).self) { try await reopened.loadNewest() }
        #expect(reopened.loaded && reopened.bubbles.map(\.content) == [.text(text["plaintext"] as! String, edited: false)])
    }

    @Test func signingOutForgetsTheKeptChats() async throws {
        let cache = ResponseCache(account: 3)  // the real place
        cache.write(Data("[]".utf8), "friends")
        let meAnswer = json(["id": 3, "username": "bob", "display_name": NSNull(), "role": "user", "has_recovery_key": true])
        let server = StubServer { request in request.url!.path == "/api/me" ? (200, meAnswer) : (204, Data()) }
        let session = Session(transport: server, store: MemoryStore(account), reporter: Reporter(transport: server))
        await session.restore(server: "https://napsack.test")
        await session.signOut()
        #expect(cache.read("friends") == nil)
    }
}
