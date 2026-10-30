import Foundation

/// Friends' and group members' public keys as this phone first saw them
/// (the web app's pins, app.js). If the server later hands out a different key
/// for someone, the app reads with the pinned one and won't send to the new
/// one until you accept it: keys only change when an admin resets an account,
/// and a key the server swapped in would let it read the chat.
struct Pins: Codable, Equatable, Sendable {
    /// The key to trust for each person.
    var current: [Int64: String] = [:]
    /// Keys accepted before the current one, oldest first: they still open the
    /// messages they protected. Only ever from my own pins, never from the
    /// server (a server-supplied "old key" could forge old messages).
    var past: [Int64: [String]] = [:]

    /// The first time someone's key is seen it's pinned. Returns whether the
    /// server's key now differs from the pinned one.
    mutating func see(_ id: Int64, _ key: String) -> Bool {
        guard let pinned = current[id] else {
            current[id] = key
            return false
        }
        return pinned != key
    }

    /// The new key becomes the pinned one; the old one moves to the past keys.
    mutating func accept(_ id: Int64, _ key: String) {
        if let old = current[id], old != key { past[id, default: []].append(old) }
        current[id] = key
    }

    /// Keys that could have sealed someone's messages: the pinned one, then
    /// the past ones, newest first. The server's only when nothing's pinned.
    func readingKeys(_ id: Int64, server: String?) -> [String] {
        if let pinned = current[id] { return [pinned] + (past[id] ?? []).reversed() }
        return server.map { [$0] } ?? []
    }
}

/// Where each account's pins are kept between launches. They stay when you
/// sign out (as the web app's do): public keys, which open nothing, kept so a
/// key swapped while you were away is still caught.
protocol PinStore: Sendable {
    func load(account: Int64) -> Pins
    func save(_ pins: Pins, account: Int64) throws
}

struct KeychainPinStore: PinStore {
    /// Pins are a server's account's: the same id on another server (staging
    /// and production, say) is someone else, whose keys mustn't be mixed in.
    /// (A browser keeps each site's apart by itself.)
    let server: String

    init(server: String) {
        self.server = server
    }

    /// `pins:<host>[:port]:<account>`.
    func key(_ account: Int64) -> String {
        let url = URL(string: server)
        let host = (url?.host() ?? server).lowercased() + (url?.port.map { ":\($0)" } ?? "")
        return "pins:\(host):\(account)"
    }

    func load(account: Int64) -> Pins {
        (try? Keychain.read(account: key(account))).flatMap { try? JSONDecoder().decode(Pins.self, from: $0) } ?? Pins()
    }

    func save(_ pins: Pins, account: Int64) throws {
        try Keychain.save(JSONEncoder().encode(pins), account: key(account))
    }
}

/// The signed-in person's pins, shared by the chat list and open chats.
@MainActor @Observable final class PinBook {
    private(set) var pins: Pins
    /// Friends whose key changed and hasn't been accepted: their chats are blocked for sending.
    private(set) var changed: Set<Int64> = []
    private let account: Int64
    private let store: any PinStore

    init(account: Int64, store: any PinStore) {
        self.account = account
        self.store = store
        pins = store.load(account: account)
    }

    /// Friends from the chat list: pinned on first sight, and noted if their key changed.
    func see(friends: [Friend]) {
        var pins = self.pins
        changed = Set(friends.filter { pins.see($0.id, $0.publicKey) }.map(\.id))
        keep(pins)
    }

    /// Group members, from their messages' sender keys: pinned on first sight.
    func see(senders: [(Int64, String)]) {
        var pins = self.pins
        for (id, key) in senders { _ = pins.see(id, key) }
        keep(pins)
    }

    func accept(_ friend: Friend) {
        var pins = self.pins
        pins.accept(friend.id, friend.publicKey)
        changed.remove(friend.id)
        keep(pins)
    }

    private func keep(_ pins: Pins) {
        guard pins != self.pins else { return }
        self.pins = pins
        try? store.save(pins, account: account)
    }
}
