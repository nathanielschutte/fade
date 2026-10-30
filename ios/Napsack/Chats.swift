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
    /// The newest edit of a text, sealed like it.
    let editCiphertext: String?
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

    /// What the app calls them: your nickname, their display name, or their username.
    var name: String { nickname ?? displayName ?? username }
}

struct GroupMessage: Decodable, Sendable, Equatable {
    struct Pic: Decodable, Sendable, Equatable {
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

    var myName: String { me.displayName ?? me.username }

    /// Anyone by what I call them: me by my display name, friends by their name, others by username.
    func name(_ id: Int64, _ username: String) -> String {
        id == me.id ? myName : friends[id]?.name ?? username
    }

    // ---------- direct chats ----------

    func row(_ friend: Friend) -> ChatRow {
        let (preview, waiting) = status(friend)
        return ChatRow(kind: .friend(friend.id), name: friend.name, preview: preview, waiting: waiting,
                       time: friend.lastMessage.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) },
                       favorite: friend.favorite, muted: friend.muted, hidden: friend.hidden)
    }

    func status(_ friend: Friend) -> (String, ChatRow.Waiting?) {
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
        guard [1, 2].contains(m.format), let ciphertext = m.ciphertext,
              let key = try? E2E.pairKey(mine: identity, theirs: friend.publicKey, myId: me.id, theirId: friend.id),
              let body = try? E2E.decryptAnyText(key, ciphertext, format: m.format, sender: m.senderId, recipient: m.recipientId)
        else { return nil }
        if let edit = m.editCiphertext,
           let edited = try? E2E.decryptEdit(key, edit, sender: m.senderId, recipient: m.recipientId, message: m.id) {
            return edited
        }
        return body.text
    }

    // ---------- groups ----------

    func row(_ group: GroupSummary) -> ChatRow {
        let (preview, waiting) = status(group)
        return ChatRow(kind: .group(group.id), name: group.name, preview: preview, waiting: waiting,
                       time: group.lastMessage.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) },
                       favorite: group.favorite, muted: group.muted, hidden: false)
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
        if m.format == 0 { return m.body }
        guard m.format == E2E.groupFormat, let content = m.content, let wrap = m.key, let senderKey = m.senderPublicKey,
              let bytes = try? E2E.fromB64(content),
              let wrapKey = try? E2E.groupWrapKey(mine: identity, theirs: senderKey, myId: me.id, theirId: m.senderId)
        else { return nil }
        let opening = E2E.GroupOpening(groupId: m.groupId, senderId: m.senderId, myId: me.id,
                                       clientId: m.clientId ?? "", recipients: m.recipients ?? [], wrapKey: wrapKey)
        guard let body = try? E2E.decryptGroupText(bytes, wrap: wrap, opening) else { return nil }
        if let editContent = m.editContent, let editKey = m.editKey, let editBytes = try? E2E.fromB64(editContent) {
            var edit = opening
            edit.clientId = m.editClientId ?? ""
            if let edited = try? E2E.decryptGroupEdit(editBytes, wrap: editKey, message: m.id, edit) { return edited }
        }
        return body.text
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

    var favorites: [ChatRow] { rows.filter { $0.favorite && !$0.hidden } }
    var others: [ChatRow] { rows.filter { !$0.favorite && !$0.hidden } }

    /// Both lists at once; the rows are worked out (decrypted) off the main thread.
    func load(_ account: Account, transport: any Transport = NetworkTransport()) async throws {
        do {
            let server = try Server(account.server, transport: transport)
            async let friends = server.friends(token: account.token)
            async let groups = server.groups(token: account.token)
            let (f, g) = try await (friends, groups)
            let identity = try account.identity()
            let reader = Reader(me: account.user, identity: identity, friends: Dictionary(uniqueKeysWithValues: f.map { ($0.id, $0) }))
            rows = await Task.detached(priority: .userInitiated) { reader.rows(friends: f, groups: g) }.value
            problem = nil
            loaded = true
        } catch {
            problem = error.localizedDescription
            throw error
        }
    }
}
