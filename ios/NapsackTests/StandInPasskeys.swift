import CryptoKit
import Foundation
@testable import Napsack

/// A stand-in for the phone's passkeys (the system's sheet can't be driven in
/// tests): it makes passkeys and signs with them as an authenticator does,
/// with the bytes the smoke test's Passkey class makes (tests/smoke_test.py):
/// ES256, "none" attestation, the person present and verified, and iCloud
/// Keychain's AAGUID. Its PRF secret is what an authenticator's hmac-secret
/// gives: HMAC-SHA256 of WebAuthn's salt for the input, under a key of the
/// passkey's own.
@MainActor final class StandInPasskeys: PasskeyAuthenticator {
    struct Credential {
        let id: Data
        let rpID: String
        let key: P256.Signing.PrivateKey
        /// The passkey's own secret for PRF (hmac-secret's CredRandom).
        let prfKey: SymmetricKey
    }

    /// The origin its client data says: the local test server's relying party
    /// is "localhost", which takes any http://localhost port.
    let origin: String
    private(set) var credentials: [Credential] = []
    /// Whether its passkeys give a PRF secret at all, and already as they're made.
    var prf = true
    var prfAsMade = true
    /// The next sheet is closed instead of answered.
    var closesSheet = false
    /// Answers with this secret instead of its own (the vectors' secret).
    var fixedSecret: Data?
    /// Answers with this passkey whatever was asked for, as a sheet that ignored `allowed` would.
    var answersWith: Data?
    private(set) var signed: [(rpID: String, allowed: [Data])] = []
    private(set) var forgotten: [Data] = []

    static let iCloudKeychain = Data([0xfb, 0xfc, 0x30, 0x07, 0x15, 0x4e, 0x4e, 0xcc, 0x8c, 0x0b, 0x6e, 0x02, 0x05, 0x57, 0xd7, 0xbd])

    init(origin: String = "http://localhost") {
        self.origin = origin
    }

    /// The local test server's: http://localhost and its port.
    convenience init(server address: String) {
        let port = URL(string: address)?.port.map { ":\($0)" } ?? ""
        self.init(origin: "http://localhost\(port)")
    }

    /// Another device with the same passkeys (iCloud Keychain keeps them on
    /// each), and nothing forgotten there yet.
    convenience init(sharing other: StandInPasskeys) {
        self.init(origin: other.origin)
        credentials = other.credentials
    }

    func works(for rpID: String) -> Bool { true }

    func create(rpID: String, challenge: Data, userName: String, userID: Data, excluding: [Data], prfInput: Data) async throws -> NewPasskey {
        if closesSheet { closesSheet = false; throw PasskeyError.canceled }
        if credentials.contains(where: { $0.rpID == rpID && excluding.contains($0.id) }) { throw PasskeyError.alreadyAdded }
        let credential = Credential(id: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }, rpID: rpID,
                                    key: P256.Signing.PrivateKey(), prfKey: SymmetricKey(size: .bits256))
        credentials.append(credential)
        let client = clientData("webauthn.create", challenge)
        let attestation = CBOR.map([
            (CBOR.text("fmt"), CBOR.text("none")),
            (CBOR.text("attStmt"), CBOR.map([])),
            (CBOR.text("authData"), CBOR.bytes(authData(credential, flags: 0x45, created: true))),
        ])
        return NewPasskey(credentialID: credential.id, clientDataJSON: client, attestationObject: attestation,
                          prfSupported: prf, prfSecret: prf && prfAsMade ? secret(credential, prfInput) : nil)
    }

    func sign(rpID: String, challenge: Data, allowed: [Data], prfInput: Data) async throws -> PasskeySignature {
        signed.append((rpID, allowed))
        if closesSheet { closesSheet = false; throw PasskeyError.canceled }
        // The newest of the site's, as the sheet would offer first (or one of those allowed).
        let wanted = answersWith.map { [$0] } ?? allowed
        guard let credential = credentials.last(where: { $0.rpID == rpID && (wanted.isEmpty || wanted.contains($0.id)) }) else {
            throw PasskeyError.canceled  // no passkey to offer: the person can only close the sheet
        }
        let client = clientData("webauthn.get", challenge)
        let data = authData(credential, flags: 0x05, created: false)
        let signature = try credential.key.signature(for: data + Data(SHA256.hash(data: client)))
        return PasskeySignature(credentialID: credential.id, clientDataJSON: client, authenticatorData: data,
                                signature: signature.derRepresentation, prfSecret: prf ? secret(credential, prfInput) : nil)
    }

    func forget(rpID: String, credentialID: Data) async {
        forgotten.append(credentialID)
    }

    /// One of its passkeys' PRF secret for an input, as it would answer.
    func secret(of id: Data, for input: Data) -> SymmetricKey? {
        credentials.first { $0.id == id }.map { secret($0, input) }
    }

    // ---------- the bytes ----------

    private func clientData(_ type: String, _ challenge: Data) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        struct Client: Encodable { let type: String; let challenge: String; let origin: String }
        return try! encoder.encode(Client(type: type, challenge: Passkeys.b64url(challenge), origin: origin))
    }

    /// sha256(rp id) | flags | count 0 | (AAGUID | id length | id | COSE key) when made.
    private func authData(_ c: Credential, flags: UInt8, created: Bool) -> Data {
        var d = Data(SHA256.hash(data: Data(c.rpID.utf8)))
        d.append(flags)
        d.append(contentsOf: [0, 0, 0, 0])
        if created {
            let point = c.key.publicKey.rawRepresentation  // x | y
            d.append(Self.iCloudKeychain)
            d.append(contentsOf: [UInt8(c.id.count >> 8), UInt8(c.id.count & 0xff)])
            d.append(c.id)
            d.append(CBOR.map([
                (CBOR.int(1), CBOR.int(2)), (CBOR.int(3), CBOR.int(-7)), (CBOR.int(-1), CBOR.int(1)),
                (CBOR.int(-2), CBOR.bytes(point.prefix(32))), (CBOR.int(-3), CBOR.bytes(point.suffix(32))),
            ]))
        }
        return d
    }

    /// hmac-secret: the same secret for the same passkey and input, every time.
    private func secret(_ c: Credential, _ input: Data) -> SymmetricKey {
        if let fixedSecret { return SymmetricKey(data: fixedSecret) }
        let salt = Data(SHA256.hash(data: Data("WebAuthn PRF".utf8) + Data([0]) + input))
        return SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: salt, using: c.prfKey)))
    }
}

/// Just enough CBOR (RFC 8949) for what authenticators send, as the smoke test writes it.
enum CBOR {
    static func head(_ major: UInt8, _ n: Int) -> Data {
        if n < 24 { return Data([major << 5 | UInt8(n)]) }
        if n < 256 { return Data([major << 5 | 24, UInt8(n)]) }
        return Data([major << 5 | 25, UInt8(n >> 8), UInt8(n & 0xff)])
    }
    static func int(_ v: Int) -> Data { v >= 0 ? head(0, v) : head(1, -1 - v) }
    static func bytes(_ b: Data) -> Data { head(2, b.count) + b }
    static func text(_ s: String) -> Data { head(3, s.utf8.count) + Data(s.utf8) }
    static func map(_ pairs: [(Data, Data)]) -> Data { pairs.reduce(head(5, pairs.count)) { $0 + $1.0 + $1.1 } }
}
