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

    /// The reactions clients offer (the server checks group reactions against the same set).
    public static let reactions = ["\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F44D}", "\u{1F44E}"]

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
