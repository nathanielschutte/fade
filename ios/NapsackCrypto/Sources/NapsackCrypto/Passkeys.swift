import CryptoKit
import Foundation

// Passkeys (docs/design/passkeys.md): a third copy of the private key, beside
// the password's and the recovery key's, wrapped by a secret only one passkey
// can produce: WebAuthn's PRF extension, asked for the same input every time.
// The server keeps the copy and never sees the secret. crypto.js's passkey
// section, byte for byte (tests/vectors/passkey1.json).

extension E2E {
    static let passkeyAAD = "napsack/v1/passkey"

    /// The PRF input every napsack passkey is asked for (32 bytes). Each
    /// passkey turns it into its own secret.
    public static func passkeyPrfInput() -> Data {
        Data(SHA256.hash(data: Data("napsack/v1/passkey/prf".utf8)))
    }

    /// The wrap key from a passkey's PRF secret: the bytes, or the key iOS
    /// hands back. The secret is random, so HKDF is enough.
    public static func deriveFromPasskey(_ prfSecret: some ContiguousBytes) throws -> SymmetricKey {
        guard prfSecret.withUnsafeBytes({ $0.count }) == 32 else { throw Failure.notAPasskeySecret }
        return hkdf(SymmetricKey(data: prfSecret), info: "napsack/v1/passkey/wrap")
    }

    /// The passkey's copy of the private key, made from the password-wrapped one.
    public static func wrapForPasskey(wrapKey: SymmetricKey, wrapped: String, passkeyWrapKey: SymmetricKey) throws -> String {
        try rewrap(wrapKey, wrapped, fromAAD: wrapAAD, to: passkeyWrapKey, toAAD: passkeyAAD)
    }

    /// Signing in with a passkey: its copy, opened. Throws for any other passkey's.
    public static func unwrapWithPasskey(passkeyWrapKey: SymmetricKey, wrapped b64: String) throws -> P256.KeyAgreement.PrivateKey {
        var pkcs8 = try open(passkeyWrapKey, fromB64(b64), aad: passkeyAAD)
        defer { pkcs8.resetBytes(in: 0..<pkcs8.count) }
        return try P256.KeyAgreement.PrivateKey(derRepresentation: pkcs8)
    }
}
