import CryptoKit
import Foundation

// Formats 4 to 7: videos and photos in a media envelope.
//   header length (2 bytes, big-endian) || header (UTF-8 JSON) || the bytes
// The header says what the bytes are and carries the caption, and where on the
// picture it sits (`y`, a fraction of the height from the top; plan X33):
//   {"type": "video/mp4", "c": "the caption", "y": 0.62}
// Readers ignore header keys they don't know (`y` came after format 4). Formats
// 4 (video) and 6 (photo) seal the envelope with the pair key; 5 and 7 are the
// group scheme with the kind "video" or "image".

extension E2E {
    static let maxMediaHeaderBytes = 8192

    public struct Media: Equatable, Sendable {
        public let type: String
        public let caption: String
        /// Where the caption sits, 0 (top) to 1 (bottom); nil for the default place.
        public let y: Double?
        public let media: Data
    }

    public enum MediaKind: String, Sendable {
        case video, image
    }

    static func videoAAD(_ sender: Int64, _ recipient: Int64) -> String { "napsack/v4/snap/\(sender)/\(recipient)" }
    static func imageAAD(_ sender: Int64, _ recipient: Int64) -> String { "napsack/v6/snap/\(sender)/\(recipient)" }

    /// What a sender may say the bytes are: a video type and its parameters, or
    /// a JPEG (photos are always made JPEG before sending), nothing else.
    static func mediaTypeOK(_ type: Any?, _ kind: MediaKind) -> Bool {
        guard let type = type as? String, type.utf16.count <= 100 else { return false }
        switch kind {
        case .image: return type == "image/jpeg"  // exactly, as crypto.js checks it
        case .video: return (try? /video\/[a-z0-9.+\-]+(;[a-z0-9 =.,+"\-]*)?/.ignoresCase().wholeMatch(in: type)) != nil
        }
    }

    /// The plaintext of a video or photo: exactly these bytes are encrypted.
    public static func packMedia(_ media: Data, type: String, caption: String = "", y: Double? = nil) throws -> Data {
        let kind: MediaKind = type.hasPrefix("image/") ? .image : .video
        guard mediaTypeOK(type, kind) else { throw Failure.notSendable(kind == .image ? "photo" : "video") }
        guard caption.utf8.count <= maxCaptionBytes else { throw Failure.captionTooLong }
        var fields: [(String, JSJSON.Value)] = [("type", .string(type)), ("c", .string(caption))]
        if let y, y.isFinite {
            fields.append(("y", .double((min(1, max(0, y)) * 1000).rounded(.toNearestOrAwayFromZero) / 1000)))
        }
        let header = Data(JSJSON.object(fields).utf8)
        guard header.count <= maxMediaHeaderBytes else { throw Failure.captionTooLong }
        return lengthPrefixed(header, media)
    }

    /// Throws unless it's a well-formed envelope of the kind expected: a photo can't pass as a video.
    public static func unpackMedia(_ body: Data, kind: MediaKind) throws -> Media {
        guard let (headerBytes, media) = splitLengthPrefixed(body, max: maxMediaHeaderBytes),
              let header = try? JSJSON.parse(utf8(headerBytes)) as? [String: Any],
              mediaTypeOK(header["type"], kind), let type = header["type"] as? String
        else { throw Failure.malformed(kind.rawValue) }
        let y = JSJSON.number(header["y"]).flatMap { (0...1).contains($0) ? $0 : nil }
        return Media(type: type, caption: header["c"] as? String ?? "", y: y, media: media)
    }

    // Format 4, a video in a direct chat.
    public static func encryptVideo(_ key: SymmetricKey, _ media: Data, type: String, caption: String, sender: Int64, recipient: Int64, y: Double? = nil) throws -> Data {
        try seal(key, packMedia(media, type: type, caption: caption, y: y), aad: videoAAD(sender, recipient))
    }

    public static func decryptVideo(_ key: SymmetricKey, _ bytes: Data, sender: Int64, recipient: Int64) throws -> Media {
        try unpackMedia(open(key, bytes, aad: videoAAD(sender, recipient)), kind: .video)
    }

    // Format 5, a group video.
    public static func encryptGroupVideo(_ media: Data, type: String, caption: String, y: Double? = nil, groupId: Int64, senderId: Int64, wrapKeys: [Int64: SymmetricKey]) throws -> GroupMessage {
        try encryptGroup(packMedia(media, type: type, caption: caption, y: y), groupId: groupId, senderId: senderId, kind: "video", wrapKeys: wrapKeys)
    }

    public static func decryptGroupVideo(_ content: Data, wrap: String, _ o: GroupOpening) throws -> Media {
        try unpackMedia(decryptGroup(content, wrap: wrap, o, kind: "video"), kind: .video)
    }

    // Format 6, a photo (JPEG) in a direct chat, with its caption and where it sits.
    public static func encryptImage(_ key: SymmetricKey, _ jpeg: Data, caption: String, sender: Int64, recipient: Int64, y: Double? = nil) throws -> Data {
        try seal(key, packMedia(jpeg, type: "image/jpeg", caption: caption, y: y), aad: imageAAD(sender, recipient))
    }

    public static func decryptImage(_ key: SymmetricKey, _ bytes: Data, sender: Int64, recipient: Int64) throws -> Media {
        try unpackMedia(open(key, bytes, aad: imageAAD(sender, recipient)), kind: .image)
    }

    // Format 7, a group photo.
    public static func encryptGroupImage(_ jpeg: Data, caption: String, y: Double? = nil, groupId: Int64, senderId: Int64, wrapKeys: [Int64: SymmetricKey]) throws -> GroupMessage {
        try encryptGroup(packMedia(jpeg, type: "image/jpeg", caption: caption, y: y), groupId: groupId, senderId: senderId, kind: "image", wrapKeys: wrapKeys)
    }

    public static func decryptGroupImage(_ content: Data, wrap: String, _ o: GroupOpening) throws -> Media {
        try unpackMedia(decryptGroup(content, wrap: wrap, o, kind: "image"), kind: .image)
    }
}
