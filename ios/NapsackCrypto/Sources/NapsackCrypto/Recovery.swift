import CryptoKit
import Foundation

// A random key the person saves at sign-up. It wraps a second copy of the
// private key, so a forgotten password doesn't cost the message history.
// Shown as 32 Crockford base32 characters in groups of four. It's random
// (160 bits), so HKDF is enough; no slow stretching needed.

extension E2E {
    static let recoveryBytes = 20
    static let recoveryAAD = "napsack/v1/recovery"
    /// Crockford base32: no I, L, O, or U.
    static let base32 = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func toBase32(_ bytes: Data) -> String {
        var out = "", bits = 0, value: UInt32 = 0
        for b in bytes {
            value = (value << 8 | UInt32(b)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                out.append(base32[Int(value >> UInt32(bits - 5) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(base32[Int(value << UInt32(5 - bits) & 31)]) }
        return out
    }

    /// Accepts any case, spaces, and dashes, and the letters people mistype (O for 0, I and L for 1).
    public static func parseRecoveryKey(_ text: String) throws -> Data {
        let clean = text.uppercased()
            .filter { !$0.isWhitespace && $0 != "-" }
            .map { $0 == "O" ? "0" : ($0 == "I" || $0 == "L") ? "1" : $0 }
        guard clean.count == 32, clean.allSatisfy(base32.contains) else { throw Failure.notARecoveryKey }
        var out = Data(), bits = 0, value: UInt32 = 0
        for c in clean {
            value = (value << 5 | UInt32(base32.firstIndex(of: c)!)) & 0xFFFF
            bits += 5
            if bits >= 8 {
                out.append(UInt8(value >> UInt32(bits - 8) & 0xff))
                bits -= 8
            }
        }
        return out
    }

    public static func formatRecoveryKey(_ bytes: Data) -> String {
        let chars = Array(toBase32(bytes))
        return stride(from: 0, to: chars.count - chars.count % 4, by: 4)
            .map { String(chars[$0..<$0 + 4]) }
            .joined(separator: "-")
    }

    public static func newRecoveryKey() -> String {
        formatRecoveryKey(randomBytes(recoveryBytes))
    }

    /// Like deriveFromPassword: an auth key for the server, and a wrap key that stays here.
    public static func deriveFromRecoveryKey(_ text: String) throws -> PasswordKeys {
        let input = SymmetricKey(data: try parseRecoveryKey(text))
        let auth = hkdf(input, info: "napsack/v1/recovery/auth")
        return PasswordKeys(
            authKey: auth.withUnsafeBytes { toB64(Data($0)) },
            wrapKey: hkdf(input, info: "napsack/v1/recovery/wrap"))
    }

    /// The recovery copy of the private key, made from the password-wrapped one.
    public static func wrapForRecovery(wrapKey: SymmetricKey, wrapped: String, recoveryWrapKey: SymmetricKey) throws -> String {
        try rewrap(wrapKey, wrapped, fromAAD: wrapAAD, to: recoveryWrapKey, toAAD: recoveryAAD)
    }

    /// Forgot the password: unwraps with the recovery key and wraps under the new password.
    public static func recoverIdentity(recoveryWrapKey: SymmetricKey, recoveryWrapped: String, newWrapKey: SymmetricKey)
        throws -> (wrappedPrivateKey: String, privateKey: P256.KeyAgreement.PrivateKey)
    {
        let wrapped = try rewrap(recoveryWrapKey, recoveryWrapped, fromAAD: recoveryAAD, to: newWrapKey, toAAD: wrapAAD)
        return (wrapped, try unwrapIdentity(wrapKey: newWrapKey, wrapped: wrapped))
    }
}
