import CryptoKit
import Foundation

// Format 3: group messages (docs/implementation/group-encryption.md).
// Each message is sealed once with a fresh key K, and K is wrapped for every
// member (the sender too, for their other devices) with the key that sender
// and member share: the pair key's ECDH secret under its own HKDF label. A
// wrap only the sender could have made proves who sent it; the wrap's
// associated data pins the group, sender, member, message id, a digest of the
// content, and the member list the sender used. Group texts, pics, edits,
// videos (5), and photos (7) all travel this way, told apart by `kind`.

extension E2E {
    static let groupKeyBytes = 32
    static let clientIdBytes = 16

    /// A sealed group message, as sent: the content once, a wrap per member.
    public struct GroupMessage: Sendable {
        public let clientId: String
        public let content: Data
        public let recipients: [Int64]
        public let wraps: [Int64: String]
    }

    /// What a member needs to open a group message, besides their wrap.
    public struct GroupOpening: Sendable {
        public var groupId: Int64
        public var senderId: Int64
        public var myId: Int64
        public var clientId: String
        public var recipients: [Int64]
        public var wrapKey: SymmetricKey

        public init(groupId: Int64, senderId: Int64, myId: Int64, clientId: String, recipients: [Int64], wrapKey: SymmetricKey) {
            self.groupId = groupId
            self.senderId = senderId
            self.myId = myId
            self.clientId = clientId
            self.recipients = recipients
            self.wrapKey = wrapKey
        }
    }

    /// Same on both sides, like pairKey, but only for wrapping group message keys.
    public static func groupWrapKey(mine: P256.KeyAgreement.PrivateKey, theirs b64: String, myId: Int64, theirId: Int64) throws -> SymmetricKey {
        let theirKey = try P256.KeyAgreement.PublicKey(derRepresentation: fromB64(b64))
        let shared = try mine.sharedSecretFromKeyAgreement(with: theirKey)
        let (lo, hi) = (min(myId, theirId), max(myId, theirId))
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("napsack/v1/pair/\(lo)/\(hi)".utf8),
            sharedInfo: Data("napsack/v3/group-keys".utf8),
            outputByteCount: 32)
    }

    static func groupAAD(_ group: Int64, _ sender: Int64, _ clientId: String, _ kind: String) -> String {
        "napsack/v3/group/\(group)/\(sender)/\(clientId)/\(kind)"
    }

    static func groupKeyAAD(_ group: Int64, _ sender: Int64, _ member: Int64, _ clientId: String, _ digest: String, _ roster: String) -> String {
        "napsack/v3/group-key/\(group)/\(sender)/\(member)/\(clientId)/\(digest)/\(roster)"
    }

    /// Commits to who a message was for: SHA-256 of the sorted member ids, comma-joined.
    public static func rosterHash(_ memberIds: [Int64]) -> String {
        sha256B64(Data(memberIds.sorted().map(String.init).joined(separator: ",").utf8))
    }

    /// Seals `body` for a group. `wrapKeys`: member id -> groupWrapKey with that
    /// member, for every current member including the sender.
    public static func encryptGroup(_ body: Data, groupId: Int64, senderId: Int64, kind: String, wrapKeys: [Int64: SymmetricKey]) throws -> GroupMessage {
        let recipients = wrapKeys.keys.sorted()
        guard recipients.contains(senderId) else { throw Failure.senderMustWrapForThemselves }
        let clientId = toB64(randomBytes(clientIdBytes))
        let raw = randomBytes(groupKeyBytes)
        let content = try seal(SymmetricKey(data: raw), body, aad: groupAAD(groupId, senderId, clientId, kind))
        let digest = sha256B64(content)
        let roster = rosterHash(recipients)
        var wraps: [Int64: String] = [:]
        for id in recipients {
            wraps[id] = toB64(try seal(wrapKeys[id]!, raw, aad: groupKeyAAD(groupId, senderId, id, clientId, digest, roster)))
        }
        return GroupMessage(clientId: clientId, content: content, recipients: recipients, wraps: wraps)
    }

    /// Opens a group message with my wrap. Throws if anything doesn't check out.
    public static func decryptGroup(_ content: Data, wrap b64: String, _ o: GroupOpening, kind: String) throws -> Data {
        guard o.recipients.contains(o.myId) else { throw Failure.notSentToMe }
        let digest = sha256B64(content)
        let roster = rosterHash(o.recipients)
        let raw = try open(o.wrapKey, fromB64(b64), aad: groupKeyAAD(o.groupId, o.senderId, o.myId, o.clientId, digest, roster))
        guard raw.count == groupKeyBytes else { throw Failure.malformed("key") }
        return try open(SymmetricKey(data: raw), content, aad: groupAAD(o.groupId, o.senderId, o.clientId, kind))
    }

    /// A group text: the format 2 envelope, so replies travel inside, out of the server's sight.
    public static func encryptGroupText(_ text: String, replyTo: Int64?, groupId: Int64, senderId: Int64, wrapKeys: [Int64: SymmetricKey]) throws -> GroupMessage {
        try encryptGroup(Data(packText(text, replyTo: replyTo).utf8), groupId: groupId, senderId: senderId, kind: "text", wrapKeys: wrapKeys)
    }

    public static func decryptGroupText(_ content: Data, wrap: String, _ o: GroupOpening) throws -> Text {
        try unpackText(utf8(decryptGroup(content, wrap: wrap, o, kind: "text")))
    }

    /// A group pic: the format 2 pic envelope (caption sealed in with the photo).
    public static func encryptGroupPic(_ photo: Data, caption: String, groupId: Int64, senderId: Int64, wrapKeys: [Int64: SymmetricKey]) throws -> GroupMessage {
        try encryptGroup(packPic(photo, caption: caption), groupId: groupId, senderId: senderId, kind: "pic", wrapKeys: wrapKeys)
    }

    public static func decryptGroupPic(_ content: Data, wrap: String, _ o: GroupOpening) throws -> Pic {
        try unpackPic(decryptGroup(content, wrap: wrap, o, kind: "pic"))
    }

    /// An edit to a group text, wrapped for the members the text went to.
    public static func encryptGroupEdit(_ text: String, message: Int64, groupId: Int64, senderId: Int64, wrapKeys: [Int64: SymmetricKey]) throws -> GroupMessage {
        try encryptGroup(Data(packText(text).utf8), groupId: groupId, senderId: senderId, kind: "edit/\(message)", wrapKeys: wrapKeys)
    }

    public static func decryptGroupEdit(_ content: Data, wrap: String, message: Int64, _ o: GroupOpening) throws -> String {
        try unpackText(utf8(decryptGroup(content, wrap: wrap, o, kind: "edit/\(message)"))).text
    }
}
