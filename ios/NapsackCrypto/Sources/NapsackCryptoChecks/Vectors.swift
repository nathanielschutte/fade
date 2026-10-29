import Foundation

/// The pinned vectors (tests/vectors/*.json), decoded into the fields the
/// checks use. The files are never copied or regenerated: the tests read them
/// from the repository, and the app from a copy Xcode puts in it when it builds.
public struct Vectors: Sendable {
    public static let files = ["format1", "format2", "recovery", "texts2", "group3", "media4", "edits2", "media6"]

    let format1: Format1
    let format2: Format2
    let recovery: Recovery
    let texts2: Texts2
    let group3: Group3
    let media4: Media4
    let edits2: Edits2
    let media6: Media6

    /// Reads every vector file from `directory`.
    public static func load(from directory: URL) throws -> Vectors {
        func file<T: Decodable>(_ name: String) throws -> T {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: Data(contentsOf: directory.appending(path: "\(name).json")))
        }
        return Vectors(
            format1: try file("format1"), format2: try file("format2"), recovery: try file("recovery"),
            texts2: try file("texts2"), group3: try file("group3"), media4: try file("media4"),
            edits2: try file("edits2"), media6: try file("media6"))
    }
}

/// A sealed group message as the vectors hold it: wraps keyed by member id.
struct SealedGroup: Decodable, Sendable {
    let clientId: String
    let recipients: [Int64]
    let content: String
    let wraps: [String: String]

    func wrap(for member: Int64) -> String { wraps[String(member)] ?? "" }
}

struct Format1: Decodable, Sendable {
    struct Password: Decodable, Sendable {
        let username: String
        let password: String
        let authKey: String
        let wrappedPrivateKey: String
    }
    struct Party: Decodable, Sendable {
        let id: Int64
        let pkcs8: String
        let spki: String
    }
    struct Text: Decodable, Sendable {
        let from: Int64
        let to: Int64
        let plaintext: String
        let ciphertext: String
    }
    struct Snap: Decodable, Sendable {
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
    let safetyCode: String
}

struct Format2: Decodable, Sendable {
    struct Pic: Decodable, Sendable {
        let from: Int64
        let to: Int64
        let caption: String
        let photoB64: String
        let plaintextB64: String
        let ciphertextB64: String
    }
    let pic: Pic
    let picNoCaption: Pic
}

struct Recovery: Decodable, Sendable {
    let keyBytesHex: String
    let recoveryKey: String
    let recoveryAuthKey: String
    let recoveryWrappedKey: String
}

struct Texts2: Decodable, Sendable {
    struct Text: Decodable, Sendable {
        let from: Int64
        let to: Int64
        let text: String
        let replyTo: Int64?
        let plaintext: String
        let ciphertext: String
    }
    struct Reaction: Decodable, Sendable {
        let from: Int64
        let to: Int64
        let messageId: Int64
        let emoji: String
        let ciphertext: String
    }
    let texts: [Text]
    let reaction: Reaction
}

struct Group3: Decodable, Sendable {
    struct Text: Decodable, Sendable {
        let text: String
        let replyTo: Int64?
        let plaintext: String
        let clientId: String
        let recipients: [Int64]
        let content: String
        let wraps: [String: String]
        var sealed: SealedGroup { SealedGroup(clientId: clientId, recipients: recipients, content: content, wraps: wraps) }
    }
    struct Pic: Decodable, Sendable {
        let caption: String
        let photo: String
        let clientId: String
        let recipients: [Int64]
        let content: String
        let wraps: [String: String]
        var sealed: SealedGroup { SealedGroup(clientId: clientId, recipients: recipients, content: content, wraps: wraps) }
    }
    let groupId: Int64
    let sender: Int64
    let text: Text
    let pic: Pic
}

struct DirectMedia: Decodable, Sendable {
    let from: Int64
    let to: Int64
    let type: String
    let caption: String
    let y: Double?
    let media: String
    let plaintext: String
    let ciphertext: String
}

struct GroupMedia: Decodable, Sendable {
    let groupId: Int64
    let sender: Int64
    let type: String
    let caption: String
    let y: Double?
    let media: String
    let clientId: String
    let recipients: [Int64]
    let content: String
    let wraps: [String: String]
    var sealed: SealedGroup { SealedGroup(clientId: clientId, recipients: recipients, content: content, wraps: wraps) }
}

struct Media4: Decodable, Sendable {
    let direct: DirectMedia
    let group: GroupMedia
}

typealias Media6 = Media4

struct Edits2: Decodable, Sendable {
    struct Direct: Decodable, Sendable {
        let from: Int64
        let to: Int64
        let messageId: Int64
        let text: String
        let plaintext: String
        let ciphertext: String
    }
    struct Group: Decodable, Sendable {
        let groupId: Int64
        let sender: Int64
        let messageId: Int64
        let text: String
        let clientId: String
        let recipients: [Int64]
        let content: String
        let wraps: [String: String]
        var sealed: SealedGroup { SealedGroup(clientId: clientId, recipients: recipients, content: content, wraps: wraps) }
    }
    let direct: Direct
    let group: Group
}
