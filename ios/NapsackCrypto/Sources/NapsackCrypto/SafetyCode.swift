import CryptoKit
import Foundation

extension E2E {
    /// A code both friends see identically: six groups of five digits. If it
    /// matches when compared in person, no one (the server included) is in the middle.
    public static func safetyCode(_ publicA: String, _ publicB: String) -> String {
        // Sorted the way JavaScript sorts strings (by UTF-16 code unit).
        let (a, b) = publicA.utf16.lexicographicallyPrecedes(publicB.utf16) ? (publicA, publicB) : (publicB, publicA)
        let digest = Array(SHA256.hash(data: Data("napsack/v1/safety/\(a)/\(b)".utf8)))
        return stride(from: 0, to: 12, by: 2)
            .map { i in
                let n = (Int(digest[i]) << 8 | Int(digest[i + 1])) % 100_000
                return String(repeating: "0", count: 5 - String(n).count) + String(n)
            }
            .joined(separator: " ")
    }
}
