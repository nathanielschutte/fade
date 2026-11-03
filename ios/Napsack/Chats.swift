import CryptoKit
import Foundation
import NapsackCrypto
import Synchronization

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
    // The newest message, the counts, and your marks change live (ChatList), between reloads.
    var lastMessage: DirectMessage?
    var unread: Int
    var favorite: Bool
    var hidden: Bool
    var muted: Bool
    /// When a mute "for 8 hours" or "a week" ends (nil: until turned back on).
    let mutedUntil: Int64?
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
    var lastMessage: GroupMessage?
    var unread: Int
    var favorite: Bool
    var muted: Bool
    let mutedUntil: Int64?
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
    /// Tapping the row shows the pics and videos waiting from them right there,
    /// instead of opening the chat (Nate, 2026-11-02; `Reader.opensPics`).
    var opensPics = false
    /// A friend's username, which search finds them by too.
    var username: String? = nil
    /// The newest message's id.
    var newestId: Int64? = nil

    var id: Kind { kind }
    var isGroup: Bool { if case .group = kind { true } else { false } }
}

/// What readers have worked out already, kept between reloads (one per
/// signed-in list, shared by its open chats): chat keys, which take an ECDH
/// and an HKDF each, and each row's newest message, opened. Only in memory,
/// gone with the session.
final class ReaderMemo: Sendable {
    private struct State {
        var keys: [String: SymmetricKey] = [:]
        /// By message: what it was opened from (its sealed bytes), and what it says.
        var previews: [String: (sealed: String, text: String)] = [:]
    }
    private let state = Mutex(State())

    /// A key worked out once (`id` names who it's with, and their public key).
    func key(_ id: String, make: () throws -> SymmetricKey) rethrows -> SymmetricKey {
        if let kept = state.withLock({ $0.keys[id] }) { return kept }
        let key = try make()  // outside the lock: two at once may both work it out, which is harmless
        state.withLock { $0.keys[id] = key }
        return key
    }

    /// A newest message's words, opened once while its sealed bytes stay the same.
    /// What can't be opened isn't kept: a key accepted later may open it.
    func preview(_ id: String, sealed: String, open: () -> String?) -> String? {
        if let kept = state.withLock({ $0.previews[id] }), kept.sealed == sealed { return kept.text }
        guard let text = open() else { return nil }
        state.withLock { $0.previews[id] = (sealed, text) }
        return text
    }

    /// Only the rows' newest messages stay (one per chat).
    func keepPreviews(_ ids: Set<String>) {
        state.withLock { s in s.previews = s.previews.filter { ids.contains($0.key) } }
    }

    var keptPreviews: Int { state.withLock { $0.previews.count } }
}

/// What the rows need to know about the person reading them, and how to open
/// what they've been sent.
struct Reader: Sendable {
    let me: Me
    let identity: P256.KeyAgreement.PrivateKey
    /// Friends by id, for their names and keys.
    var friends: [Int64: Friend]
    /// Whose keys to trust (Pins.swift): messages are read with these, not
    /// whatever key the server hands out now.
    var pins = Pins()
    /// Friends whose key changed and hasn't been accepted.
    var changed: Set<Int64> = []
    /// Mine, for opening what I sent to a group.
    var myPublicKey = ""
    /// Keys and previews already worked out (ChatList keeps one for the session).
    var memo = ReaderMemo()

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

    /// The formats of pics and videos this app opens: direct (formats 1, 2, 4, 6) and in groups (3, 5, 7).
    static let directPicFormats: Set<Int> = [1, 2, E2E.videoFormat, E2E.imageFormat]
    static let groupPicFormats: Set<Int> = [E2E.groupFormat, E2E.groupVideoFormat, E2E.groupImageFormat]

    func row(_ friend: Friend) -> ChatRow {
        let (preview, waiting) = status(friend)
        var row = ChatRow(kind: .friend(friend.id), name: friend.name, preview: preview, waiting: waiting,
                       time: friend.lastMessage.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) },
                       favorite: friend.favorite, muted: friend.muted, hidden: friend.hidden, avatarId: friend.avatarId)
        row.marks = Self.marks(friend)
        row.opensPics = opensPics(friend, waiting: waiting)
        row.username = friend.username
        row.newestId = friend.lastMessage?.id
        return row
    }

    /// Tapping a chat whose newest message is a pic or video from them, waiting
    /// (and one this app can open), shows it straight from the list, with the
    /// others waiting there (Nate, 2026-11-02). Anything else opens the chat.
    func opensPics(_ friend: Friend, waiting: ChatRow.Waiting?) -> Bool {
        guard waiting == .snap, let m = friend.lastMessage else { return false }
        return m.kind == "snap" && m.senderId == friend.id && Self.directPicFormats.contains(m.format)
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
            // A text from before it can still be unread (the server's count): its
            // pics viewed from the list, say, or a pic sent from the camera.
            return (label[m.snapState ?? ""] ?? Word, friend.unread > 0 ? .text : nil)
        }
        let text = self.text(m, with: friend) ?? "Encrypted message"
        if !mine && m.readAt == nil { return (text, .text) }
        return (mine ? "You: \(text)" : text, nil)
    }

    /// A direct text, decrypted (its newest edit if it has one), or nil if it
    /// can't be. Kept (`memo`), so a reload doesn't open every row again.
    func text(_ m: DirectMessage, with friend: Friend) -> String? {
        memo.preview("d\(m.id)", sealed: "\(m.format)|\(m.ciphertext ?? "")|\(m.editCiphertext ?? "")") {
            body(m, with: friend)?.text.text
        }
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
    /// Each is worked out once per key (`memo`), not for every message.
    func readingKeys(_ friend: Friend) -> [SymmetricKey] {
        pins.readingKeys(friend.id, server: friend.publicKey).compactMap { key in
            try? memo.key("p\(friend.id):\(key)") { try E2E.pairKey(mine: identity, theirs: key, myId: me.id, theirId: friend.id) }
        }
    }

    /// The key that wraps group messages between me and someone, worked out once per key.
    func wrapKey(_ id: Int64, _ key: String) throws -> SymmetricKey {
        try memo.key("g\(id):\(key)") { try E2E.groupWrapKey(mine: identity, theirs: key, myId: me.id, theirId: id) }
    }

    // ---------- groups ----------

    func row(_ group: GroupSummary) -> ChatRow {
        let (preview, waiting) = status(group)
        var row = ChatRow(kind: .group(group.id), name: group.name, preview: preview, waiting: waiting,
                          time: group.lastMessage.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) },
                          favorite: group.favorite, muted: group.muted, hidden: false, avatarId: group.avatarId)
        row.opensPics = opensPics(group)
        row.newestId = group.lastMessage?.id
        return row
    }

    /// As for a friend: the newest message a group pic or video from someone else, not yet seen by me.
    func opensPics(_ group: GroupSummary) -> Bool {
        guard let m = group.lastMessage, let pic = m.pic, m.senderId != me.id else { return false }
        return pic.discardReason == nil && !pic.viewers.contains(me.id) && m.key != nil && Self.groupPicFormats.contains(m.format)
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

    /// A group text: format 0 as it is, format 3 opened with my wrap (and its newest edit), kept (`memo`).
    func groupText(_ m: GroupMessage) -> String? {
        if m.format == 0 { return m.body }
        let sealed = [String(m.format), m.content ?? "", m.key ?? "", m.clientId ?? "", m.editContent ?? "", m.editKey ?? "", m.editClientId ?? ""]
        return memo.preview("g\(m.id)", sealed: sealed.joined(separator: "|")) { groupBody(m)?.text.text }
    }

    func groupBody(_ m: GroupMessage) -> (text: E2E.Text, edited: Bool)? {
        if m.format == 0 { return (E2E.Text(text: m.body, replyTo: m.replyTo), false) }
        guard m.format == E2E.groupFormat, let content = m.content, let wrap = m.key, let bytes = try? E2E.fromB64(content)
        else { return nil }
        for senderKey in senderKeys(m.senderId, server: m.senderPublicKey) {
            guard let wrapKey = try? wrapKey(m.senderId, senderKey) else { continue }
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
        let rows = (friends.map(row) + groups.map(row)).sorted {
            let a = $0.time ?? .distantPast, b = $1.time ?? .distantPast
            return a != b ? a > b : $0.name.localizedCompare($1.name) == .orderedAscending
        }
        // The previews kept are those rows' newest messages, and no others.
        memo.keepPreviews(Set(friends.compactMap { $0.lastMessage.map { "d\($0.id)" } } + groups.compactMap { $0.lastMessage.map { "g\($0.id)" } }))
        return rows
    }

    /// After a group's waiting pics were shown from the list (`ChatRow.opensPics`):
    /// the group counts as read only if they were all that was unread, its
    /// newest `unread` messages from others. Otherwise a text nobody saw would
    /// show as seen ("Seen by"), so it stays unread.
    static func readAfterShowing(_ shown: Set<Int64>, unread: Int, in bubbles: [Bubble]) -> Bool {
        guard unread > 0 else { return false }
        let theirs = bubbles.filter { b in
            if b.mine { return false }
            if case .event = b.content { return false }
            return true
        }
        guard theirs.count >= unread else { return false }
        return theirs.suffix(unread).allSatisfy { shown.contains($0.id) }
    }
}

/// The signed-in person's chat list, loaded from the server and kept current
/// by the live connection: a new message changes its own row (no reload);
/// what only the server knows (friends, groups, requests, reads on another
/// device) reloads just the list it's in, and a reconnect reloads everything.
/// Answers are decoded and rows worked out (decrypted) off the main thread,
/// and merged into what's shown: a message that came live is never replaced
/// by an answer older than it.
@MainActor @Observable final class ChatList {
    private(set) var rows: [ChatRow] = []
    /// The rows in their places (favorites, the rest, hidden ones), worked out once per change.
    private(set) var favorites: [ChatRow] = []
    private(set) var others: [ChatRow] = []
    /// Chats you hid (archived): out of the list until you open "Hidden chats", or a new message shows them again.
    private(set) var hiddenRows: [ChatRow] = []
    /// Chats with something unread or unopened, muted and hidden ones not counted: the tab's badge.
    private(set) var waitingCount = 0
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

    /// What the server sent last (and what's changed live since), from which the rows are made.
    @ObservationIgnored private var friendList: [Friend] = []
    @ObservationIgnored private var groupList: [GroupSummary] = []
    @ObservationIgnored private let memo = ReaderMemo()
    @ObservationIgnored private var identity: P256.KeyAgreement.PrivateKey?

    // ---------- the list's own actions (app.js, the row actions) ----------

    private struct On: Encodable { let on: Bool; var hours: Int? = nil }

    private func path(_ kind: ChatRow.Kind, _ what: String) -> String {
        switch kind {
        case .friend(let id): "chats/\(id)/\(what)"
        case .group(let id): "groups/\(id)/\(what)"
        }
    }

    // Each changes its row as soon as the server says yes; the server's
    // friends_changed or groups_changed then reloads that list (the truth).

    /// Kept at the top (up to 10, direct and groups together: the server says so past that).
    func setFavorite(_ row: ChatRow, _ on: Bool, account: Account, transport: any Transport = NetworkTransport()) async throws {
        _ = try await Server(account.server, transport: transport).send(path(row.kind, "favorite"), method: "PUT", token: account.token, json: On(on: on))
        change(row.kind, friend: { $0.favorite = on }, group: { $0.favorite = on })
        await settled()
    }

    /// No notifications and no unread dot: for `hours`, or until turned back on (nil).
    func setMuted(_ row: ChatRow, _ on: Bool, hours: Int? = nil, account: Account, transport: any Transport = NetworkTransport()) async throws {
        _ = try await Server(account.server, transport: transport).send(path(row.kind, "mute"), method: "PUT", token: account.token,
                                                                         json: On(on: on, hours: on ? hours : nil))
        change(row.kind, friend: { $0.muted = on }, group: { $0.muted = on })
        await settled()
    }

    /// Out of the list, or back. Only direct chats; you leave a group instead.
    func setHidden(_ row: ChatRow, _ on: Bool, account: Account, transport: any Transport = NetworkTransport()) async throws {
        guard case .friend = row.kind else { return }
        _ = try await Server(account.server, transport: transport).send(path(row.kind, "hidden"), method: "PUT", token: account.token, json: On(on: on))
        change(row.kind, friend: { $0.hidden = on }, group: { _ in })
        await settled()
    }

    /// Leaves a group: the membership is marked ended, nothing is deleted.
    func leave(_ row: ChatRow, account: Account, transport: any Transport = NetworkTransport()) async throws {
        guard case .group(let id) = row.kind else { return }
        _ = try await Server(account.server, transport: transport).send("groups/\(id)/members/\(account.user.id)", method: "DELETE", token: account.token)
        groupList.removeAll { $0.id == id }
        groups[id] = nil
        touched(row.kind)
        left[id] = changes  // an answer asked for before this doesn't bring it back
        await settled()
    }

    /// Rows whose name, username, or newest message (as shown, already opened
    /// here) has the words: at once, as you type. Messages further back are
    /// MessageFinder's (Search.swift).
    func search(_ text: String) -> [ChatRow] {
        let words = text.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return [] }
        return rows.filter {
            $0.name.localizedStandardContains(words) || $0.username?.localizedStandardContains(words) == true
                || $0.preview.localizedStandardContains(words)
        }
    }

    // ---------- live changes, without asking the server ----------

    /// What the live connection says, as far as the list goes (the open chat
    /// takes its own, ChatListScreen). A message changes its own row; what only
    /// the server knows reloads just the list it's in; a reconnect reloads all.
    /// Reads don't: the list doesn't show "Seen", and a group's every message
    /// can bring a read from each member.
    func heard(_ event: LiveEvent, account: Account, transport: any Transport = NetworkTransport()) {
        switch event {
        case .ready:
            reloadSoon(account, .all, transport: transport)  // anything could have happened while disconnected
        case .message(let m):
            // A chat new to the list; or a pic, sent or opened: the streak and the
            // unread count are the server's to work out (pics are few, so it's cheap).
            if !arrived(m) || m.kind == "snap" { reloadSoon(account, .friends, transport: transport) }
        case .groupMessage(let m):
            if !arrived(m) { reloadSoon(account, .groups, transport: transport) }
        case .read(let by, _):
            // I read a chat on another device (it doesn't say which); a friend's reads don't show here.
            if by == account.user.id { reloadSoon(account, .friends, transport: transport) }
        case .friendsChanged:
            reloadSoon(account, [.friends, .requests], transport: transport)
        case .groupsChanged:
            reloadSoon(account, .groups, transport: transport)
        case .announcement(let a):
            announce(a)
        case .groupRead, .typing, .presence, .authFailed, .pong, .other:
            break
        }
    }

    /// A direct message from the socket, new or changed: its row changes here.
    /// False when it's with someone not in the list yet (the caller reloads).
    @discardableResult func arrived(_ m: DirectMessage) -> Bool {
        guard let me = reader?.me.id else { return false }
        let friendId = m.senderId == me ? m.recipientId : m.senderId
        guard let i = friendList.firstIndex(where: { $0.id == friendId }) else { return false }
        var friend = friendList[i]
        let newest = friend.lastMessage?.id ?? 0
        guard m.id >= newest else { return true }  // an older one changed: the row doesn't show it
        if m.id > newest {
            if m.senderId == friendId && (m.kind == "text" ? m.readAt == nil : m.snapState == "pending") { friend.unread += 1 }
            friend.hidden = false  // a new message brings a hidden chat back (marks.rs)
        } else if m.senderId == friendId, friend.lastMessage?.snapState == "pending", m.snapState != "pending" {
            friend.unread = max(0, friend.unread - 1)  // their newest pic, opened: the reload this brings confirms it
        }
        friend.lastMessage = m
        guard friend != friendList[i] else { return true }
        friendList[i] = friend
        reader?.friends[friendId] = friend
        touched(.friend(friendId))
        return true
    }

    /// A group message from the socket, new or changed (a reaction, someone
    /// seeing a pic): its row changes here. False for a group not in the list yet.
    @discardableResult func arrived(_ m: GroupMessage) -> Bool {
        guard let me = reader?.me.id, let i = groupList.firstIndex(where: { $0.id == m.groupId }) else { return false }
        var group = groupList[i]
        let newest = group.lastMessage?.id ?? 0
        guard m.id >= newest else { return true }
        if m.id > newest && m.senderId != me && m.kind == "text" { group.unread += 1 }
        group.lastMessage = m
        guard group != groupList[i] else { return true }
        groupList[i] = group
        groups[group.id] = group
        if let pinBook, let key = m.senderPublicKey {
            pinBook.see(senders: [(m.senderId, key)])  // first sight pins it, as a reload would
            reader?.pins = pinBook.pins
        }
        touched(.group(group.id))
        return true
    }

    /// A key was accepted in a chat (or a group sender pinned there): the
    /// rows and what opening a chat needs take the shared pins at once, so
    /// "Safety code changed" goes, and the camera can send to them again,
    /// without waiting for a reload.
    func pinsChanged() {
        guard let pinBook, var reader, reader.pins != pinBook.pins || reader.changed != pinBook.changed else { return }
        reader.pins = pinBook.pins
        reader.changed = pinBook.changed
        self.reader = reader
        recompute()
    }

    private func change(_ kind: ChatRow.Kind, friend change: (inout Friend) -> Void, group changeGroup: (inout GroupSummary) -> Void) {
        switch kind {
        case .friend(let id):
            guard let i = friendList.firstIndex(where: { $0.id == id }) else { return }
            var friend = friendList[i]
            change(&friend)
            guard friend != friendList[i] else { return }
            friendList[i] = friend
            reader?.friends[id] = friend
        case .group(let id):
            guard let i = groupList.firstIndex(where: { $0.id == id }) else { return }
            var group = groupList[i]
            changeGroup(&group)
            guard group != groupList[i] else { return }
            groupList[i] = group
            groups[id] = group
        }
        touched(kind)
    }

    /// Counts changes made here, so an answer asked for before one doesn't undo it.
    @ObservationIgnored private var changes = 0
    @ObservationIgnored private var changedAt: [ChatRow.Kind: Int] = [:]
    /// Groups left here, and when (in `changes`).
    @ObservationIgnored private var left: [Int64: Int] = [:]

    private func touched(_ kind: ChatRow.Kind) {
        changes += 1
        changedAt[kind] = changes
        recompute()
    }

    // ---------- loading ----------

    /// What a load asks the server for.
    struct Parts: OptionSet, Sendable {
        let rawValue: Int
        static let friends = Parts(rawValue: 1 << 0)
        static let groups = Parts(rawValue: 1 << 1)
        /// Friend requests waiting on you, for the badge on Friends.
        static let requests = Parts(rawValue: 1 << 2)
        static let announcement = Parts(rawValue: 1 << 3)
        static let all: Parts = [.friends, .groups, .requests, .announcement]
    }

    /// Where pins are kept; by default the Keychain, per server and account (KeychainPinStore).
    private let pinStore: (any PinStore)?
    /// Where the server's answers are kept on the phone (ResponseCache); nil keeps nothing.
    let cacheRoot: URL?
    /// The list is showing what was kept, until the server answers.
    private(set) var fromCache = false

    init(pinStore: (any PinStore)? = nil, cacheRoot: URL? = ResponseCache.root) {
        self.pinStore = pinStore
        self.cacheRoot = cacheRoot
    }

    func cache(for account: Account) -> ResponseCache? {
        cacheRoot.map { ResponseCache(account: account.user.id, root: $0) }
    }

    @ObservationIgnored private var reloading: Task<Void, Never>?
    @ObservationIgnored private var lastReload: Task<Void, Never>?
    @ObservationIgnored private var waitingParts: Parts = []

    /// Many changes at once (a burst of events) make one reload a moment
    /// later, of only the lists they touched.
    func reloadSoon(_ account: Account, _ parts: Parts = .all, transport: any Transport = NetworkTransport()) {
        waitingParts.formUnion(parts)
        guard reloading == nil else { return }  // the one waiting takes these too
        let task = Task {
            try? await Task.sleep(for: .milliseconds(150))
            let parts = waitingParts
            waitingParts = []
            reloading = nil  // what comes from here on makes the next one
            try? await load(account, parts, transport: transport)
        }
        reloading = task
        lastReload = task
    }

    /// Waits for the reloads asked for so far, and the rows they make (tests).
    func quiet() async {
        while let task = lastReload {
            await task.value
            if lastReload == task { break }
        }
        await settled()
    }

    /// Each list's answers are taken in the order they were asked for: a slow one never undoes a newer one.
    @ObservationIgnored private var asked = 0
    @ObservationIgnored private var taken: [Int: Int] = [:]

    /// Asks the server for `parts` (everything, by default) and shows the answers.
    func load(_ account: Account, _ parts: Parts = .all, transport: any Transport = NetworkTransport()) async throws {
        let cache = cache(for: account)
        asked += 1
        let number = asked, since = changes
        do {
            let server = try Server(account.server, transport: transport)
            let tz = URLQueryItem(name: "tz", value: String(TimeZone.current.secondsFromGMT() / 60))
            async let friends = Self.fetch(server, "friends", account, [tz], if: parts.contains(.friends))
            async let groups = Self.fetch(server, "groups", account, if: parts.contains(.groups))
            async let requests = Self.fetch(server, "friends/requests", account, if: parts.contains(.requests))
            async let announced = Self.fetch(server, "announcement", account, if: parts.contains(.announcement))
            // What was kept, shown at once while the server answers (still encrypted on disk; opened here).
            if !loaded, let cache {
                async let fd = cache.load("friends"), gd = cache.load("groups")
                if let fd = await fd, let gd = await gd, let kept = try? await Self.decode(friends: fd, groups: gd) {
                    take(kept, number: 0, since: since)
                    try? await show(account)
                    fromCache = true
                }
            }
            let (fd, gd) = try await (friends, groups)
            // The badge and the banner are extras: the list shows without them.
            let answers = try await Self.decode(friends: fd, groups: gd, requests: try? await requests, announced: try? await announced)
            if let fd { cache?.write(fd, "friends") }  // as sent: still encrypted
            if let gd { cache?.write(gd, "groups") }
            if let n = answers.incoming { incoming = n }
            if answers.announced { announce(answers.announcement) }
            take(answers, number: number, since: since)
            try await show(account)
            reloadWhenAMuteEnds(account, transport: transport)
            if parts.isSuperset(of: [.friends, .groups]) { fromCache = false }
            problem = nil
        } catch {
            Reporter.shared.report(.warn, "loading chats failed", Reporter.fields(error))
            problem = error.localizedDescription
            throw error
        }
    }

    @ObservationIgnored private var unmuting: Task<Void, Never>?
    /// When the next mute ends, if one does (the reload then is waiting for it).
    @ObservationIgnored private(set) var nextMuteEnd: Int64?

    /// A mute for 8 hours or a week ends on the server's clock, and nothing
    /// says so: the list reloads then, so the bell goes and the chat counts again.
    private func reloadWhenAMuteEnds(_ account: Account, transport: any Transport) {
        let now = Int64(Date().timeIntervalSince1970)
        let next = (friendList.compactMap(\.mutedUntil) + groupList.compactMap(\.mutedUntil)).filter { $0 > now }.min()
        guard next != nextMuteEnd else { return }
        nextMuteEnd = next
        unmuting?.cancel()
        unmuting = next.map { end in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(end - now + 1))
                guard !Task.isCancelled, let self else { return }
                nextMuteEnd = nil
                reloadSoon(account, [.friends, .groups], transport: transport)
            }
        }
    }

    private struct Answers: Sendable {
        var friends: [Friend]?
        var groups: [GroupSummary]?
        var incoming: Int?
        var announced = false
        var announcement: Announcement?
    }

    nonisolated private static func fetch(_ server: Server, _ path: String, _ account: Account, _ query: [URLQueryItem] = [],
                                          if wanted: Bool) async throws -> Data? {
        guard wanted else { return nil }
        return try await server.send(path, token: account.token, query: query)
    }

    /// Off the main thread: a list of every friend, each with a message, is enough to notice.
    nonisolated private static func decode(friends: Data?, groups: Data?, requests: Data? = nil, announced: Data? = nil) async throws -> Answers {
        struct Requests: Decodable {
            struct One: Decodable {}
            let incoming: [One]
        }
        struct Announced: Decodable { let announcement: Announcement? }
        var answers = Answers()
        answers.friends = try friends.map { try Server.decoder.decode([Friend].self, from: $0) }
        answers.groups = try groups.map { try Server.decoder.decode([GroupSummary].self, from: $0) }
        answers.incoming = requests.flatMap { try? Server.decoder.decode(Requests.self, from: $0).incoming.count }
        if let announced, let a = try? Server.decoder.decode(Announced.self, from: announced) {
            answers.announced = true
            answers.announcement = a.announcement
        }
        return answers
    }

    /// Takes the server's lists, keeping what changed here after they were
    /// asked for (`since`) unless the answer has a newer message for that chat.
    private func take(_ answers: Answers, number: Int, since: Int) {
        if let fresh = answers.friends, number >= (taken[Parts.friends.rawValue] ?? 0) {
            taken[Parts.friends.rawValue] = number
            let shown = Dictionary(friendList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            friendList = fresh.map { f in
                guard let mine = shown[f.id], (changedAt[.friend(f.id)] ?? 0) > since,
                      (f.lastMessage?.id ?? 0) <= (mine.lastMessage?.id ?? 0) else { return f }
                return mine
            }
        }
        if let fresh = answers.groups, number >= (taken[Parts.groups.rawValue] ?? 0) {
            taken[Parts.groups.rawValue] = number
            let shown = Dictionary(groupList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            groupList = fresh.filter { (left[$0.id] ?? 0) <= since }.map { g in
                guard let mine = shown[g.id], (changedAt[.group(g.id)] ?? 0) > since,
                      (g.lastMessage?.id ?? 0) <= (mine.lastMessage?.id ?? 0) else { return g }
                return mine
            }
        }
    }

    /// The rows from the lists as they are now, and what opening a chat needs.
    private func show(_ account: Account) async throws {
        let identity = try self.identity ?? account.identity()
        self.identity = identity
        let pinBook = self.pinBook ?? PinBook(account: account.user.id, store: pinStore ?? KeychainPinStore(server: account.server))
        self.pinBook = pinBook
        pinBook.see(friends: friendList)
        pinBook.see(senders: groupList.compactMap { m in m.lastMessage.flatMap { m in m.senderPublicKey.map { (m.senderId, $0) } } })
        reader = Reader(me: account.user, identity: identity, friends: Dictionary(friendList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                        pins: pinBook.pins, changed: pinBook.changed, myPublicKey: account.publicKey, memo: memo)
        groups = Dictionary(groupList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        await recompute()?.value
    }

    @ObservationIgnored private var computing: Task<Void, Never>?
    @ObservationIgnored private var computed = 0
    @ObservationIgnored private var placed = 0

    /// The rows again, worked out (and opened) off the main thread; the newest
    /// asked for wins. Under way as soon as this returns (`settled` waits for it).
    @discardableResult private func recompute() -> Task<Void, Never>? {
        guard let reader else { return nil }
        computed += 1
        let number = computed, friends = friendList, groups = groupList
        let task = Task {
            let rows = await Task.detached(priority: .userInitiated) { reader.rows(friends: friends, groups: groups) }.value
            guard number > placed else { return }  // a newer one is already on screen
            placed = number
            place(rows)
        }
        computing = task
        return task
    }

    /// Waits until the rows on screen are the newest worked out.
    func settled() async {
        while let task = computing {
            await task.value
            if computing == task { return }
        }
    }

    /// Only what changed is set, so an answer the same as what's shown redraws nothing.
    private func place(_ rows: [ChatRow]) {
        if rows != self.rows { self.rows = rows }
        let favorites = rows.filter { $0.favorite && !$0.hidden }, others = rows.filter { !$0.favorite && !$0.hidden }
        let hidden = rows.filter(\.hidden), waiting = Notifications.badge(rows)
        if favorites != self.favorites { self.favorites = favorites }
        if others != self.others { self.others = others }
        if hidden != hiddenRows { hiddenRows = hidden }
        if waiting != waitingCount { waitingCount = waiting }
        if !loaded { loaded = true }
    }
}
