import CryptoKit
import Foundation
import Testing
@testable import NapsackCrypto

/// The format 1 checks from shared/crypto/vector-checks.js, against
/// tests/vectors/format1.json, with the same names.
@Suite struct Format1Tests {
    let v: Format1 = try! Vectors.load("format1")

    func priv(_ party: Format1.Party) throws -> P256.KeyAgreement.PrivateKey {
        try P256.KeyAgreement.PrivateKey(derRepresentation: E2E.fromB64(party.pkcs8))
    }

    /// Bob's key for the chat with Alice, the recipient's side of every vector.
    func bobsKey() throws -> SymmetricKey {
        try E2E.pairKey(mine: priv(v.bob), theirs: v.alice.spki, myId: v.bob.id, theirId: v.alice.id)
    }

    @Test("base64 round-trips")
    func base64() throws {
        #expect(E2E.toB64(try E2E.fromB64("AAEC/w==")) == "AAEC/w==")
        #expect(throws: E2E.Failure.notBase64) { try E2E.fromB64("not base64!") }
    }

    @Test("password derives the vector's auth key")
    func authKey() throws {
        let d = try E2E.deriveFromPassword(username: v.password.username, password: v.password.password)
        #expect(d.authKey == v.password.authKey)
    }

    @Test("username is case-insensitive")
    func caseInsensitive() throws {
        let d = try E2E.deriveFromPassword(username: v.password.username.lowercased(), password: v.password.password)
        #expect(d.authKey == v.password.authKey)
    }

    @Test("unwrapped key decrypts the vector text")
    func unwrap() throws {
        let d = try E2E.deriveFromPassword(username: v.password.username, password: v.password.password)
        let mine = try E2E.unwrapIdentity(wrapKey: d.wrapKey, wrapped: v.password.wrappedPrivateKey)
        let key = try E2E.pairKey(mine: mine, theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
        #expect(try E2E.decryptText(key, v.text.ciphertext, sender: v.text.from, recipient: v.text.to) == v.text.plaintext)
    }

    @Test("a wrong password can't unwrap")
    func wrongPassword() throws {
        let wrong = try E2E.deriveFromPassword(username: v.password.username, password: "wrong password")
        #expect(throws: (any Error).self) { try E2E.unwrapIdentity(wrapKey: wrong.wrapKey, wrapped: v.password.wrappedPrivateKey) }
    }

    @Test("both friends derive the chat key")
    func pairKeys() throws {
        let ka = try E2E.pairKey(mine: priv(v.alice), theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
        #expect(ka == (try bobsKey()))
    }

    @Test("recipient decrypts the vector text")
    func text() throws {
        #expect(try E2E.decryptText(bobsKey(), v.text.ciphertext, sender: v.text.from, recipient: v.text.to) == v.text.plaintext)
    }

    @Test("recipient decrypts the vector pic (format 1)")
    func snap() throws {
        let opened = try E2E.decryptSnap(bobsKey(), E2E.fromB64(v.snap.ciphertextB64), sender: v.snap.from, recipient: v.snap.to)
        #expect(E2E.toB64(opened) == v.snap.plaintextB64)
    }

    @Test("a fresh text round-trips with a fresh IV")
    func roundTrip() throws {
        let ka = try E2E.pairKey(mine: priv(v.alice), theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
        let a = try E2E.encryptText(ka, "round trip", sender: v.alice.id, recipient: v.bob.id)
        let b = try E2E.encryptText(ka, "round trip", sender: v.alice.id, recipient: v.bob.id)
        #expect(a != b)
        #expect(try E2E.decryptText(bobsKey(), a, sender: v.alice.id, recipient: v.bob.id) == "round trip")
    }

    @Test("swapped sender fails")
    func swappedSender() throws {
        let key = try bobsKey()
        #expect(throws: (any Error).self) { try E2E.decryptText(key, v.text.ciphertext, sender: v.text.to, recipient: v.text.from) }
    }

    @Test("a text can't be read as a pic")
    func textAsPic() throws {
        let key = try bobsKey()
        #expect(throws: (any Error).self) { try E2E.decryptSnap(key, E2E.fromB64(v.text.ciphertext), sender: v.text.from, recipient: v.text.to) }
    }
}
