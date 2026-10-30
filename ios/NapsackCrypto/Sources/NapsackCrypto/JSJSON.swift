import Foundation

/// JSON exactly as JavaScript writes and reads it. Envelopes (format 2 texts,
/// the media header) are sealed as bytes, and the vectors pin those bytes, so
/// they're written the way `JSON.stringify` writes them: keys in the order
/// given, strings escaped only where JavaScript escapes them (quote, backslash,
/// control characters; never "/" or anything else), numbers in their shortest
/// form (1, not 1.0). Swift's own JSON encoders differ on each of these.
enum JSJSON {
    enum Value {
        case string(String)
        case int(Int64)
        case double(Double)
    }

    static func object(_ fields: [(String, Value)]) -> String {
        "{" + fields.map { quote($0.0) + ":" + encode($0.1) }.joined(separator: ",") + "}"
    }

    static func encode(_ value: Value) -> String {
        switch value {
        case .string(let s): quote(s)
        case .int(let n): String(n)
        case .double(let d): number(d)
        }
    }

    /// JavaScript's form for the numbers envelopes hold (a caption's place, 0 to
    /// 1 in thousandths): whole numbers without ".0", others shortest round-trip.
    static func number(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// `JSON.parse`: any JSON value, or throws. Objects come back as `[String: Any]`.
    static func parse(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// A JSON number (not true or false, which Foundation also hands back as NSNumber).
    static func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// `Number.isSafeInteger`: a whole number JavaScript holds exactly.
    static func safeInteger(_ any: Any?) -> Int64? {
        guard let d = number(any), d == d.rounded(), abs(d) <= 9_007_199_254_740_991 else { return nil }
        return Int64(d)
    }
}
