import CryptoKit
import Foundation

// Format 2: a pic with a caption.
// Plaintext: caption length (2 bytes, big-endian) || caption (UTF-8) || JPEG.
// Same pair key; the associated data says v2, so a format 2 pic can't be
// passed off as format 1 or the other way round.

extension E2E {
    /// Encoded caption limit (200 characters in the UI; emoji take up to 4 bytes each).
    public static let maxCaptionBytes = 1000

    public struct Pic: Equatable, Sendable {
        public let photo: Data
        public let caption: String
    }

    static func picAAD(_ sender: Int64, _ recipient: Int64) -> String { "napsack/v2/snap/\(sender)/\(recipient)" }

    public static func packPic(_ photo: Data, caption: String = "") throws -> Data {
        let c = Data(caption.utf8)
        guard c.count <= maxCaptionBytes else { throw Failure.captionTooLong }
        return lengthPrefixed(c, photo)
    }

    public static func unpackPic(_ body: Data) throws -> Pic {
        guard let (caption, photo) = splitLengthPrefixed(body, max: maxCaptionBytes) else { throw Failure.malformed("pic") }
        return Pic(photo: photo, caption: utf8(caption))
    }

    public static func encryptPic(_ key: SymmetricKey, photo: Data, caption: String, sender: Int64, recipient: Int64) throws -> Data {
        try seal(key, packPic(photo, caption: caption), aad: picAAD(sender, recipient))
    }

    /// Any pic format: format 1 pics have no caption.
    public static func decryptPic(_ key: SymmetricKey, _ bytes: Data, format: Int, sender: Int64, recipient: Int64) throws -> Pic {
        switch format {
        case 1: Pic(photo: try decryptSnap(key, bytes, sender: sender, recipient: recipient), caption: "")
        case 2: try unpackPic(open(key, bytes, aad: picAAD(sender, recipient)))
        default: throw Failure.unknownFormat(format)
        }
    }
}
