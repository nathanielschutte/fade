import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

final class MemoryPinStore: PinStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [Int64: Pins] = [:]

    init(_ pins: Pins? = nil, account: Int64 = 3) { if let pins { kept[account] = pins } }
    func load(account: Int64) -> Pins { lock.withLock { kept[account] ?? Pins() } }
    func save(_ pins: Pins, account: Int64) throws { lock.withLock { kept[account] = pins } }
}

/// Friends' keys as first seen, and what happens when the server hands out a
/// different one: reading stays with the pinned key, the chat says so, and
/// nothing changes until it's accepted. People and keys are the vectors'
/// (ChatListTests): I'm Bob (3), Alice (7) a friend.
@MainActor @Suite struct PinsTests {
    let list = try! ChatListTests()
    /// A key the server could swap in for Alice's.
    let swapped = E2E.toB64(P256.KeyAgreement.PrivateKey().publicKey.derRepresentation)
    var real: String { list.alice["spki"] as! String }

    @Test func firstSightPinsAndAcceptingKeepsTheOldKey() {
        var pins = Pins()
        #expect(pins.readingKeys(7, server: "a") == ["a"])  // nothing pinned yet: the server's
        let first = pins.see(7, "a"), again = pins.see(7, "a"), other = pins.see(7, "b")
        #expect(!first && !again && other)  // pinned on first sight; a different key is a change
        #expect(pins.readingKeys(7, server: "b") == ["a"])  // still read with the pinned one
        pins.accept(7, "b")
        let accepted = pins.see(7, "b")
        #expect(!accepted)
        pins.accept(7, "c")
        #expect(pins.readingKeys(7, server: "z") == ["c", "b", "a"])  // newest first
        pins.accept(7, "c")  // the same key again changes nothing
        #expect(pins.past[7] == ["a", "b"])
    }

    @Test func aBookKeepsWhatItSawAndWhatChanged() throws {
        let store = MemoryPinStore()
        let alice = try list.direct(list.message(from: 7, to: 3, read: true))
        let book = PinBook(account: 3, store: store)
        book.see(friends: [alice])
        #expect(book.changed.isEmpty && store.load(account: 3).current[7] == real)

        let swappedAlice = try list.direct(list.message(from: 7, to: 3, read: true), extra: ["public_key": swapped])
        let later = PinBook(account: 3, store: store)  // the next launch
        later.see(friends: [swappedAlice])
        #expect(later.changed == [7] && later.pins.current[7] == real)
        later.see(senders: [(7, swapped), (9, "member")])  // a group never re-pins a friend; new members are pinned
        #expect(later.pins.current[7] == real && later.pins.current[9] == "member")
        later.accept(swappedAlice)
        #expect(later.changed.isEmpty && store.load(account: 3).current[7] == swapped && store.load(account: 3).past[7] == [real])
    }

    @Test func pinsAreKeptInTheKeychainPerAccount() throws {
        let store = KeychainPinStore(), account = Int64.random(in: 1_000_000...9_999_999)
        defer { try? Keychain.delete(account: "pins:\(account)") }
        #expect(store.load(account: account) == Pins())
        var pins = Pins()
        _ = pins.see(7, real)
        pins.accept(7, swapped)
        try store.save(pins, account: account)
        #expect(store.load(account: account) == pins)
        #expect(store.load(account: account + 1) == Pins())
    }

    /// The whole path: the server swaps Alice's key. Her chat says so, still
    /// opens with the key I pinned, and blocks sending until I accept; once
    /// accepted, her old messages still open (with the key accepted before).
    @Test func aSwappedKeyIsCaughtAndReadingStaysWithThePin() async throws {
        let text = list.v["text"] as! [String: Any]  // sealed with Alice's real key
        let message = list.message(from: 7, to: 3, ciphertext: text["ciphertext"] as? String, read: true)
        let friends = json([ChatListTests.friendJSON(alice: list.alice, nickname: "Al", last: message, extra: ["public_key": swapped])])
        let messages = json([message])
        let server = StubServer { request in
            let path = request.url!.path
            if path.hasSuffix("/friends") { return (200, friends) }
            if path.hasSuffix("/groups") { return (200, json([])) }
            if path.hasSuffix("/messages") { return (200, messages) }
            return (200, json(["ok": true]))
        }
        var pinned = Pins()
        _ = pinned.see(7, real)
        let reader = list.reader
        let account = Account(server: "https://napsack.test", token: "t", user: reader.me, publicKey: list.bob["spki"] as! String,
                              privateKey: reader.identity.derRepresentation)
        let chats = ChatList(pinStore: MemoryPinStore(pinned))
        try await chats.load(account, transport: server)
        #expect(chats.rows.map(\.preview) == ["Safety code changed"])

        let alice = try #require(chats.reader?.friends[7])
        let chat = Conversation(.friend(alice), account: account, reader: try #require(chats.reader), pinBook: chats.pinBook, transport: server)
        try await chat.loadNewest()
        #expect(chat.keyChanged)
        #expect(chat.bubbles.map(\.content) == [.text(text["plaintext"] as! String, edited: false)])
        // The code to compare is for the key the server hands out now.
        #expect(chat.safetyCode == E2E.safetyCode(account.publicKey, swapped))

        try await chat.acceptNewKey()
        #expect(!chat.keyChanged)
        #expect(chat.bubbles.map(\.content) == [.text(text["plaintext"] as! String, edited: false)])
        try await chats.load(account, transport: server)
        #expect(chats.rows.map(\.preview) == [text["plaintext"] as! String])
    }

    @Test func groupMessagesAreReadWithThePinnedSenderKey() throws {
        let t = list.vg["text"] as! [String: Any]
        let sender = list.vg["sender"] as! Int64
        let m = try ChatListTests.decode(GroupMessage.self, list.groupMessage(format: 3, sender: sender, extra: [
            "client_id": t["client_id"]!, "recipients": t["recipients"]!, "content": t["content"]!,
            "key": (t["wraps"] as! [String: Any])["3"]!, "sender_public_key": swapped]))
        var reader = list.reader
        #expect(reader.bubble(m).content == .unreadable(Reader.cantOpen))  // the server's key opens nothing
        _ = reader.pins.see(sender, real)
        #expect(reader.bubble(m).content == .text(t["text"] as! String, edited: false))
    }
}
