import Foundation

/// The pinned vectors, read from the repository's tests/vectors/ (never copied,
/// never regenerated). Each file is decoded into just the fields the checks use.
enum Vectors {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // NapsackCryptoTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // NapsackCrypto
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // the repository
        .appending(path: "tests/vectors")

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let data = try Data(contentsOf: directory.appending(path: "\(name).json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

/// tests/vectors/format1.json: the original scheme.
struct Format1: Decodable {
    struct Password: Decodable {
        let username: String
        let password: String
        let authKey: String
        let wrappedPrivateKey: String
    }
    struct Party: Decodable {
        let id: Int64
        let pkcs8: String
        let spki: String
    }
    struct Text: Decodable {
        let from: Int64
        let to: Int64
        let plaintext: String
        let ciphertext: String
    }
    struct Snap: Decodable {
        let from: Int64
        let to: Int64
        let plaintextB64: String
        let ciphertextB64: String
    }
    let password: Password
    let alice: Party
    let bob: Party
    let text: Text
    let snap: Snap
}
