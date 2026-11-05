import CryptoKit
import Foundation
import Synchronization
import UIKit
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
    /// The one I gave, if any (the same again takes it back).
    var myReaction: String? = nil
    /// One of my texts that can be edited (format 3 in a group), within the window.
    var editable = false
    /// A group text's member list: an edit is sealed for exactly these.
    var recipients: [Int64]? = nil
    /// One of my direct texts the friend has read.
    var seen = false
    /// A pic or video waiting for me to open it (once).
    var opening: PicToOpen? = nil
    /// Who sent it (for "Seen by", and for opening its edits).
    var senderId: Int64 = 0
    /// An edited text's words as first sent.
    var original: String? = nil

    /// Your own texts can be edited for 15 minutes after sending (app.js, `canEdit`).
    static let editWindow: TimeInterval = 15 * 60
    var canEdit: Bool { editable && Date().timeIntervalSince(time) < Self.editWindow }

    /// Texts and pics can be replied to; group events can't, nor what couldn't be opened.
    var repliable: Bool {
        switch content {
        case .text, .media: true
        case .event, .unreadable: false
        }
    }

    /// A line about it, for a reply's quote.
    var gist: String {
        switch content {
        case .text(let text, _): text
        case .media(let words), .event(let words), .unreadable(let words): words
        }
    }
}

/// The keys a chat has worked out, kept while it's open: every message,
/// reaction, and edit needs one, and each is an ECDH and an HKDF. A key is
/// kept under the public key it came from, so a newly pinned or accepted key
/// is a new entry, never a stale one. Shared with the work done off the main
/// thread (opening a page), so it's locked.
final class KeyRing: Sendable {
    private let kept = Mutex<[String: SymmetricKey]>([:])

    /// A direct chat's key with someone (E2E.pairKey).
    func pair(mine: P256.KeyAgreement.PrivateKey, theirs: String, myId: Int64, theirId: Int64) throws -> SymmetricKey {
        try key("pair:\(myId):\(theirId):\(theirs)") { try E2E.pairKey(mine: mine, theirs: theirs, myId: myId, theirId: theirId) }
    }

    /// The key that wraps a group message's key between two people (E2E.groupWrapKey).
    func groupWrap(mine: P256.KeyAgreement.PrivateKey, theirs: String, myId: Int64, theirId: Int64) throws -> SymmetricKey {
        try key("wrap:\(myId):\(theirId):\(theirs)") { try E2E.groupWrapKey(mine: mine, theirs: theirs, myId: myId, theirId: theirId) }
    }

    /// How many it holds (ConversationTests checks each is worked out once).
    var count: Int { kept.withLock { $0.count } }

    private func key(_ name: String, _ make: () throws -> SymmetricKey) throws -> SymmetricKey {
        if let known = kept.withLock({ $0[name] }) { return known }
        let made = try make()
        kept.withLock { $0[name] = made }
        return made
    }
}

extension Reader {
    static let tooNew = "Update napsack to read this"
    static let cantOpen = "This message couldn't be decrypted"

    /// The chat keys that can read a friend's messages (as `readingKeys`), each worked out once per chat.
    func readingKeys(_ friend: Friend, ring: KeyRing) -> [SymmetricKey] {
        pins.readingKeys(friend.id, server: friend.publicKey).compactMap {
            try? ring.pair(mine: identity, theirs: $0, myId: me.id, theirId: friend.id)
        }
    }

    /// The wrap keys that can open someone's group message (from `senderKeys`), each worked out once per chat.
    func wrapKeys(from sender: Int64, server: String?, ring: KeyRing) -> [SymmetricKey] {
        senderKeys(sender, server: server).compactMap {
            try? ring.groupWrap(mine: identity, theirs: $0, myId: me.id, theirId: sender)
        }
    }

    func bubble(_ m: DirectMessage, with friend: Friend, ring: KeyRing = KeyRing()) -> Bubble {
        let mine = m.senderId == me.id
        let keys = readingKeys(friend, ring: ring)
        let content: Bubble.Content
        var replyTo: Int64?
        var opening: PicToOpen?
        var original: String?
        if m.kind == "snap" {
            let word = m.format == E2E.videoFormat ? "video" : "pic", Word = word.capitalized
            let words = mine
                ? ["pending": "Sent a \(word)", "opened": "\(Word) opened", "expired": "\(Word) expired unopened"]
                : ["pending": "New \(word)", "opened": "\(Word) viewed", "expired": "\(Word) expired"]
            content = .media(words[m.snapState ?? ""] ?? Word)
            if !mine && m.snapState == "pending" { opening = .direct(m) }
        } else if ![1, 2].contains(m.format) {
            content = .unreadable(Self.tooNew)
        } else if let opened = Self.open(m, keys: keys) {
            content = .text(opened.text.text, edited: opened.original != nil)
            replyTo = opened.text.replyTo
            original = opened.original
        } else {
            content = .unreadable(Self.cantOpen)
        }
        // Any one emoji (X49), held to the server's rule for groups' (E2E.isReaction):
        // the server can't see these, so anything else a client sealed is dropped here.
        let reactions = (m.reactions ?? []).compactMap { r -> (Int64, String)? in
            let to = r.senderId == me.id ? friend.id : me.id
            return keys.lazy.compactMap { try? E2E.decryptReaction($0, r.ciphertext, sender: r.senderId, recipient: to, message: m.id) }.first
                .flatMap { E2E.isReaction($0) ? (r.senderId, $0) : nil }
        }
        var bubble = Bubble(id: m.id, mine: mine, sender: nil, content: content, replyTo: replyTo,
                            time: Date(timeIntervalSince1970: TimeInterval(m.createdAt)), reactions: reactions.map(\.1))
        bubble.myReaction = reactions.first { $0.0 == me.id }?.1
        if case .text = content { bubble.editable = mine }
        bubble.seen = mine && m.kind == "text" && m.readAt != nil
        bubble.opening = opening
        bubble.senderId = m.senderId
        bubble.original = original
        return bubble
    }

    /// A direct text opened with the first key that can (as `body`, Chats.swift): what it
    /// says now (its newest edit), and its words as first sent if it was edited.
    static func open(_ m: DirectMessage, keys: [SymmetricKey]) -> (text: E2E.Text, original: String?)? {
        guard let ciphertext = m.ciphertext else { return nil }
        for key in keys {
            guard let body = try? E2E.decryptAnyText(key, ciphertext, format: m.format, sender: m.senderId, recipient: m.recipientId)
            else { continue }
            if let edit = m.editCiphertext,
               let edited = try? E2E.decryptEdit(key, edit, sender: m.senderId, recipient: m.recipientId, message: m.id) {
                return (E2E.Text(text: edited, replyTo: body.replyTo), body.text)
            }
            return (body, nil)
        }
        return nil
    }

    func bubble(_ m: GroupMessage, ring: KeyRing = KeyRing()) -> Bubble {
        let mine = m.senderId == me.id
        let content: Bubble.Content
        var replyTo: Int64?
        var opening: PicToOpen?
        var original: String?
        if m.kind == "event" {
            content = .event(eventText(m))
        } else if let pic = m.pic {
            let word = m.format == E2E.groupVideoFormat ? "video" : "pic", Word = word.capitalized
            content = .media(
                pic.discardReason == "expired" ? "\(Word) expired"
                : mine ? "Sent a \(word)"
                : pic.viewers.contains(me.id) ? "\(Word) viewed" : "New \(word)")
            if !mine && pic.discardReason == nil && !pic.viewers.contains(me.id) { opening = .group(m) }
        } else if m.format == 0 {
            content = .text(m.body, edited: false)
            replyTo = m.replyTo
        } else if m.format != E2E.groupFormat {
            content = .unreadable(Self.tooNew)
        } else if let opened = open(m, wrapKeys: wrapKeys(from: m.senderId, server: m.senderPublicKey, ring: ring)) {
            content = .text(opened.text.text, edited: opened.original != nil)
            replyTo = opened.text.replyTo
            original = opened.original
        } else {
            content = .unreadable(Self.cantOpen)
        }
        var bubble = Bubble(id: m.id, mine: mine, sender: mine || m.kind == "event" ? nil : name(m.senderId, m.senderName),
                            content: content, replyTo: replyTo, time: Date(timeIntervalSince1970: TimeInterval(m.createdAt)),
                            reactions: (m.reactions ?? []).map(\.emoji).filter(E2E.isReaction))  // the server checks these too
        bubble.myReaction = m.reactions?.first { $0.userId == me.id }?.emoji
        if case .text = content { bubble.editable = mine && m.format == E2E.groupFormat }
        bubble.recipients = m.recipients
        bubble.opening = opening
        bubble.senderId = m.senderId
        bubble.original = original
        return bubble
    }

    /// A format 3 group text opened with the first wrap key that can (as `groupBody`, Chats.swift):
    /// what it says now (its newest edit), and its words as first sent if it was edited.
    func open(_ m: GroupMessage, wrapKeys: [SymmetricKey]) -> (text: E2E.Text, original: String?)? {
        guard let content = m.content, let wrap = m.key, let bytes = try? E2E.fromB64(content) else { return nil }
        for wrapKey in wrapKeys {
            let opening = E2E.GroupOpening(groupId: m.groupId, senderId: m.senderId, myId: me.id,
                                           clientId: m.clientId ?? "", recipients: m.recipients ?? [], wrapKey: wrapKey)
            guard let body = try? E2E.decryptGroupText(bytes, wrap: wrap, opening) else { continue }
            if let editContent = m.editContent, let editKey = m.editKey, let editBytes = try? E2E.fromB64(editContent) {
                var edit = opening
                edit.clientId = m.editClientId ?? ""
                if let edited = try? E2E.decryptGroupEdit(editBytes, wrap: editKey, message: m.id, edit) {
                    return (E2E.Text(text: edited, replyTo: body.replyTo), body.text)
                }
            }
            return (body, nil)
        }
        return nil
    }
}

extension [Bubble] {
    /// Where the message with this id is, or would go: a chat's bubbles are in id order.
    func slot(of id: Int64) -> (index: Int, found: Bool) {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle].id < id { low = middle + 1 } else { high = middle }
        }
        return (low, low < count && self[low].id == id)
    }
}

/// A text on its way: shown at once, below the chat, until the server has it.
struct Outgoing: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case sending
        /// Why, in words ("Not sent: no connection.").
        case failed(String)
        /// Behind one that wasn't sent: it goes once that one is sent or removed,
        /// so the chat keeps the order they were written in.
        case held
    }

    /// The message's `client_id`: the same on every try, so the server never stores it twice.
    let id: String
    let text: String
    let replyTo: Int64?
    var status: Status = .sending
}

/// Why napsack won't send.
enum SendError: LocalizedError, Equatable {
    case keyChanged(String)
    case memberKeyChanged(String)
    case cantEdit
    case cantOpen
    case tooLarge
    case notAReaction

    var errorDescription: String? {
        switch self {
        case .keyChanged(let username): "\(username)'s safety code changed. Messages are blocked."
        case .cantEdit: "This text can't be edited: napsack doesn't have the key of everyone it went to."
        case .cantOpen: "This pic couldn't be shown. It's still unopened."
        case .tooLarge: "That's too large to send."
        case .notAReaction: "A reaction is one emoji. Pick another."
        case .memberKeyChanged(let name):
            "\(name)'s safety code changed, so napsack won't send to this group. If you're friends, check it in your chat with them."
        }
    }
}

/// A pic or video someone sent me that I haven't opened: what's needed to fetch and open it.
enum PicToOpen: Equatable, Sendable {
    case direct(DirectMessage)
    case group(GroupMessage)

    var isVideo: Bool {
        switch self {
        case .direct(let m): m.format == E2E.videoFormat
        case .group(let m): m.format == E2E.groupVideoFormat
        }
    }
}

/// A pic or video, opened: shown once, never saved (a video is a temporary file, deleted after).
struct OpenedPic: Sendable {
    let image: Data?
    let video: URL?
    let caption: String
    /// Where the caption sits, 0 (top) to 1 (bottom); nil for the usual place.
    let y: Double?
}

/// An open chat: its history, newest page first, older pages as you scroll
/// back (plan F3: 50 at a time), each message opened on arrival. Texts you
/// send wait in an outbox until the server has them (app.js, the outbox),
/// going one at a time in the order written: a bad connection is tried
/// again, and a text that still can't go waits as "Not sent" with Try again,
/// holding the ones after it. Unsent texts are only in memory, never kept.
/// (Pics and videos go on their own, each as soon as it's ready.)
@MainActor @Observable final class Conversation {
    enum Chat: Sendable {
        case friend(Friend)
        case group(GroupSummary)
    }

    static let page = 50

    private(set) var chat: Chat
    private let account: Account
    private var reader: Reader
    private let transport: any Transport
    /// Whose keys to trust; group senders seen here for the first time are pinned.
    private let pinBook: PinBook?
    /// The newest page, kept on the phone (still encrypted).
    private let cache: ResponseCache?
    /// The keys this chat has worked out (KeyRing).
    @ObservationIgnored private let ring = KeyRing()
    /// The last write of the kept page, so writes land in order (off the main thread).
    @ObservationIgnored private var keeping: Task<Void, Never>?

    /// Oldest first (in id order, which `slot(of:)` relies on).
    private(set) var bubbles: [Bubble] = []
    private(set) var loaded = false
    /// Nothing older to load: the chat's beginning (or, in a group, when you joined).
    private(set) var reachedStart = false
    private(set) var loadingOlder = false
    private(set) var problem: String?
    /// Texts on their way, oldest first.
    private(set) var outbox: [Outgoing] = []
    /// Sealed once per text, so every try sends the same bytes.
    private var sealedTexts: [String: String] = [:]
    private var sealedGroupTexts: [String: E2E.GroupMessage] = [:]
    /// Who's typing here, until when (app.js, TYPING_MS: 4 seconds after the last word).
    private(set) var typingUntil: [Int64: Date] = [:]
    /// The friend on screen now, or when they last were (only if you both share it).
    private(set) var activeNow = false
    private(set) var lastSeenAt: Int64?
    @ObservationIgnored private var lastTypingSent = Date.distantPast
    static let typingFor: TimeInterval = 4

    /// Texts that failed for the connection's sake: they go again on reconnect.
    private var offline: Set<String> = []
    /// Waits between tries while the connection is the problem.
    var retryDelays: [Duration] = [.seconds(1), .seconds(3)]

    init(_ chat: Chat, account: Account, reader: Reader, pinBook: PinBook? = nil, cache: ResponseCache? = nil,
         transport: any Transport = NetworkTransport()) {
        self.chat = chat
        self.account = account
        self.reader = Self.current(reader, pinBook)
        self.pinBook = pinBook
        self.cache = cache
        self.transport = transport
        if case .friend(let friend) = chat {
            activeNow = friend.activeNow == true
            lastSeenAt = friend.lastSeenAt
        }
    }

    // ---------- typing, active now, seen ----------

    /// "Ana is typing…", "Ana and Ben are typing…", "3 people are typing…" (the web app's words).
    var typingLine: String? {
        let now = Date()
        let names = typingUntil.filter { $0.value > now }.keys.sorted().map { id in
            reader.friends[id]?.name ?? (friend?.id == id ? friend?.name : nil) ?? "Someone"
        }
        switch names.count {
        case 0: return nil
        case 1: return "\(names[0]) is typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "\(names.count) people are typing…"
        }
    }

    /// Someone's typing: shown for 4 seconds after the last word. Returns whether it's this chat.
    @discardableResult func typing(from user: Int64, group: Int64?) -> Bool {
        switch chat {
        case .friend(let friend) where group == nil && user == friend.id: break
        case .group(let g) where group == g.id: break
        default: return false
        }
        let until = Date().addingTimeInterval(Self.typingFor)
        typingUntil[user] = until
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.typingFor + 0.05))
            if let self, self.typingUntil[user] == until { self.typingUntil[user] = nil }
        }
        return true
    }

    /// The friend came on screen or left.
    func presence(user: Int64, active: Bool, lastSeenAt: Int64?) {
        guard friend?.id == user else { return }
        activeNow = active
        if let lastSeenAt { self.lastSeenAt = lastSeenAt }
    }

    /// "Active now", "Active 5m ago", or nothing past a day (app.js, `activeText`).
    func activeText(now: Date = .now) -> String? {
        if activeNow { return "Active now" }
        guard let lastSeenAt else { return nil }
        let ago = now.timeIntervalSince1970 - TimeInterval(lastSeenAt)
        if ago > 86_400 { return nil }
        if ago < 60 { return "Active just now" }
        if ago < 3600 { return "Active \(Int(ago / 60))m ago" }
        return "Active \(Int(ago / 3600))h ago"
    }

    /// The friend read my texts up to `at`: they're seen.
    func read(by user: Int64, at: Int64) {
        guard let friend, friend.id == user else { return }
        typingUntil[user] = nil  // they've read it; whatever they were typing will come as a message
        let upTo = Date(timeIntervalSince1970: TimeInterval(at))
        var marked = bubbles, changed = false
        for i in marked.indices where marked[i].mine && !marked[i].seen && marked[i].time <= upTo {
            if case .text = marked[i].content { marked[i].seen = true; changed = true }
        }
        if changed { bubbles = marked }  // one change on screen, not one per text
    }

    /// The newest of my texts they've seen, if it's my newest text ("Seen" goes under it).
    var seenId: Int64? {
        guard let newest = bubbles.last(where: { b in b.mine && { if case .text = b.content { true } else { false } }() }) else { return nil }
        return newest.seen ? newest.id : nil
    }

    // ---------- "Seen by" in groups ----------

    /// Where each member has read up to (groups only).
    private(set) var groupReads: [Int64: (username: String, last: Int64)] = [:]

    func loadGroupReads() async {
        guard case .group(let group) = chat, let server = try? Server(account.server, transport: transport) else { return }
        struct Read: Decodable { let userId: Int64; let username: String; let lastReadId: Int64? }
        guard let data = try? await server.send("groups/\(group.id)/reads", token: account.token),
              let reads = try? Server.decoder.decode([Read].self, from: data) else { return }
        groupReads = Dictionary(uniqueKeysWithValues: reads.map { ($0.userId, ($0.username, $0.lastReadId ?? 0)) })
    }

    /// Someone in the group read up to a message (the `group_read` event).
    func groupRead(group: Int64, user: Int64, last: Int64) {
        guard case .group(let g) = chat, g.id == group else { return }
        if let r = groupReads[user] {
            if last > r.last { groupReads[user] = (r.username, last) }
        } else {
            Task { await loadGroupReads() }  // someone new: the member list changed
        }
    }

    /// "Seen by Ana and Ben" under the newest message (app.js, `seenByText`).
    var seenBy: String? {
        guard case .group = chat, let last = bubbles.last(where: { if case .event = $0.content { false } else { true } }) else { return nil }
        let others = groupReads.filter { $0.key != account.user.id && $0.key != last.senderId }
        let seen = others.filter { $0.value.last >= last.id }.map { reader.name($0.key, $0.value.username) }.sorted()
        if seen.isEmpty { return nil }
        if seen.count == others.count && others.count > 2 { return "Seen by everyone" }
        if seen.count > 3 { return "Seen by \(seen.prefix(2).joined(separator: ", ")), and \(seen.count - 2) others" }
        if seen.count == 1 { return "Seen by \(seen[0])" }
        return "Seen by \(seen.dropLast().joined(separator: ", "))\(seen.count > 2 ? "," : "") and \(seen.last!)"
    }

    // ---------- every version of an edited text ----------

    struct Version: Identifiable, Sendable {
        let id: Int
        let text: String?  // nil: couldn't be opened
        let at: Date
        let label: String
    }

    /// The text as sent, then each edit, oldest first, each opened here.
    func versions(of bubble: Bubble) async throws -> [Version] {
        let server = try Server(account.server, transport: transport)
        var out = [Version(id: 0, text: bubble.original, at: bubble.time, label: "Sent")]
        switch chat {
        case .friend(let friend):
            struct Edit: Decodable { let ciphertext: String; let createdAt: Int64 }
            let edits = try Server.decoder.decode([Edit].self, from: await server.send("chats/\(friend.id)/messages/\(bubble.id)/edits", token: account.token))
            let (sender, recipient) = bubble.mine ? (account.user.id, friend.id) : (friend.id, account.user.id)
            let keys = reader.readingKeys(friend, ring: ring)
            for (n, e) in edits.enumerated() {
                let text = keys.lazy.compactMap {
                    try? E2E.decryptEdit($0, e.ciphertext, sender: sender, recipient: recipient, message: bubble.id)
                }.first
                out.append(Version(id: n + 1, text: text, at: Date(timeIntervalSince1970: TimeInterval(e.createdAt)), label: "Edited"))
            }
        case .group(let group):
            struct Edit: Decodable { let content: String; let clientId: String; let createdAt: Int64; let key: String? }
            let edits = try Server.decoder.decode([Edit].self, from: await server.send("groups/\(group.id)/messages/\(bubble.id)/edits", token: account.token))
            let wrapKeys = reader.wrapKeys(from: bubble.senderId, server: nil, ring: ring)
            for (n, e) in edits.enumerated() {
                var text: String?
                if let wrap = e.key, let bytes = try? E2E.fromB64(e.content) {
                    for wrapKey in wrapKeys {
                        let o = E2E.GroupOpening(groupId: group.id, senderId: bubble.senderId, myId: account.user.id, clientId: e.clientId,
                                                 recipients: bubble.recipients ?? [], wrapKey: wrapKey)
                        if let t = try? E2E.decryptGroupEdit(bytes, wrap: wrap, message: bubble.id, o) { text = t; break }
                    }
                }
                out.append(Version(id: n + 1, text: text, at: Date(timeIntervalSince1970: TimeInterval(e.createdAt)), label: "Edited"))
            }
        }
        return out
    }

    /// I'm typing: tells them, at most every couple of seconds (the web app's pace).
    func noteTyping(_ live: Live) {
        guard canSend, Date().timeIntervalSince(lastTypingSent) >= 2 else { return }
        lastTypingSent = Date()
        switch chat {
        case .friend(let friend): live.sendTyping(to: .friend(friend.id))
        case .group(let group): live.sendTyping(to: .group(group.id))
        }
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

    func bubble(_ id: Int64) -> Bubble? {
        let slot = bubbles.slot(of: id)
        return slot.found ? bubbles[slot.index] : nil
    }

    /// Friends by id, for names (a group's members, adding people).
    var friendsById: [Int64: Friend] { reader.friends }

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

    /// Opened again: the chat list's newest view of who's who, their keys, and this chat.
    /// What's shown and what's still being sent carry on.
    func update(_ chat: Chat, reader: Reader) {
        self.chat = chat
        self.reader = Self.current(reader, pinBook)
    }

    /// A reader with the pins as they are now. The shared book is the truth:
    /// a key accepted here (or in another chat) since the list last loaded
    /// must not be undone by the list's older copy, or texts would be sealed
    /// to the old key.
    private static func current(_ reader: Reader, _ pinBook: PinBook?) -> Reader {
        guard let pinBook else { return reader }
        var reader = reader
        reader.pins = pinBook.pins
        reader.changed = pinBook.changed
        return reader
    }

    /// Why nothing can be sent here, when it's the chat itself (the web app's words).
    var blockedNote: String? {
        guard let friend else { return nil }
        if friend.system == true { return "Messages from Team Napsack, for birthdays and other occasions. You can't reply here." }
        if friend.deactivated == true { return "This account has been turned off. You can read your chat, but nothing new can be sent." }
        return nil
    }

    var canSend: Bool { loaded && !keyChanged && blockedNote == nil }

    /// Sends a text: it shows at once, and goes when it can.
    func send(_ text: String, replyTo: Int64?) async {
        await retry(queue(text, replyTo: replyTo))
    }

    /// Puts a text in the outbox, to show at once; `retry` sends it.
    func queue(_ text: String, replyTo: Int64?) -> String {
        let item = Outgoing(id: Self.newClientId(), text: text, replyTo: replyTo)
        outbox.append(item)
        holdBehindUnsent()
        return item.id
    }

    /// Sends a queued text, or tries one that wasn't sent again (with the
    /// texts held behind it). Returns once it's in, or can't go yet.
    func retry(_ id: String) async {
        guard let i = outbox.firstIndex(where: { $0.id == id }) else { return }
        if case .failed = outbox[i].status {
            outbox[i].status = .sending
            offline.remove(id)
        }
        holdBehindUnsent()
        await sendInOrder()
    }

    /// Gives up on a text; returns it, so it can go back in the box. The
    /// texts held behind it go on.
    func discard(_ id: String) -> String? {
        guard let i = outbox.firstIndex(where: { $0.id == id }) else { return nil }
        sealedTexts[id] = nil
        sealedGroupTexts[id] = nil
        offline.remove(id)
        let text = outbox.remove(at: i).text
        holdBehindUnsent()
        if sending == nil, outbox.first?.status == .sending { Task { await sendInOrder() } }
        return text
    }

    /// The outbox sending, while it is.
    @ObservationIgnored private var sending: Task<Void, Never>?

    /// A chat's texts go one at a time, oldest first (Nate, 2026-11-03: texts
    /// stay in order): each is posted only once the one before has its
    /// answer, so the server stores them, and numbers them, in the order they
    /// were written (every chat and page is in the server's order). Writing
    /// stays instant: the outbox shows each at once. Returns when nothing
    /// more can go now (all sent, or held behind one that wasn't).
    private func sendInOrder() async {
        if let sending { return await sending.value }
        let task = Task {
            while let next = outbox.first, next.status == .sending { await attempt(next.id) }
            sending = nil  // with no wait since the check: a text queued meanwhile was seen by it
        }
        sending = task
        await task.value
    }

    /// Texts behind one that wasn't sent wait for it ("held"); with none
    /// unsent before them, they go.
    private func holdBehindUnsent() {
        var blocked = false
        for i in outbox.indices {
            switch outbox[i].status {
            case .failed: blocked = true
            case .sending where blocked: outbox[i].status = .held
            case .held where !blocked: outbox[i].status = .sending
            default: break
            }
        }
    }

    /// 16 random bytes, base64url, as the web app makes them.
    static func newClientId() -> String {
        E2E.toB64(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func attempt(_ id: String) async {
        guard let i = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox[i].status = .sending
        offline.remove(id)
        var failure: (any Error)?
        for n in 0...retryDelays.count {
            guard let item = outbox.first(where: { $0.id == id }) else { return }
            do {
                let bubble = try await post(item)
                settle(id, bubble)
                return
            } catch {
                failure = error
                guard (error as? ServerError)?.retryable == true, n < retryDelays.count else { break }
                try? await Task.sleep(for: retryDelays[n])
            }
        }
        guard let i = outbox.firstIndex(where: { $0.id == id }) else { return }
        let connection = failure.map { ($0 as? ServerError)?.retryable == true } ?? true
        if connection { offline.insert(id) }
        Reporter.shared.report(.warn, "send failed", failure.map { Reporter.fields($0, ["group": groupFlag]) } ?? [:])
        let why = connection ? "no connection." : failure?.localizedDescription ?? "no connection."
        outbox[i].status = .failed("Not sent: \(why)")
        holdBehindUnsent()  // the ones after it wait for it
    }

    /// It's in: the server's copy joins the chat, and the outbox lets it go.
    private func settle(_ id: String, _ bubble: Bubble) {
        _ = discard(id)
        upsert(bubble)
    }

    private func post(_ item: Outgoing) async throws -> Bubble {
        let server = try Server(account.server, transport: transport)
        switch chat {
        case .friend(let friend):
            let ciphertext = try sealedTexts[item.id]
                ?? E2E.encryptText2(sendingPairKey(friend), item.text, replyTo: item.replyTo, sender: account.user.id, recipient: friend.id)
            sealedTexts[item.id] = ciphertext
            let m = try await server.sendText(to: friend.id, ciphertext: ciphertext, clientId: item.id, token: account.token)
            return reader.bubble(m, with: friend, ring: ring)
        case .group(let group):
            var sealed: E2E.GroupMessage
            if let kept = sealedGroupTexts[item.id] { sealed = kept } else { sealed = try await seal(item, for: group, server: server) }
            sealedGroupTexts[item.id] = sealed
            let m: GroupMessage
            do {
                m = try await server.sendGroupText(to: group.id, sealed, token: account.token)
            } catch ServerError.refused(_, status: 409) {
                // Someone joined or left since it was sealed: seal it again for who's there now.
                sealed = try await seal(item, for: group, server: server)
                sealedGroupTexts[item.id] = sealed
                m = try await server.sendGroupText(to: group.id, sealed, token: account.token)
            }
            return reader.bubble(m, ring: ring)
        }
    }

    /// Seals a group text for its members now, each to the key I pinned for them.
    private func seal(_ item: Outgoing, for group: GroupSummary, server: Server) async throws -> E2E.GroupMessage {
        try E2E.encryptGroupText(item.text, replyTo: item.replyTo, groupId: group.id, senderId: account.user.id,
                                 wrapKeys: await wrapKeys(for: group, server: server))
    }

    /// Each member's wrap key, to the key I pinned for them (the group is blocked if one changed).
    private func wrapKeys(for group: GroupSummary, server: Server) async throws -> [Int64: SymmetricKey] {
        let members = try await server.group(group.id, token: account.token).members
        var wrapKeys: [Int64: SymmetricKey] = [:]
        for member in members {
            wrapKeys[member.id] = try ring.groupWrap(mine: reader.identity, theirs: sendingKey(member),
                                                     myId: account.user.id, theirId: member.id)
        }
        return wrapKeys
    }

    // ---------- sending a photo ----------

    /// Sends a photo (a JPEG made on the phone) with its caption sealed in:
    /// format 6 to a friend, 7 to a group (app.js, `sendSnapTo`, `sendGroupPicTo`).
    /// Sealed once and sent with the same id on every try, so a retry is never
    /// a second pic; a group that changed meanwhile (409) is sealed again for who's there now.
    func sendPhoto(_ jpeg: Data, caption: String, y: Double? = nil, maxBytes: Int? = nil) async throws {
        try await sendMedia(jpeg, video: nil, caption: caption, y: y, maxBytes: maxBytes)
    }

    /// A video from the camera (MP4): format 4 to a friend, 5 to a group, sealed the same way.
    func sendVideo(_ mp4: Data, caption: String, y: Double? = nil, maxBytes: Int? = nil) async throws {
        try await sendMedia(mp4, video: "video/mp4", caption: caption, y: y, maxBytes: maxBytes)
    }

    /// A photo (`video` nil) or a video of that type.
    private func sendMedia(_ media: Data, video: String?, caption: String, y: Double?, maxBytes: Int?) async throws {
        let jpeg = media
        let server = try Server(account.server, transport: transport)
        let caption = String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        switch chat {
        case .friend(let friend):
            let key = try sendingPairKey(friend)
            let sealed = try video.map { try E2E.encryptVideo(key, jpeg, type: $0, caption: caption, sender: account.user.id, recipient: friend.id, y: y) }
                ?? E2E.encryptImage(key, jpeg, caption: caption, sender: account.user.id, recipient: friend.id, y: y)
            if let maxBytes, sealed.count > maxBytes { throw SendError.tooLarge }
            let format = video == nil ? E2E.imageFormat : E2E.videoFormat
            let query = [URLQueryItem(name: "format", value: String(format)), URLQueryItem(name: "client_id", value: Self.newClientId())]
            let data = try await retrying {
                try await server.upload("chats/\(friend.id)/snaps", data: sealed, contentType: "application/octet-stream",
                                        token: self.account.token, query: query)
            }
            upsert(reader.bubble(try Server.decoder.decode(DirectMessage.self, from: data), with: friend, ring: ring))
        case .group(let group):
            func seal() async throws -> E2E.GroupMessage {
                let keys = try await wrapKeys(for: group, server: server)
                if let video {
                    return try E2E.encryptGroupVideo(jpeg, type: video, caption: caption, y: y, groupId: group.id, senderId: account.user.id, wrapKeys: keys)
                }
                return try E2E.encryptGroupImage(jpeg, caption: caption, y: y, groupId: group.id, senderId: account.user.id, wrapKeys: keys)
            }
            let format = video == nil ? E2E.groupImageFormat : E2E.groupVideoFormat
            func post(_ sealed: E2E.GroupMessage) async throws -> Data {
                let keys = try JSONSerialization.data(withJSONObject: [
                    "client_id": sealed.clientId, "recipients": sealed.recipients,
                    "wraps": Dictionary(uniqueKeysWithValues: sealed.wraps.map { (String($0.key), $0.value) }),
                ])
                return try await retrying {
                    try await server.upload("groups/\(group.id)/pics", data: sealed.content, contentType: "application/octet-stream",
                                            token: self.account.token, query: [URLQueryItem(name: "format", value: String(format))],
                                            headers: ["X-Napsack-Keys": String(decoding: keys, as: UTF8.self)])
                }
            }
            var sealed = try await seal()
            if let maxBytes, sealed.content.count > maxBytes { throw SendError.tooLarge }
            let data: Data
            do {
                data = try await post(sealed)
            } catch ServerError.refused(_, status: 409) {
                sealed = try await seal()  // someone joined or left since
                data = try await post(sealed)
            }
            upsert(reader.bubble(try Server.decoder.decode(GroupMessage.self, from: data), ring: ring))
        }
        Reporter.shared.report(.info, video == nil ? "pic sent" : "video sent", ["group": groupFlag, "bytes": String(jpeg.count)])
    }

    /// A photo as napsack sends one: at most 1280 on its longest side, JPEG,
    /// smaller and smaller until it fits (app.js, `compressPhoto`).
    nonisolated static func photoJPEG(_ image: UIImage, maxBytes: Int = 500_000) -> Data? {  // under the server's 512 KB, with room for sealing
        var edge: CGFloat = 1280
        while edge >= 320 {
            let scale = min(1, edge / max(image.size.width, image.size.height))
            let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            for quality in [0.8, 0.68, 0.56] {
                if let data = drawn.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
            }
            edge *= 0.75
        }
        return nil
    }

    /// Mine, the one pinned for them, or (first seen, friend or not) the server's, which is pinned.
    /// A key that differs from the pin blocks the group, as a direct chat is blocked.
    private func sendingKey(_ member: Server.GroupDetail.Member) throws -> String {
        if member.id == account.user.id { return account.publicKey }
        if let pinned = reader.pins.current[member.id] {
            guard pinned == member.publicKey else {
                Reporter.shared.report(.warn, "group member key changed; group blocked", ["user_id": String(member.id)])
                throw SendError.memberKeyChanged(reader.name(member.id, member.username))
            }
            return pinned
        }
        pinBook?.see(senders: [(member.id, member.publicKey)])
        reader.pins = pinBook?.pins ?? reader.pins
        if pinBook == nil { _ = reader.pins.see(member.id, member.publicKey) }
        return member.publicKey
    }

    /// Trusts the friend's new key (compared or not), then reopens the chat with it.
    func acceptNewKey(verified: Bool) async throws {
        guard let friend, let pinBook else { return }
        pinBook.accept(friend)
        Reporter.shared.report(.info, "friend key accepted", ["friend_id": String(friend.id), "verified": String(verified)])
        reader.pins = pinBook.pins
        reader.changed = pinBook.changed
        try await loadNewest()
    }

    /// The newest page, replacing what's shown.
    func loadNewest() async throws {
        // What was kept, at once, while the server answers (read and opened off the main thread).
        if !loaded, let cache {
            let key = cacheKey
            if let kept = await Task.detached(priority: .userInitiated, operation: { cache.read(key) }).value,
               let page = try? await bubbles(from: kept), !page.isEmpty, !loaded {
                bubbles = page
                reachedStart = page.count < Self.page
                loaded = true
            }
        }
        let page = try await fetch(before: nil)
        noteUnreadable(page)
        if loaded {
            // Already on screen (the kept copy): change only what changed. Replacing
            // the whole list moved the scroll view back to the bottom, stopping a
            // scroll under way for a second or two as the chat opened (D17).
            join(page)
        } else {
            bubbles = page
            reachedStart = page.count < Self.page
        }
        loaded = true
        problem = nil
    }

    /// Back from a dropped connection: the newest page again, merged with what's
    /// shown. If more came than a page holds, it starts again from the newest.
    func catchUp() async throws {
        guard loaded else { return try await loadNewest() }
        join(try await fetch(before: nil))
    }

    /// The newest page, joined to what's shown: merged, unless a whole page came
    /// since the newest shown (a kept copy from long ago, or a long time
    /// offline). Then what's missing in between would never load (older pages
    /// come from before the oldest shown), so it starts again from the newest.
    private func join(_ page: [Bubble]) {
        if page.count == Self.page, let oldest = page.first?.id, let newest = bubbles.last?.id, oldest > newest {
            bubbles = page
            reachedStart = false
            return
        }
        merge(page)
    }

    /// A direct message, new or changed, from the socket. Returns whether it's
    /// a new text from them (to mark it read while it's on screen).
    @discardableResult func arrived(_ m: DirectMessage) -> Bool {
        guard loaded, let friend, [m.senderId, m.recipientId].contains(friend.id) else { return false }
        if m.senderId == account.user.id, let clientId = m.clientId { _ = discard(clientId) }  // it went
        let new = !bubbles.slot(of: m.id).found
        if new { typingUntil[m.senderId] = nil }  // their message is in: they're done typing
        upsert(reader.bubble(m, with: friend, ring: ring))
        return new && m.senderId == friend.id && m.kind == "text"
    }

    /// A group message, new or changed, from the socket. Returns whether it's new and someone else's.
    @discardableResult func arrived(_ m: GroupMessage) -> Bool {
        guard loaded, case .group(let group) = chat, m.groupId == group.id else { return false }
        if m.senderId == account.user.id, let clientId = m.clientId,
           let id = sealedGroupTexts.first(where: { $0.value.clientId == clientId })?.key {
            _ = discard(id)
        }
        if let pinBook, let key = m.senderPublicKey {
            pinBook.see(senders: [(m.senderId, key)])
            reader.pins = pinBook.pins
        }
        let new = !bubbles.slot(of: m.id).found
        if new { typingUntil[m.senderId] = nil }
        upsert(reader.bubble(m, ring: ring))
        return new && m.senderId != account.user.id
    }

    /// Reacts to a message; the same emoji again takes it back, another replaces it.
    /// Direct reactions are encrypted; group reactions aren't (each group says so).
    func react(_ bubble: Bubble, _ emoji: String) async throws {
        guard E2E.isReaction(emoji) else { throw SendError.notAReaction }
        let server = try Server(account.server, transport: transport)
        let next = bubble.myReaction == emoji ? nil : emoji
        switch chat {
        case .friend(let friend):
            let key = try sendingPairKey(friend)
            let ciphertext = try next.map { try E2E.encryptReaction(key, $0, sender: account.user.id, recipient: friend.id, message: bubble.id) }
            upsert(reader.bubble(try await server.react(to: bubble.id, friend: friend.id, ciphertext: ciphertext, token: account.token), with: friend, ring: ring))
        case .group(let group):
            upsert(reader.bubble(try await server.react(to: bubble.id, group: group.id, emoji: next, token: account.token), ring: ring))
        }
    }

    /// Replaces one of my texts with new words. Every version is kept on the
    /// server; the newest shows. Tried again while the connection is the
    /// problem, with the same `client_id`, so a retry isn't a second edit.
    func edit(_ bubble: Bubble, to text: String) async throws {
        let server = try Server(account.server, transport: transport)
        let clientId = Self.newClientId()
        switch chat {
        case .friend(let friend):
            let ciphertext = try E2E.encryptEdit(try sendingPairKey(friend), text, sender: account.user.id, recipient: friend.id, message: bubble.id)
            let m = try await retrying { try await server.editText(bubble.id, friend: friend.id, ciphertext: ciphertext, clientId: clientId, token: self.account.token) }
            upsert(reader.bubble(m, with: friend, ring: ring))
        case .group(let group):
            let members = try await server.group(group.id, token: account.token).members
            var wrapKeys: [Int64: SymmetricKey] = [:]
            for id in bubble.recipients ?? [] {
                let key: String
                if let member = members.first(where: { $0.id == id }) {
                    key = try sendingKey(member)
                } else if let known = id == account.user.id ? account.publicKey : reader.pins.current[id] {
                    key = known  // left the group since: the key I pinned
                } else {
                    throw SendError.cantEdit
                }
                wrapKeys[id] = try ring.groupWrap(mine: reader.identity, theirs: key, myId: account.user.id, theirId: id)
            }
            let sealed = try E2E.encryptGroupEdit(text, message: bubble.id, groupId: group.id, senderId: account.user.id, wrapKeys: wrapKeys)
            let m = try await retrying { try await server.editGroupText(bubble.id, group: group.id, sealed, token: self.account.token) }
            upsert(reader.bubble(m, ring: ring))
        }
    }

    /// Up to three tries while the connection is the problem.
    private func retrying<T>(_ body: () async throws -> T) async throws -> T {
        for delay in retryDelays {
            do { return try await body() } catch let error as ServerError where error.retryable {
                try? await Task.sleep(for: delay)
            }
        }
        return try await body()
    }

    /// The chat key for sending to a friend: with the key I pinned, never one the server swapped in.
    private func sendingPairKey(_ friend: Friend) throws -> SymmetricKey {
        if keyChanged { throw SendError.keyChanged(friend.username) }
        return try ring.pair(mine: reader.identity, theirs: reader.pins.current[friend.id] ?? friend.publicKey,
                             myId: account.user.id, theirId: friend.id)
    }

    // ---------- pics and videos, opened once ----------

    /// Fetches and decrypts a pic or video sent to me (app.js, `loadSnap`). Fetching doesn't open it;
    /// `confirmOpened` does, once it's been shown.
    func open(_ pic: PicToOpen) async throws -> OpenedPic {
        let server = try Server(account.server, transport: transport)
        switch pic {
        case .direct(let m):
            guard let friend else { throw SendError.cantOpen }
            let sealed = try await server.send("snaps/\(m.id)", token: account.token)
            for key in reader.readingKeys(friend, ring: ring) {
                if m.format == E2E.videoFormat, let v = try? E2E.decryptVideo(key, sealed, sender: m.senderId, recipient: m.recipientId) {
                    return try OpenedPic(image: nil, video: Self.temporaryVideo(v.media, type: v.type), caption: v.caption, y: v.y)
                }
                if m.format == E2E.imageFormat, let p = try? E2E.decryptImage(key, sealed, sender: m.senderId, recipient: m.recipientId) {
                    return OpenedPic(image: p.media, video: nil, caption: p.caption, y: p.y)
                }
                if [1, 2].contains(m.format), let p = try? E2E.decryptPic(key, sealed, format: m.format, sender: m.senderId, recipient: m.recipientId) {
                    return OpenedPic(image: p.photo, video: nil, caption: p.caption, y: nil)
                }
            }
            throw SendError.cantOpen
        case .group(let m):
            guard let id = m.pic?.id, let wrap = m.key else { throw SendError.cantOpen }
            let sealed = try await server.send("groups/\(m.groupId)/pics/\(id)", token: account.token)
            for wrapKey in reader.wrapKeys(from: m.senderId, server: m.senderPublicKey, ring: ring) {
                let o = E2E.GroupOpening(groupId: m.groupId, senderId: m.senderId, myId: account.user.id,
                                         clientId: m.clientId ?? "", recipients: m.recipients ?? [], wrapKey: wrapKey)
                if m.format == E2E.groupVideoFormat, let v = try? E2E.decryptGroupVideo(sealed, wrap: wrap, o) {
                    return try OpenedPic(image: nil, video: Self.temporaryVideo(v.media, type: v.type), caption: v.caption, y: v.y)
                }
                if m.format == E2E.groupImageFormat, let p = try? E2E.decryptGroupImage(sealed, wrap: wrap, o) {
                    return OpenedPic(image: p.media, video: nil, caption: p.caption, y: p.y)
                }
                if m.format == E2E.groupFormat, let p = try? E2E.decryptGroupPic(sealed, wrap: wrap, o) {
                    return OpenedPic(image: p.photo, video: nil, caption: p.caption, y: nil)
                }
            }
            throw SendError.cantOpen
        }
    }

    /// It's been shown: now it's opened, and gone. A repeat is fine.
    func confirmOpened(_ pic: PicToOpen) async {
        let server = try? Server(account.server, transport: transport)
        switch pic {
        case .direct(let m): _ = try? await server?.send("snaps/\(m.id)/opened", method: "POST", token: account.token)
        case .group(let m):
            if let id = m.pic?.id { _ = try? await server?.send("groups/\(m.groupId)/pics/\(id)/opened", method: "POST", token: account.token) }
        }
        try? await catchUp()
    }

    /// A video to play: a file only this app can read, while the phone is unlocked, deleted once watched.
    nonisolated static func temporaryVideo(_ data: Data, type: String) throws -> URL {
        let ext = type.contains("mp4") ? "mp4" : type.contains("webm") ? "webm" : "mov"
        let url = FileManager.default.temporaryDirectory.appending(path: "napsack-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Back online: texts that couldn't go for the connection's sake go now.
    func flush() async {
        for id in outbox.map(\.id) where offline.contains(id) { await retry(id) }
    }

    private func upsert(_ bubble: Bubble) {
        merge([bubble])
    }

    /// Messages, new or changed, merged into what's shown in id order: each
    /// found by halving, the list changed once, and only if something did (the
    /// same again changes nothing on screen, D17).
    private func merge(_ page: [Bubble]) {
        var merged = bubbles, changed = false
        for bubble in page {
            let slot = merged.slot(of: bubble.id)
            if !slot.found {
                merged.insert(bubble, at: slot.index)
                changed = true
            } else if merged[slot.index] != bubble {
                merged[slot.index] = bubble
                changed = true
            }
        }
        if changed { bubbles = merged }
    }

    private var groupFlag: String {
        if case .group = chat { "true" } else { "false" }
    }

    /// Messages that couldn't be opened say so in the chat; the log viewer gets how many, nothing more.
    private func noteUnreadable(_ page: [Bubble]) {
        let count = page.filter { $0.content == .unreadable(Reader.cantOpen) }.count
        if count > 0 { Reporter.shared.report(.warn, "messages couldn't be decrypted", ["count": String(count), "group": groupFlag]) }
    }

    /// The page before the oldest shown.
    func loadOlder() async throws {
        guard loaded, !reachedStart, !loadingOlder, let oldest = bubbles.first?.id else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let page = try await fetch(before: oldest)
        guard bubbles.first?.id == oldest else { return }  // started again from the newest meanwhile (catchUp)
        bubbles = page.filter { $0.id < oldest } + bubbles
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

    /// Where this chat's newest page is kept on the phone (ResponseCache).
    private var cacheKey: String {
        switch chat {
        case .friend(let friend): "chat-d-\(friend.id)"
        case .group(let group): "chat-g-\(group.id)"
        }
    }

    private func fetch(before: Int64?) async throws -> [Bubble] {
        let server = try Server(account.server, transport: transport)
        let path = switch chat {
        case .friend(let friend): "chats/\(friend.id)/messages"
        case .group(let group): "groups/\(group.id)/messages"
        }
        let data = try await server.send(path, token: account.token, query: Server.page(before: before, limit: Self.page))
        let kept = before == nil ? keep(data) : nil  // as sent: still encrypted (written while the page is opened)
        let page = try await bubbles(from: data)
        await kept?.value
        return page
    }

    /// Keeps the newest page on the phone, off the main thread, each write after the last.
    private func keep(_ data: Data) -> Task<Void, Never>? {
        guard let cache else { return nil }
        let key = cacheKey, previous = keeping
        let write = Task.detached(priority: .userInitiated) {
            await previous?.value
            cache.write(data, key)
        }
        keeping = write
        return write
    }

    /// A page of messages (from the server, or kept): read and opened off the main thread.
    private func bubbles(from data: Data) async throws -> [Bubble] {
        let ring = self.ring
        switch chat {
        case .friend(let friend):
            let reader = self.reader
            return try await Task.detached(priority: .userInitiated) {
                try Server.decoder.decode([DirectMessage].self, from: data).map { reader.bubble($0, with: friend, ring: ring) }
            }.value
        case .group:
            // Senders seen here for the first time are pinned before anything is
            // read (on the main actor, where the pins live), so the page is read
            // with the same keys on every open: a message sealed with another key
            // than the first one seen reads as it will next time, not by the
            // server's say-so this once.
            let messages = try await Task.detached(priority: .userInitiated) {
                try Server.decoder.decode([GroupMessage].self, from: data)
            }.value
            if let pinBook {
                pinBook.see(senders: messages.compactMap { m in m.senderPublicKey.map { (m.senderId, $0) } })
                reader.pins = pinBook.pins
            }
            let reader = self.reader
            return await Task.detached(priority: .userInitiated) { messages.map { reader.bubble($0, ring: ring) } }.value
        }
    }
}
