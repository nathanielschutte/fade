import CryptoKit
import Foundation
import NapsackCrypto

/// One message as a chat shows it, opened.
struct Bubble: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case text(String, edited: Bool)
        /// A pic or video, in words ("New pic", "Video opened"); opening them comes with the camera (plan-ios.md).
        case media(String)
        /// Something that happened in a group ("Ana added you").
        case event(String)
        /// Couldn't be opened: why, in words.
        case unreadable(String)
    }

    let id: Int64
    let mine: Bool
    /// Groups: who sent it (others only).
    let sender: String?
    let content: Content
    let replyTo: Int64?
    let time: Date
    let reactions: [String]

    /// A line about it, for a reply's quote.
    var gist: String {
        switch content {
        case .text(let text, _): text
        case .media(let words), .event(let words), .unreadable(let words): words
        }
    }
}

extension Reader {
    static let tooNew = "Update napsack to read this"
    static let cantOpen = "This message couldn't be decrypted"

    func bubble(_ m: DirectMessage, with friend: Friend) -> Bubble {
        let mine = m.senderId == me.id
        let content: Bubble.Content
        var replyTo: Int64?
        if m.kind == "snap" {
            let word = m.format == E2E.videoFormat ? "video" : "pic", Word = word.capitalized
            let words = mine
                ? ["pending": "Sent a \(word)", "opened": "\(Word) opened", "expired": "\(Word) expired unopened"]
                : ["pending": "New \(word)", "opened": "\(Word) viewed", "expired": "\(Word) expired"]
            content = .media(words[m.snapState ?? ""] ?? Word)
        } else if ![1, 2].contains(m.format) {
            content = .unreadable(Self.tooNew)
        } else if let opened = body(m, with: friend) {
            content = .text(opened.text.text, edited: opened.edited)
            replyTo = opened.text.replyTo
        } else {
            content = .unreadable(Self.cantOpen)
        }
        let keys = readingKeys(friend)
        let reactions = (m.reactions ?? []).compactMap { r -> String? in
            let to = r.senderId == me.id ? friend.id : me.id
            return keys.lazy.compactMap { try? E2E.decryptReaction($0, r.ciphertext, sender: r.senderId, recipient: to, message: m.id) }.first
        }
        return Bubble(id: m.id, mine: mine, sender: nil, content: content, replyTo: replyTo,
                      time: Date(timeIntervalSince1970: TimeInterval(m.createdAt)), reactions: reactions)
    }

    func bubble(_ m: GroupMessage) -> Bubble {
        let mine = m.senderId == me.id
        let content: Bubble.Content
        var replyTo: Int64?
        if m.kind == "event" {
            content = .event(eventText(m))
        } else if let pic = m.pic {
            let word = m.format == E2E.groupVideoFormat ? "video" : "pic", Word = word.capitalized
            content = .media(
                pic.discardReason == "expired" ? "\(Word) expired"
                : mine ? "Sent a \(word)"
                : pic.viewers.contains(me.id) ? "\(Word) viewed" : "New \(word)")
        } else if ![0, E2E.groupFormat].contains(m.format) {
            content = .unreadable(Self.tooNew)
        } else if let opened = groupBody(m) {
            content = .text(opened.text.text, edited: opened.edited)
            replyTo = opened.text.replyTo
        } else {
            content = .unreadable(Self.cantOpen)
        }
        return Bubble(id: m.id, mine: mine, sender: mine || m.kind == "event" ? nil : name(m.senderId, m.senderName),
                      content: content, replyTo: replyTo, time: Date(timeIntervalSince1970: TimeInterval(m.createdAt)),
                      reactions: (m.reactions ?? []).map(\.emoji))
    }
}

/// An open chat: its history, newest page first, older pages as you scroll
/// back (plan F3: 50 at a time), each message opened on arrival.
@MainActor @Observable final class Conversation {
    enum Chat: Sendable {
        case friend(Friend)
        case group(GroupSummary)
    }

    static let page = 50

    let chat: Chat
    private let account: Account
    private var reader: Reader
    private let transport: any Transport
    /// Whose keys to trust; group senders seen here for the first time are pinned.
    private let pinBook: PinBook?

    /// Oldest first.
    private(set) var bubbles: [Bubble] = []
    private(set) var loaded = false
    /// Nothing older to load: the chat's beginning (or, in a group, when you joined).
    private(set) var reachedStart = false
    private(set) var loadingOlder = false
    private(set) var problem: String?

    init(_ chat: Chat, account: Account, reader: Reader, pinBook: PinBook? = nil, transport: any Transport = NetworkTransport()) {
        self.chat = chat
        self.account = account
        self.reader = reader
        self.pinBook = pinBook
        self.transport = transport
    }

    var title: String {
        switch chat {
        case .friend(let friend): friend.name
        case .group(let group): group.name
        }
    }

    /// Where the history stops, in the web app's words.
    var beginning: String {
        switch chat {
        case .friend(let friend): "This is the beginning of your chat with \(friend.name)."
        case .group(let group): "This is the beginning of \(group.name), from when you joined."
        }
    }

    func bubble(_ id: Int64) -> Bubble? { bubbles.first { $0.id == id } }

    /// The friend in a direct chat.
    var friend: Friend? {
        if case .friend(let friend) = chat { return friend }
        return nil
    }

    /// The server now hands out a different key for this friend than the one
    /// pinned: sending is blocked until it's accepted.
    var keyChanged: Bool {
        guard let friend else { return false }
        return pinBook?.changed.contains(friend.id) ?? reader.changed.contains(friend.id)
    }

    /// The code to compare with the friend, for the key the server hands out now.
    var safetyCode: String? {
        guard let friend else { return nil }
        return E2E.safetyCode(account.publicKey, friend.publicKey)
    }

    /// Trusts the friend's new key (compared or not), then reopens the chat with it.
    func acceptNewKey() async throws {
        guard let friend, let pinBook else { return }
        pinBook.accept(friend)
        reader.pins = pinBook.pins
        reader.changed = pinBook.changed
        try await loadNewest()
    }

    /// The newest page, replacing what's shown.
    func loadNewest() async throws {
        let page = try await fetch(before: nil)
        bubbles = page
        reachedStart = page.count < Self.page
        loaded = true
        problem = nil
    }

    /// The page before the oldest shown.
    func loadOlder() async throws {
        guard loaded, !reachedStart, !loadingOlder, let oldest = bubbles.first?.id else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let page = try await fetch(before: oldest)
        let shown = Set(bubbles.map(\.id))
        bubbles = page.filter { !shown.contains($0.id) } + bubbles
        reachedStart = page.count < Self.page
    }

    /// Tells the server (and the sender) this chat has been read.
    func markRead() async {
        let server = try? Server(account.server, transport: transport)
        switch chat {
        case .friend(let friend): try? await server?.markRead(path: "chats/\(friend.id)/read", token: account.token)
        case .group(let group): try? await server?.markRead(path: "groups/\(group.id)/read", token: account.token)
        }
    }

    func noted(_ error: any Error) {
        problem = error.localizedDescription
    }

    private func fetch(before: Int64?) async throws -> [Bubble] {
        let server = try Server(account.server, transport: transport)
        let reader = self.reader
        switch chat {
        case .friend(let friend):
            let messages = try await server.directMessages(friend: friend.id, before: before, limit: Self.page, token: account.token)
            return await Task.detached(priority: .userInitiated) { messages.map { reader.bubble($0, with: friend) } }.value
        case .group(let group):
            let messages = try await server.groupMessages(group: group.id, before: before, limit: Self.page, token: account.token)
            if let pinBook {
                pinBook.see(senders: messages.compactMap { m in m.senderPublicKey.map { (m.senderId, $0) } })
                self.reader.pins = pinBook.pins
            }
            let reader = self.reader
            return await Task.detached(priority: .userInitiated) { messages.map(reader.bubble) }.value
        }
    }
}
