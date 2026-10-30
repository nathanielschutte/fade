import Foundation
import NapsackCryptoChecks
import Testing

/// Every check in NapsackCryptoChecks (shared/crypto/vector-checks.js in
/// Swift) against the pinned vectors, read from the repository: one test per
/// check, by its name.
@Suite struct VectorTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // NapsackCryptoTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // NapsackCrypto
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // the repository
        .appending(path: "tests/vectors")

    static let results = VectorChecks.run(try! Vectors.load(from: directory))

    @Test(arguments: results)
    func check(_ result: CheckResult) {
        #expect(result.ok, "\(result.name): \(result.error ?? "the check came out false")")
    }

    /// The same checks as JavaScript's, in the same order. When vector-checks.js
    /// gains a check, this fails until the Swift has it too.
    @Test func sameChecksAsJavaScript() {
        #expect(Self.results.map(\.name) == Self.javaScript)
    }

    // vector-checks.js's names, less its two browser-platform checks (WebCrypto,
    // TextEncoder). From: node, runVectorChecks(...).map((r) => r.name).
    static let javaScript = [
        "base64 round-trips",
        "password derives the vector's auth key",
        "username is case-insensitive",
        "unwrapped key decrypts the vector text",
        "a wrong password can't unwrap",
        "both friends derive the chat key",
        "recipient decrypts the vector text",
        "recipient decrypts the vector pic (format 1)",
        "a fresh text round-trips with a fresh IV",
        "swapped sender fails",
        "a text can't be read as a pic",
        "tampering fails",
        "recipient decrypts format 2 pic",
        "packs pic like the vector",
        "recipient decrypts format 2 pic_no_caption",
        "packs pic_no_caption like the vector",
        "format 2 can't be read as format 1",
        "a captioned pic round-trips",
        "a new identity wraps and unwraps",
        "format 2 text 1 decrypts like the vector",
        "format 2 text 2 decrypts like the vector",
        "format 1 texts still read, with no reply",
        "a format 2 text can't be read as format 1",
        "unknown envelope fields are ignored",
        "malformed envelopes are refused",
        "reaction decrypts like the vector",
        "a reaction can't move to another message",
        "a reaction round-trips",
        "group wrap keys for bob and alice",
        "group text decrypts like the vector",
        "the sender's own devices read it too",
        "group pic decrypts like the vector, caption and all",
        "one member's wrap doesn't open for another",
        "a group message can't move to another group",
        "or claim a different member list",
        "a group text can't be read as a pic",
        "changed content fails",
        "a new group message round-trips",
        "a format 4 video decrypts like the vector, caption and all",
        "a video can't be read as a pic",
        "a format 5 group video decrypts like the vector",
        "a group video can't be read as a group pic",
        "only video types travel in the envelope",
        "a video round-trips",
        "a format 6 photo decrypts like the vector, caption and place",
        "a photo can't be read as a video or a format 2 pic",
        "a format 7 group photo decrypts like the vector, with no place",
        "only JPEGs travel as photos",
        "a direct edit decrypts like the vector",
        "an edit can't be moved to another message",
        "an edit can't be read as a text",
        "a group edit decrypts like the vector",
        "recovery key displays like the vector",
        "recovery key reads back despite typos",
        "recovery key derives the vector's auth key",
        "recovery key unlocks the vector's private key",
        "a recovery copy round-trips",
        "the password-wrapped key can't pass as a recovery copy",
        "a wrong recovery key can't unlock",
        "malformed recovery keys are refused",
        "changing the password keeps the same key",
        "safety code matches the vector",
        "safety code is symmetric",
        "new texts and pics are format 2",
    ]
}
