import CryptoKit
import Foundation
import NapsackCrypto

// The chat list: your friends (`GET /api/friends`) and groups (`GET
// /api/groups`), each with its newest message, and what a row says about it.
// The wording follows the web app's (app.js, chatStatus and groupStatus).

/// A message in a direct chat, as lists and histories carry it.
struct DirectMessage: Decodable, Sendable, Equatable {
    let id: Int64
    let senderId: Int64
    let recipientId: Int64
    /// "text" or "snap" (a pic or video).
    let kind: String
    let ciphertext: String?
    let format: Int
    /// Pics and videos: "pending", "opened", or "expired".
    let snapState: String?
    let createdAt: Int64
    let readAt: Int64?
    /// Picked by the sender's app, so a resend isn't stored twice.
    let clientId: String?
    /// The newest edit of a text, sealed like it.
    let editCiphertext: String?
    /// Encrypted like the texts, each bound to this message.
    let reactions: [Reaction]?

    struct Reaction: Decodable, Sendable, Equatable {
        let senderId: Int64
        let ciphertext: String
        let createdAt: Int64
    }
}

struct Friend: Decodable, Sendable, Identifiable, Equatable {
    let id: Int64
    let username: String
    let displayName: String?
    /// What you call them; only you see it.
    let nickname: String?
    let publicKey: String
    let lastMessage: DirectMessage?
    let unread: Int
    let favorite: Bool
    let hidden: Bool
    let muted: Bool
    /// An Admin turned their account off: the chat is read-only.
    let deactivated: Bool?
    /// Team Napsack, napsack's own account (team-napsack.md).
    let system: Bool?
    /// When an admin reset their account, which gives them a new key.
    let keyResetAt: Int64?
    /// Their profile picture, if they have one (only friends get it).
    let avatarId: Int64?
    /// On screen now, and when they last were: only if you both share it (`share_activity`).
    let activeNow: Bool?
    let lastSeenAt: Int64?
    /// Days in a row you've both sent each other a pic, and whether it ends tonight (streaks.rs).
    let streak: Int?
    let streakExpiring: Bool?
    /// "MM-DD", if they've shared it.
    let birthday: String?

    /// What the app calls them: your nickname, their display name, or their username.
    var name: String { nickname ?? displayName ?? username }
}

struct GroupMessage: Decodable, Sendable, Equatable {
    struct Pic: Decodable, Sendable, Equatable {
        let id: Int64
        let viewers: [Int64]
        /// "opened" or "expired", once the file is gone.
        let discardReason: String?
    }

    let id: Int64
    let groupId: Int64
    let senderId: Int64
    let senderName: String
    /// "text" or "event" (someone added, left, renamed it, ...).
    let kind: String
    /// Format 0: the text itself. Events: a JSON description. Format 3: empty.
    let body: String
    let format: Int
    let createdAt: Int64
    let pic: Pic?
    /// Format 0's reply; format 3 carries its own inside the sealed text.
    let replyTo: Int64?
    /// Group reactions aren't encrypted (CLAUDE.md, Security; each group says so).
    let reactions: [Reaction]?

    struct Reaction: Decodable, Sendable, Equatable {
        let userId: Int64
        let emoji: String
    }
    // Format 3 (group-encryption.md): the sealed content, and only my own wrap of its key.
    let clientId: String?
    let recipients: [Int64]?
    let content: String?
    let key: String?
    let senderPublicKey: String?
    let editContent: String?
    let editClientId: String?
    let editKey: String?
}

struct GroupSummary: Decodable, Sendable, Identifiable, Equatable {
    let id: Int64
    let name: String
    let memberCount: Int
    let lastMessage: GroupMessage?
    let unread: Int
    let favorite: Bool
    let muted: Bool
    /// The group's picture, if it has one. Not end-to-end encrypted (each group says so).
    let avatarId: Int64?
}

/// One row of the list.
struct ChatRow: Identifiable, Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case friend(Int64)
        case group(Int64)
    }
    /// Something waiting: an unopened pic or video, or an unread text.
    enum Waiting: Sendable {
        case snap, text
    }

    let kind: Kind
    let name: String
    let preview: String
    let waiting: Waiting?
    let time: Date?
    let favorite: Bool
    let muted: Bool
    let hidden: Bool
    /// The friend's or group's picture, if any.
    var avatarId: Int64? = nil
    /// After the name: " 🔥5⌛ 🎂" (app.js, `listName`).
    var marks: String = ""

    var id: Kind { kind }
    var isGroup: Bool { if case .group = kind { true } else { false } }
}

/// What the rows need to know about the person reading them, and how to open
/// what they've been sent.
struct Reader: Sendable {
    let me: Me
    let identity: P256.KeyAgreement.PrivateKey
    /// Friends by id, for their names and keys.
    let friends: [Int64: Friend]
    /// Whose keys to trust (Pins.swift): messages are read with these, not
    /// whatever key the server hands out now.
    var pins = Pins()
    /// Friends whose key changed and hasn't been accepted.
    var changed: Set<Int64> = []
    /// Mine, for opening what I sent to a group.
    var myPublicKey = ""

    var myName: String { me.displayName ?? me.username }

    /// Anyone by what I call them: me by my display name, friends by their name, others by username.
    func name(_ id: Int64, _ username: String) -> String {
        id == me.id ? myName : friends[id]?.name ?? username
    }

    // ---------- direct chats ----------

    /// A streak shows from 3 days, with ⌛ when it ends tonight; a 🎂 on their birthday (app.js, `streakText`).
    static func marks(_ friend: Friend, today: Date = .now) -> String {
        var marks = ""
        if let streak = friend.streak, streak >= 3 { marks += " 🔥\(streak)" + (friend.streakExpiring == true ? "⌛" : "") }
        let parts = Calendar.current.dateComponents([.month, .day], from: today)
        if let b = friend.birthday, b == String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0) { marks += " 🎂" }
        return marks
    }

    func row(_ friend: Friend) -> ChatRow {
        let (preview, waiting) = status(friend)
        var row = ChatRow(kind: .friend(friend.id), name: friend.name, preview: preview, waiting: waiting,
                       time: friend.lastMessage.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) },
                       favorite: friend.favorite, muted: friend.muted, hidden: friend.hidden, avatarId: friend.avatarId)
        row.marks = Self.marks(friend)
        return row
    }

    func status(_ friend: Friend) -> (String, ChatRow.Waiting?) {
        if changed.contains(friend.id) { return ("Safety code changed", nil) }
        if friend.deactivated == true { return ("Account turned off", nil) }
        guard let m = friend.lastMessage else { return ("Say hi", nil) }
        let mine = m.senderId == me.id
        if m.kind == "snap" {
            let word = m.format == E2E.videoFormat ? "video" : "pic", Word = word.capitalized
            if !mine && m.snapState == "pending" { return ("New \(word)", .snap) }
            let label = mine
                ? ["pending": "Sent a \(word)", "opened": "\(Word) opened", "expired": "\(Word) expired unopened"]
                : ["opened": "\(Word) viewed", "expired": "\(Word) expired"]
            return (label[m.snapState ?? ""] ?? Word, nil)
        }
        let text = self.text(m, with: friend) ?? "Encrypted message"
        if !mine && m.readAt == nil { return (text, .text) }
        return (mine ? "You: \(text)" : text, nil)
    }

    /// A direct text, decrypted (its newest edit if it has one), or nil if it can't be.
    func text(_ m: DirectMessage, with friend: Friend) -> String? {
        body(m, with: friend)?.text.text
    }

    /// A direct text opened: what it says now (its newest edit), what it replies to, whether it was edited.
    func body(_ m: DirectMessage, with friend: Friend) -> (text: E2E.Text, edited: Bool)? {
        guard [1, 2].contains(m.format), let ciphertext = m.ciphertext else { return nil }
        for key in readingKeys(friend) {
            guard let body = try? E2E.decryptAnyText(key, ciphertext, format: m.format, sender: m.senderId, recipient: m.recipientId)
            else { continue }
            if let edit = m.editCiphertext,
               let edited = try? E2E.decryptEdit(key, edit, sender: m.senderId, recipient: m.recipientId, message: m.id) {
                return (E2E.Text(text: edited, replyTo: body.replyTo), true)
            }
            return (body, false)
        }
        return nil
    }

    /// Chat keys that can read a friend's messages: with the pinned key, then any accepted before it.
    func readingKeys(_ friend: Friend) -> [SymmetricKey] {
        pins.readingKeys(friend.id, server: friend.publicKey).compactMap {
            try? E2E.pairKey(mine: identity, theirs: $0, myId: me.id, theirId: friend.id)
        }
    }

    // ---------- groups ----------

    func row(_ group: GroupSummary) -> ChatRow {
        let (preview, waiting) = status(group)
        return ChatRow(kind: .group(group.id), name: group.name, preview: preview, waiting: waiting,
                       time: group.lastMessage.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) },
                       favorite: group.favorite, muted: group.muted, hidden: false, avatarId: group.avatarId)
    }

    func status(_ group: GroupSummary) -> (String, ChatRow.Waiting?) {
        guard let m = group.lastMessage else { return ("\(group.memberCount) people", nil) }
        let mine = m.senderId == me.id
        if let pic = m.pic {
            let what = "sent a \(m.format == E2E.groupVideoFormat ? "video" : "pic")"
            let waiting = !mine && pic.discardReason == nil && !pic.viewers.contains(me.id)
            return (mine ? "You \(what)" : "\(name(m.senderId, m.senderName)) \(what)", waiting ? .snap : group.unread > 0 ? .text : nil)
        }
        let text = m.kind == "event"
            ? eventText(m)
            : "\(mine ? "You" : name(m.senderId, m.senderName)): \(groupText(m) ?? "Encrypted message")"
        return (text, group.unread > 0 ? .text : nil)
    }

    /// A group text: format 0 as it is, format 3 opened with my wrap (and its newest edit).
    func groupText(_ m: GroupMessage) -> String? {
        groupBody(m)?.text.text
    }

    func groupBody(_ m: GroupMessage) -> (text: E2E.Text, edited: Bool)? {
        if m.format == 0 { return (E2E.Text(text: m.body, replyTo: m.replyTo), false) }
        guard m.format == E2E.groupFormat, let content = m.content, let wrap = m.key, let bytes = try? E2E.fromB64(content)
        else { return nil }
        for senderKey in senderKeys(m.senderId, server: m.senderPublicKey) {
            guard let wrapKey = try? E2E.groupWrapKey(mine: identity, theirs: senderKey, myId: me.id, theirId: m.senderId) else { continue }
            let opening = E2E.GroupOpening(groupId: m.groupId, senderId: m.senderId, myId: me.id,
                                           clientId: m.clientId ?? "", recipients: m.recipients ?? [], wrapKey: wrapKey)
            guard let body = try? E2E.decryptGroupText(bytes, wrap: wrap, opening) else { continue }
            if let editContent = m.editContent, let editKey = m.editKey, let editBytes = try? E2E.fromB64(editContent) {
                var edit = opening
                edit.clientId = m.editClientId ?? ""
                if let edited = try? E2E.decryptGroupEdit(editBytes, wrap: editKey, message: m.id, edit) {
                    return (E2E.Text(text: edited, replyTo: body.replyTo), true)
                }
            }
            return (body, false)
        }
        return nil
    }

    /// Keys that could have sealed a group message from someone: mine for my
    /// own, else the pinned ones (the server's only on first sight).
    func senderKeys(_ sender: Int64, server: String?) -> [String] {
        if sender == me.id { return [myPublicKey.isEmpty ? server : myPublicKey].compactMap { $0 } }
        return pins.readingKeys(sender, server: server)
    }

    func eventText(_ m: GroupMessage) -> String {
        let e = (try? JSONSerialization.jsonObject(with: Data(m.body.utf8))) as? [String: Any] ?? [:]
        let actor = m.senderId == me.id ? "You" : name(m.senderId, m.senderName)
        let targetId = (e["target"] as? NSNumber)?.int64Value
        let target = targetId == me.id ? "you" : name(targetId ?? 0, e["target_name"] as? String ?? "someone")
        let groupName = e["name"] as? String ?? ""
        switch e["type"] as? String {
        case "created": return "\(actor) created the group “\(groupName)”"
        case "added": return "\(actor) added \(target)"
        case "removed": return "\(actor) removed \(target)"
        case "left": return "\(actor) left"
        case "renamed": return "\(actor) renamed the group to “\(groupName)”"
        case "owner": return targetId == me.id ? "You're now the owner" : "\(target) is now the owner"
        case "picture": return "\(actor) changed the group picture"
        case "encrypted": return "Messages and pics here are end-to-end encrypted from now on. The group's name and picture aren't."
        default: return "The group changed"
        }
    }

    /// Friends and groups in one list, newest first (then by name), as the web app orders it.
    func rows(friends: [Friend], groups: [GroupSummary]) -> [ChatRow] {
        (friends.map(row) + groups.map(row)).sorted {
            let a = $0.time ?? .distantPast, b = $1.time ?? .distantPast
            return a != b ? a > b : $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }
}

/// The signed-in person's chat list, loaded from the server.
@MainActor @Observable final class ChatList {
    private(set) var rows: [ChatRow] = []
    private(set) var loaded = false
    private(set) var problem: String?
    /// What opening a chat needs: who's who, their keys, and the groups.
    private(set) var reader: Reader?
    private(set) var groups: [Int64: GroupSummary] = [:]
    /// Whose keys to trust (Pins.swift), shared with open chats.
    private(set) var pinBook: PinBook?
    /// Friend requests waiting on you: the badge on Friends.
    private(set) var incoming = 0
    /// The Admins' current announcement, if there is one (and it isn't over).
    private(set) var announcement: Announcement?

    static let dismissedAnnouncementKey = "napsack.announcementDismissed"

    struct Announcement: Decodable, Equatable, Sendable {
        let id: Int64
        let body: String
        let endsAt: Int64
    }

    /// From the socket: a new one, or none.
    func announce(_ a: Announcement?) {
        announcement = a.flatMap { $0.endsAt > Int64(Date().timeIntervalSince1970) ? $0 : nil }
    }

    var favorites: [ChatRow] { rows.filter { $0.favorite && !$0.hidden } }
    var others: [ChatRow] { rows.filter { !$0.favorite && !$0.hidden } }
    /// Chats you hid (archived): out of the list until you open "Hidden chats", or a new message shows them again.
    var hiddenRows: [ChatRow] { rows.filter(\.hidden) }

    // ---------- the list's own actions (app.js, the row actions) ----------

    private struct On: Encodable { let on: Bool; var hours: Int? = nil }

    private func path(_ kind: ChatRow.Kind, _ what: String) -> String {
        switch kind {
        case .friend(let id): "chats/\(id)/\(what)"
        case .group(let id): "groups/\(id)/\(what)"
        }
    }

    /// Kept at the top (up to 10, direct and groups together: the server says so past that).
    func setFavorite(_ row: ChatRow, _ on: Bool, account: Account, transport: any Transport = NetworkTransport()) async throws {
        _ = try await Server(account.server, transport: transport).send(path(row.kind, "favorite"), method: "PUT", token: account.token, json: On(on: on))
        try await load(account, transport: transport)
    }

    /// No notifications and no unread dot: for `hours`, or until turned back on (nil).
    func setMuted(_ row: ChatRow, _ on: Bool, hours: Int? = nil, account: Account, transport: any Transport = NetworkTransport()) async throws {
        _ = try await Server(account.server, transport: transport).send(path(row.kind, "mute"), method: "PUT", token: account.token,
                                                                         json: On(on: on, hours: on ? hours : nil))
        try await load(account, transport: transport)
    }

    /// Out of the list, or back. Only direct chats; you leave a group instead.
    func setHidden(_ row: ChatRow, _ on: Bool, account: Account, transport: any Transport = NetworkTransport()) async throws {
        guard case .friend = row.kind else { return }
        _ = try await Server(account.server, transport: transport).send(path(row.kind, "hidden"), method: "PUT", token: account.token, json: On(on: on))
        try await load(account, transport: transport)
    }

    /// Leaves a group: the membership is marked ended, nothing is deleted.
    func leave(_ row: ChatRow, account: Account, transport: any Transport = NetworkTransport()) async throws {
        guard case .group(let id) = row.kind else { return }
        _ = try await Server(account.server, transport: transport).send("groups/\(id)/members/\(account.user.id)", method: "DELETE", token: account.token)
        try await load(account, transport: transport)
    }

    /// Rows whose name or newest message (as shown, already decrypted here) has the words.
    func search(_ text: String) -> [ChatRow] {
        let words = text.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return [] }
        return rows.filter { $0.name.localizedStandardContains(words) || $0.preview.localizedStandardContains(words) }
    }

    /// Both lists at once; the rows are worked out (decrypted) off the main thread.
    private let pinStore: any PinStore
    /// Where the server's answers are kept on the phone (ResponseCache); nil keeps nothing.
    let cacheRoot: URL?
    /// The list is showing what was kept, until the server answers.
    private(set) var fromCache = false

    init(pinStore: any PinStore = KeychainPinStore(), cacheRoot: URL? = ResponseCache.root) {
        self.pinStore = pinStore
        self.cacheRoot = cacheRoot
    }

    func cache(for account: Account) -> ResponseCache? {
        cacheRoot.map { ResponseCache(account: account.user.id, root: $0) }
    }

    @ObservationIgnored private var reloading: Task<Void, Never>?

    /// Many changes at once (a burst of messages) make one reload, a moment later.
    func reloadSoon(_ account: Account, transport: any Transport = NetworkTransport()) {
        reloading?.cancel()
        reloading = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            try? await load(account, transport: transport)
        }
    }

    func load(_ account: Account, transport: any Transport = NetworkTransport()) async throws {
        let cache = cache(for: account)
        // What was kept, shown at once while the server answers (still encrypted on disk; opened here).
        if !loaded, let cache, let fd = cache.read("friends"), let gd = cache.read("groups"),
           let f = try? Server.decoder.decode([Friend].self, from: fd), let g = try? Server.decoder.decode([GroupSummary].self, from: gd) {
            try? await show(f, g, account: account)
            fromCache = true
        }
        do {
            let server = try Server(account.server, transport: transport)
            let tz = URLQueryItem(name: "tz", value: String(TimeZone.current.secondsFromGMT() / 60))
            async let friends = server.send("friends", token: account.token, query: [tz])
            async let groups = server.send("groups", token: account.token)
            async let requests = server.send("friends/requests", token: account.token)
            async let announced = server.send("announcement", token: account.token)
            let (fd, gd) = try await (friends, groups)
            let f = try Server.decoder.decode([Friend].self, from: fd), g = try Server.decoder.decode([GroupSummary].self, from: gd)
            cache?.write(fd, "friends")
            cache?.write(gd, "groups")
            incoming = (try? Server.decoder.decode(FriendsModel.Requests.self, from: await requests).incoming.count) ?? incoming
            struct Announced: Decodable { let announcement: Announcement? }
            if let a = try? Server.decoder.decode(Announced.self, from: await announced) { announce(a.announcement) }
            try await show(f, g, account: account)
            fromCache = false
            problem = nil
        } catch {
            Reporter.shared.report(.warn, "loading chats failed", Reporter.fields(error))
            problem = error.localizedDescription
            throw error
        }
    }

    /// The list from friends and groups (the server's answer, or what was kept).
    private func show(_ f: [Friend], _ g: [GroupSummary], account: Account) async throws {
        do {
            let identity = try account.identity()
            let pinBook = self.pinBook ?? PinBook(account: account.user.id, store: pinStore)
            self.pinBook = pinBook
            pinBook.see(friends: f)
            pinBook.see(senders: g.compactMap { m in m.lastMessage.flatMap { m in m.senderPublicKey.map { (m.senderId, $0) } } })
            let reader = Reader(me: account.user, identity: identity, friends: Dictionary(uniqueKeysWithValues: f.map { ($0.id, $0) }),
                                pins: pinBook.pins, changed: pinBook.changed, myPublicKey: account.publicKey)
            rows = await Task.detached(priority: .userInitiated) { reader.rows(friends: f, groups: g) }.value
            self.reader = reader
            self.groups = Dictionary(uniqueKeysWithValues: g.map { ($0.id, $0) })
            loaded = true
        }
    }
}
