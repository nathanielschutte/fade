import CryptoKit
import Foundation
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

extension Reader {
    static let tooNew = "Update napsack to read this"
    static let cantOpen = "This message couldn't be decrypted"

    func bubble(_ m: DirectMessage, with friend: Friend) -> Bubble {
        let mine = m.senderId == me.id
        let content: Bubble.Content
        var replyTo: Int64?
        var opening: PicToOpen?
        if m.kind == "snap" {
            let word = m.format == E2E.videoFormat ? "video" : "pic", Word = word.capitalized
            let words = mine
                ? ["pending": "Sent a \(word)", "opened": "\(Word) opened", "expired": "\(Word) expired unopened"]
                : ["pending": "New \(word)", "opened": "\(Word) viewed", "expired": "\(Word) expired"]
            content = .media(words[m.snapState ?? ""] ?? Word)
            if !mine && m.snapState == "pending" { opening = .direct(m) }
        } else if ![1, 2].contains(m.format) {
            content = .unreadable(Self.tooNew)
        } else if let opened = body(m, with: friend) {
            content = .text(opened.text.text, edited: opened.edited)
            replyTo = opened.text.replyTo
        } else {
            content = .unreadable(Self.cantOpen)
        }
        let keys = readingKeys(friend)
        let reactions = (m.reactions ?? []).compactMap { r -> (Int64, String)? in
            let to = r.senderId == me.id ? friend.id : me.id
            return keys.lazy.compactMap { try? E2E.decryptReaction($0, r.ciphertext, sender: r.senderId, recipient: to, message: m.id) }.first
                .map { (r.senderId, $0) }
        }
        var bubble = Bubble(id: m.id, mine: mine, sender: nil, content: content, replyTo: replyTo,
                            time: Date(timeIntervalSince1970: TimeInterval(m.createdAt)), reactions: reactions.map(\.1))
        bubble.myReaction = reactions.first { $0.0 == me.id }?.1
        if case .text = content { bubble.editable = mine }
        bubble.seen = mine && m.kind == "text" && m.readAt != nil
        bubble.opening = opening
        return bubble
    }

    func bubble(_ m: GroupMessage) -> Bubble {
        let mine = m.senderId == me.id
        let content: Bubble.Content
        var replyTo: Int64?
        var opening: PicToOpen?
        if m.kind == "event" {
            content = .event(eventText(m))
        } else if let pic = m.pic {
            let word = m.format == E2E.groupVideoFormat ? "video" : "pic", Word = word.capitalized
            content = .media(
                pic.discardReason == "expired" ? "\(Word) expired"
                : mine ? "Sent a \(word)"
                : pic.viewers.contains(me.id) ? "\(Word) viewed" : "New \(word)")
            if !mine && pic.discardReason == nil && !pic.viewers.contains(me.id) { opening = .group(m) }
        } else if ![0, E2E.groupFormat].contains(m.format) {
            content = .unreadable(Self.tooNew)
        } else if let opened = groupBody(m) {
            content = .text(opened.text.text, edited: opened.edited)
            replyTo = opened.text.replyTo
        } else {
            content = .unreadable(Self.cantOpen)
        }
        var bubble = Bubble(id: m.id, mine: mine, sender: mine || m.kind == "event" ? nil : name(m.senderId, m.senderName),
                            content: content, replyTo: replyTo, time: Date(timeIntervalSince1970: TimeInterval(m.createdAt)),
                            reactions: (m.reactions ?? []).map(\.emoji))
        bubble.myReaction = m.reactions?.first { $0.userId == me.id }?.emoji
        if case .text = content { bubble.editable = mine && m.format == E2E.groupFormat }
        bubble.recipients = m.recipients
        bubble.opening = opening
        return bubble
    }
}

/// A text on its way: shown at once, below the chat, until the server has it.
struct Outgoing: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case sending
        /// Why, in words ("Not sent: no connection.").
        case failed(String)
    }

    /// The message's `client_id`: the same on every try, so the server never stores it twice.
    let id: String
    let text: String
    let replyTo: Int64?
    var status: Status = .sending
}

/// Why napsack won't send.
enum SendError: LocalizedError {
    case keyChanged(String)
    case memberKeyChanged(String)
    case cantEdit
    case cantOpen
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .keyChanged(let username): "\(username)'s safety code changed. Messages are blocked."
        case .cantEdit: "This text can't be edited: napsack doesn't have the key of everyone it went to."
        case .cantOpen: "This pic couldn't be shown. It's still unopened."
        case .tooLarge: "That photo is too large to send."
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
/// send wait in an outbox until the server has them (app.js, the outbox): a
/// bad connection is tried again, and a text that still can't go waits as
/// "Not sent" with Try again. Unsent texts are only in memory, never kept.
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

    /// Oldest first.
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

    init(_ chat: Chat, account: Account, reader: Reader, pinBook: PinBook? = nil, transport: any Transport = NetworkTransport()) {
        self.chat = chat
        self.account = account
        self.reader = reader
        self.pinBook = pinBook
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
        for i in bubbles.indices where bubbles[i].mine && !bubbles[i].seen && bubbles[i].time <= upTo {
            if case .text = bubbles[i].content { bubbles[i].seen = true }
        }
    }

    /// The newest of my texts they've seen, if it's my newest text ("Seen" goes under it).
    var seenId: Int64? {
        guard let newest = bubbles.last(where: { b in b.mine && { if case .text = b.content { true } else { false } }() }) else { return nil }
        return newest.seen ? newest.id : nil
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

    func bubble(_ id: Int64) -> Bubble? { bubbles.first { $0.id == id } }

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
        self.reader = reader
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
        return item.id
    }

    /// Sends a queued text, or tries one that wasn't sent again.
    func retry(_ id: String) async { await attempt(id) }

    /// Gives up on a text; returns it, so it can go back in the box.
    func discard(_ id: String) -> String? {
        guard let i = outbox.firstIndex(where: { $0.id == id }) else { return nil }
        sealedTexts[id] = nil
        sealedGroupTexts[id] = nil
        offline.remove(id)
        return outbox.remove(at: i).text
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
            return reader.bubble(m, with: friend)
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
            return reader.bubble(m)
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
            wrapKeys[member.id] = try E2E.groupWrapKey(mine: reader.identity, theirs: sendingKey(member),
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
        let server = try Server(account.server, transport: transport)
        let caption = String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        switch chat {
        case .friend(let friend):
            let sealed = try E2E.encryptImage(sendingPairKey(friend), jpeg, caption: caption, sender: account.user.id, recipient: friend.id, y: y)
            if let maxBytes, sealed.count > maxBytes { throw SendError.tooLarge }
            let query = [URLQueryItem(name: "format", value: String(E2E.imageFormat)), URLQueryItem(name: "client_id", value: Self.newClientId())]
            let data = try await retrying {
                try await server.upload("chats/\(friend.id)/snaps", data: sealed, contentType: "application/octet-stream",
                                        token: self.account.token, query: query)
            }
            upsert(reader.bubble(try Server.decoder.decode(DirectMessage.self, from: data), with: friend))
        case .group(let group):
            func seal() async throws -> E2E.GroupMessage {
                try E2E.encryptGroupImage(jpeg, caption: caption, y: y, groupId: group.id, senderId: account.user.id,
                                          wrapKeys: await wrapKeys(for: group, server: server))
            }
            func post(_ sealed: E2E.GroupMessage) async throws -> Data {
                let keys = try JSONSerialization.data(withJSONObject: [
                    "client_id": sealed.clientId, "recipients": sealed.recipients,
                    "wraps": Dictionary(uniqueKeysWithValues: sealed.wraps.map { (String($0.key), $0.value) }),
                ])
                return try await retrying {
                    try await server.upload("groups/\(group.id)/pics", data: sealed.content, contentType: "application/octet-stream",
                                            token: self.account.token, query: [URLQueryItem(name: "format", value: String(E2E.groupImageFormat))],
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
            upsert(reader.bubble(try Server.decoder.decode(GroupMessage.self, from: data)))
        }
        Reporter.shared.report(.info, "pic sent", ["group": groupFlag, "bytes": String(jpeg.count)])
    }

    /// A photo as napsack sends one: at most 1280 on its longest side, JPEG,
    /// smaller and smaller until it fits (app.js, `compressPhoto`).
    nonisolated static func photoJPEG(_ image: UIImage, maxBytes: Int = 900_000) -> Data? {
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
        let page = try await fetch(before: nil)
        noteUnreadable(page)
        bubbles = page
        reachedStart = page.count < Self.page
        loaded = true
        problem = nil
    }

    /// Back from a dropped connection: the newest page again, merged with what's
    /// shown. If more came than a page holds, it starts again from the newest.
    func catchUp() async throws {
        guard loaded else { return try await loadNewest() }
        let page = try await fetch(before: nil)
        if page.count == Self.page, let oldest = page.first?.id, let newest = bubbles.last?.id, oldest > newest {
            bubbles = page
            reachedStart = false
            return
        }
        page.forEach(upsert)
    }

    /// A direct message, new or changed, from the socket. Returns whether it's
    /// a new text from them (to mark it read while it's on screen).
    @discardableResult func arrived(_ m: DirectMessage) -> Bool {
        guard loaded, let friend, [m.senderId, m.recipientId].contains(friend.id) else { return false }
        if m.senderId == account.user.id, let clientId = m.clientId { _ = discard(clientId) }  // it went
        let new = !bubbles.contains { $0.id == m.id }
        if new { typingUntil[m.senderId] = nil }  // their message is in: they're done typing
        upsert(reader.bubble(m, with: friend))
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
        let new = !bubbles.contains { $0.id == m.id }
        if new { typingUntil[m.senderId] = nil }
        upsert(reader.bubble(m))
        return new && m.senderId != account.user.id
    }

    /// Reacts to a message; the same emoji again takes it back, another replaces it.
    /// Direct reactions are encrypted; group reactions aren't (each group says so).
    func react(_ bubble: Bubble, _ emoji: String) async throws {
        let server = try Server(account.server, transport: transport)
        let next = bubble.myReaction == emoji ? nil : emoji
        switch chat {
        case .friend(let friend):
            let key = try sendingPairKey(friend)
            let ciphertext = try next.map { try E2E.encryptReaction(key, $0, sender: account.user.id, recipient: friend.id, message: bubble.id) }
            upsert(reader.bubble(try await server.react(to: bubble.id, friend: friend.id, ciphertext: ciphertext, token: account.token), with: friend))
        case .group(let group):
            upsert(reader.bubble(try await server.react(to: bubble.id, group: group.id, emoji: next, token: account.token)))
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
            upsert(reader.bubble(m, with: friend))
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
                wrapKeys[id] = try E2E.groupWrapKey(mine: reader.identity, theirs: key, myId: account.user.id, theirId: id)
            }
            let sealed = try E2E.encryptGroupEdit(text, message: bubble.id, groupId: group.id, senderId: account.user.id, wrapKeys: wrapKeys)
            let m = try await retrying { try await server.editGroupText(bubble.id, group: group.id, sealed, token: self.account.token) }
            upsert(reader.bubble(m))
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
        return try E2E.pairKey(mine: reader.identity, theirs: reader.pins.current[friend.id] ?? friend.publicKey,
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
            for key in reader.readingKeys(friend) {
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
            for senderKey in reader.senderKeys(m.senderId, server: m.senderPublicKey) {
                guard let wrapKey = try? E2E.groupWrapKey(mine: reader.identity, theirs: senderKey, myId: account.user.id, theirId: m.senderId) else { continue }
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
        for id in outbox.map(\.id) where offline.contains(id) { await attempt(id) }
    }

    private func upsert(_ bubble: Bubble) {
        if let i = bubbles.firstIndex(where: { $0.id == bubble.id }) {
            bubbles[i] = bubble
        } else {
            bubbles.append(bubble)
            bubbles.sort { $0.id < $1.id }
        }
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
