// End-to-end encryption for the iOS app: the formats shared/crypto/crypto.js
// defines (the reference implementation), byte for byte. The pinned vectors in
// tests/vectors/ are the contract; when this disagrees with one, this is wrong.
//
// Password -> PBKDF2 (salted with the username) -> master secret, split by HKDF into:
//   auth key: sent to the server in place of the password
//   wrap key: never leaves the device; encrypts the private key the server stores
// Each account has a P-256 key pair. Two friends' keys give them a shared
// AES-GCM key (ECDH + HKDF) that encrypts every text and pic between them.
//
// Done so far: format 1 (the password, the identity, texts and pics). The other
// formats follow the same pattern (docs/design/mobile.md, First milestones).

import CommonCrypto
import CryptoKit
import Foundation

public enum E2E {
    static let pbkdf2Iterations: UInt32 = 600_000

    public enum Failure: Error, Equatable {
        case notBase64
        case passwordDerivation(Int32)
    }

    /// What a password gives: the auth key (base64) the server checks instead
    /// of the password, and the wrap key, which never leaves the device.
    public struct PasswordKeys: Sendable {
        public let authKey: String
        public let wrapKey: SymmetricKey
    }

    // ---------- encoding ----------

    public static func fromB64(_ b64: String) throws -> Data {
        guard let data = Data(base64Encoded: b64) else { throw Failure.notBase64 }
        return data
    }

    public static func toB64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    // ---------- AES-GCM ----------
    // Sealed bytes are IV || ciphertext || tag (CryptoKit's "combined" form).
    // `aad` binds the ciphertext to its context, so the server can't move it to
    // another chat, sender, or kind of message.

    public static func seal(_ key: SymmetricKey, _ plaintext: Data, aad: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: Data(aad.utf8))
        // Always present with a 12-byte nonce, which AES.GCM.Nonce() is.
        return box.combined!
    }

    public static func open(_ key: SymmetricKey, _ sealed: Data, aad: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(aad.utf8))
    }

    // ---------- password ----------

    /// Slow on purpose (600,000 rounds of PBKDF2; near a second on a phone).
    /// Usernames are case-insensitive, so the salt is too.
    public static func deriveFromPassword(username: String, password: String) throws -> PasswordKeys {
        let salt = Array("napsack/v1/user/\(username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())".utf8)
        let secret = Array(password.utf8)
        var master = [UInt8](repeating: 0, count: 32)
        let status = secret.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress?.assumingMemoryBound(to: CChar.self), secret.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), pbkdf2Iterations,
                &master, master.count)
        }
        guard status == kCCSuccess else { throw Failure.passwordDerivation(status) }
        let input = SymmetricKey(data: master)
        let auth = hkdf(input, info: "napsack/v1/auth")
        return PasswordKeys(
            authKey: auth.withUnsafeBytes { toB64(Data($0)) },
            wrapKey: hkdf(input, info: "napsack/v1/wrap"))
    }

    /// HKDF-SHA256 with an empty salt, as crypto.js derives the password's keys.
    static func hkdf(_ input: SymmetricKey, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: Data(), info: Data(info.utf8), outputByteCount: 32)
    }

    // ---------- identity ----------

    static let wrapAAD = "napsack/v1/identity"

    /// Throws if the wrap key is wrong (wrong password, or the server swapped the blob).
    public static func unwrapIdentity(wrapKey: SymmetricKey, wrapped b64: String) throws -> P256.KeyAgreement.PrivateKey {
        let pkcs8 = try open(wrapKey, fromB64(b64), aad: wrapAAD)
        return try P256.KeyAgreement.PrivateKey(derRepresentation: pkcs8)
    }

    // ---------- a friend's chat key ----------

    /// Both friends derive the same key: ECDH, then HKDF salted with both ids in order.
    public static func pairKey(mine: P256.KeyAgreement.PrivateKey, theirs b64: String, myId: Int64, theirId: Int64) throws -> SymmetricKey {
        let theirKey = try P256.KeyAgreement.PublicKey(derRepresentation: fromB64(b64))
        let shared = try mine.sharedSecretFromKeyAgreement(with: theirKey)
        let (lo, hi) = (min(myId, theirId), max(myId, theirId))
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("napsack/v1/pair/\(lo)/\(hi)".utf8),
            sharedInfo: Data("napsack/v1/messages".utf8),
            outputByteCount: 32)
    }

    // ---------- format 1: texts and pics ----------

    public static func messageAAD(_ kind: String, sender: Int64, recipient: Int64) -> String {
        "napsack/v1/\(kind)/\(sender)/\(recipient)"
    }

    public static func encryptText(_ key: SymmetricKey, _ text: String, sender: Int64, recipient: Int64) throws -> String {
        toB64(try seal(key, Data(text.utf8), aad: messageAAD("text", sender: sender, recipient: recipient)))
    }

    public static func decryptText(_ key: SymmetricKey, _ b64: String, sender: Int64, recipient: Int64) throws -> String {
        let bytes = try open(key, fromB64(b64), aad: messageAAD("text", sender: sender, recipient: recipient))
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func encryptSnap(_ key: SymmetricKey, _ bytes: Data, sender: Int64, recipient: Int64) throws -> Data {
        try seal(key, bytes, aad: messageAAD("snap", sender: sender, recipient: recipient))
    }

    public static func decryptSnap(_ key: SymmetricKey, _ sealed: Data, sender: Int64, recipient: Int64) throws -> Data {
        try open(key, sealed, aad: messageAAD("snap", sender: sender, recipient: recipient))
    }
}
