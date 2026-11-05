import CryptoKit
import Foundation

// Format 2 texts: a small JSON envelope instead of the bare text,
//   {"t": "the text", "re": 123}   ("re", optional: the message it replies to)
// Readers ignore keys they don't know, so later additions don't need a new
// format. Reactions and edits are sealed with the pair key too, their
// associated data naming the message they're on, so the server can't move
// them to another message.

extension E2E {
    public struct Text: Equatable, Sendable {
        public let text: String
        public let replyTo: Int64?

        public init(text: String, replyTo: Int64? = nil) {
            self.text = text
            self.replyTo = replyTo
        }
    }

    /// The quick row of reactions every client offers; any other one emoji
    /// can be picked too (X49), and is held to `isReaction`.
    public static let reactions = ["\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F44D}", "\u{1F44E}"]

    /// A reaction: exactly one emoji, nothing else. The server's rule for
    /// group reactions (`text::is_one_emoji`, server/src/text.rs), scalar for
    /// scalar, and the one decrypted direct-chat reactions are held to (the
    /// server can't see those). One emoji can be several code points (a skin
    /// tone, a flag's pair, a keycap, people joined by U+200D), so this follows
    /// the shape of an emoji sequence rather than counting characters.
    public static func isReaction(_ s: String) -> Bool {
        // The longest real ones (a family, a subdivision flag) are under 30 bytes.
        guard !s.isEmpty, s.utf8.count <= 40 else { return false }
        var scalars = s.unicodeScalars.makeIterator()
        var peeked: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let p = peeked { peeked = nil; return p }
            return scalars.next()
        }
        func peek() -> Unicode.Scalar? {
            if peeked == nil { peeked = scalars.next() }
            return peeked
        }
        /// Takes the next one if it's in `range`.
        func take(_ range: ClosedRange<UInt32>) -> Bool {
            guard let p = peek(), range.contains(p.value) else { return false }
            peeked = nil
            return true
        }
        let regional: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF, tones: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
        let tags: ClosedRange<UInt32> = 0xE0020...0xE007E
        while true {
            guard let c = next() else { return false }
            switch c.value {
            case regional:
                // A flag is two regional indicators, and nothing joins to it.
                guard let second = next(), regional.contains(second.value) else { return false }
                return next() == nil
            case 0x30...0x39, 0x23, 0x2A:  // 0-9, #, *: a keycap
                _ = take(0xFE0F...0xFE0F)
                return next()?.value == 0x20E3 && next() == nil
            case _ where isPictographic(c.value):
                _ = take(0xFE0F...0xFE0F)
                _ = take(tones)
                if c.value == 0x1F3F4, let p = peek(), tags.contains(p.value) {  // a subdivision flag's tags
                    while take(tags) {}
                    guard next()?.value == 0xE007F else { return false }
                }
            default:
                return false
            }
            switch next()?.value {
            case nil: return true
            case 0x200D: continue
            default: return false
            }
        }
    }

    /// Code points that are emoji on their own: Unicode's Extended_Pictographic,
    /// by block, minus the regional indicators and skin tones (as text.rs).
    static func isPictographic(_ c: UInt32) -> Bool {
        switch c {
        case 0xA9, 0xAE, 0x203C, 0x2049, 0x2122, 0x2139,
             0x2194...0x2199, 0x21A9...0x21AA, 0x231A...0x231B,
             0x2328, 0x23CF, 0x23E9...0x23F3, 0x23F8...0x23FA,
             0x24C2, 0x25AA...0x25AB, 0x25B6, 0x25C0, 0x25FB...0x25FE,
             0x2600...0x27BF, 0x2934...0x2935, 0x2B05...0x2B07,
             0x2B1B...0x2B1C, 0x2B50, 0x2B55, 0x3030, 0x303D,
             0x3297, 0x3299,
             0x1F000...0x1F1E5, 0x1F200...0x1F3FA, 0x1F400...0x1FAFF:
            true
        default:
            false
        }
    }

    static func textAAD2(_ sender: Int64, _ recipient: Int64) -> String { "napsack/v2/text/\(sender)/\(recipient)" }
    static func reactionAAD(_ sender: Int64, _ recipient: Int64, _ message: Int64) -> String {
        "napsack/v2/reaction/\(sender)/\(recipient)/\(message)"
    }
    static func editAAD(_ sender: Int64, _ recipient: Int64, _ message: Int64) -> String {
        "napsack/v2/edit/\(sender)/\(recipient)/\(message)"
    }

    /// The plaintext of a format 2 text: exactly these bytes are encrypted.
    public static func packText(_ text: String, replyTo: Int64? = nil) -> String {
        var fields: [(String, JSJSON.Value)] = [("t", .string(text))]
        if let replyTo { fields.append(("re", .int(replyTo))) }
        return JSJSON.object(fields)
    }

    public static func unpackText(_ json: String) throws -> Text {
        guard let body = try? JSJSON.parse(json) as? [String: Any], let text = body["t"] as? String else {
            throw Failure.malformed("text")
        }
        return Text(text: text, replyTo: JSJSON.safeInteger(body["re"]))
    }

    public static func encryptText2(_ key: SymmetricKey, _ text: String, replyTo: Int64?, sender: Int64, recipient: Int64) throws -> String {
        toB64(try seal(key, Data(packText(text, replyTo: replyTo).utf8), aad: textAAD2(sender, recipient)))
    }

    /// Any text format: format 1 texts never reply.
    public static func decryptAnyText(_ key: SymmetricKey, _ b64: String, format: Int, sender: Int64, recipient: Int64) throws -> Text {
        switch format {
        case 1: Text(text: try decryptText(key, b64, sender: sender, recipient: recipient), replyTo: nil)
        case 2: try unpackText(utf8(open(key, fromB64(b64), aad: textAAD2(sender, recipient))))
        default: throw Failure.unknownFormat(format)
        }
    }

    public static func encryptReaction(_ key: SymmetricKey, _ emoji: String, sender: Int64, recipient: Int64, message: Int64) throws -> String {
        toB64(try seal(key, Data(emoji.utf8), aad: reactionAAD(sender, recipient, message)))
    }

    public static func decryptReaction(_ key: SymmetricKey, _ b64: String, sender: Int64, recipient: Int64, message: Int64) throws -> String {
        utf8(try open(key, fromB64(b64), aad: reactionAAD(sender, recipient, message)))
    }

    /// A new version of a sent text (plan X29): the text envelope, bound to the message it edits.
    public static func encryptEdit(_ key: SymmetricKey, _ text: String, sender: Int64, recipient: Int64, message: Int64) throws -> String {
        toB64(try seal(key, Data(packText(text).utf8), aad: editAAD(sender, recipient, message)))
    }

    public static func decryptEdit(_ key: SymmetricKey, _ b64: String, sender: Int64, recipient: Int64, message: Int64) throws -> String {
        try unpackText(utf8(open(key, fromB64(b64), aad: editAAD(sender, recipient, message)))).text
    }
}
