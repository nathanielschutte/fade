import CryptoKit
import Foundation
import NapsackCrypto

/// The local test server, from the other end of a chat: what a friend's own
/// app would do, done here so the UI tests can watch the real app answer it.
/// Accounts are made the way the apps make them (keys from the password, a
/// new key pair), and texts are sealed here with NapsackCrypto, so what the
/// app shows was really decrypted on the phone. scripts/test-ios.sh runs the
/// server and passes its address (NAPSACK_TEST_SERVER); without it the UI
/// tests skip.
struct TestServer: Sendable {
    let address: String
    let invite: String

    static var configured: TestServer? {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["NAPSACK_TEST_SERVER"], !address.isEmpty else { return nil }
        return TestServer(address: address, invite: env["NAPSACK_TEST_INVITE"] ?? "letmein")
    }

    /// Someone with an account: what signing in through the app needs, and what sealing for them needs.
    struct Person: Sendable {
        let id: Int64
        let username: String
        let password: String
        let token: String
        let publicKey: String
        let identity: P256.KeyAgreement.PrivateKey
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func request(_ path: String, method: String = "GET", token: String? = nil, json: [String: Any]? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: address)!.appending(path: "api").appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(description: "\(method) \(path): \(status) \(String(decoding: data, as: UTF8.self))")
        }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    /// A new account, as sign-up makes one.
    func newAccount(_ name: String) async throws -> Person {
        let username = "\(name)_\(UUID().uuidString.prefix(6).lowercased())"
        let password = "correct horse battery"
        let keys = try E2E.deriveFromPassword(username: username, password: password)
        let identity = try E2E.createIdentity(wrapKey: keys.wrapKey)
        let answer = try await request("auth/register", method: "POST", json: [
            "username": username, "auth_key": keys.authKey, "public_key": identity.publicKey,
            "wrapped_private_key": identity.wrappedPrivateKey, "invite_code": invite,
        ]) as? [String: Any]
        guard let token = answer?["token"] as? String, let user = answer?["user"] as? [String: Any],
              let id = (user["id"] as? NSNumber)?.int64Value else { throw Failure(description: "sign-up answered \(String(describing: answer))") }
        return Person(id: id, username: username, password: password, token: token, publicKey: identity.publicKey,
                      identity: identity.privateKey)
    }

    /// Each asks the other: the second request accepts the first.
    func befriend(_ a: Person, _ b: Person) async throws {
        _ = try await request("friends/requests", method: "POST", token: a.token, json: ["username": b.username])
        _ = try await request("friends/requests", method: "POST", token: b.token, json: ["username": a.username])
    }

    /// A profile picture for them (a JPEG, as the app uploads one).
    func setPicture(_ jpeg: Data, for person: Person) async throws {
        var request = URLRequest(url: URL(string: address)!.appending(path: "api/me/avatar"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(person.token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(description: "POST me/avatar: \(status) \(String(decoding: data, as: UTF8.self))")
        }
    }

    /// A text from one to the other (format 2), sealed here.
    @discardableResult func send(_ text: String, from: Person, to: Person) async throws -> Int64 {
        let key = try E2E.pairKey(mine: from.identity, theirs: to.publicKey, myId: from.id, theirId: to.id)
        let sealed = try E2E.encryptText2(key, text, replyTo: nil, sender: from.id, recipient: to.id)
        let stored = try await request("chats/\(to.id)/messages", method: "POST", token: from.token, json: [
            "ciphertext": sealed, "format": 2, "client_id": UUID().uuidString,
        ]) as? [String: Any]
        return (stored?["id"] as? NSNumber)?.int64Value ?? 0
    }

    /// A reaction from one to a message in their chat with the other, sealed here (nil takes it back).
    func react(_ emoji: String?, to message: Int64, from: Person, to: Person) async throws {
        let key = try E2E.pairKey(mine: from.identity, theirs: to.publicKey, myId: from.id, theirId: to.id)
        let sealed = try emoji.map { try E2E.encryptReaction(key, $0, sender: from.id, recipient: to.id, message: message) }
        _ = try await request("chats/\(to.id)/messages/\(message)/reaction", method: "PUT", token: from.token, json: [
            "ciphertext": sealed ?? NSNull(), "format": 2,
        ])
    }
}

/// Someone's live connection (as their app keeps one): signed in with the
/// first frame, then it can say they're typing.
final class FriendSocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(_ server: TestServer, as person: TestServer.Person) async throws {
        var parts = URLComponents(string: server.address)!
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        task = URLSession.shared.webSocketTask(with: parts.url!.appending(path: "api/ws"))
        task.resume()
        try await send(["type": "auth", "token": person.token])
        // Signed in once the server says ready.
        while true {
            let frame = try await task.receive()
            var text = ""
            if case .string(let s) = frame { text = s }
            if case .data(let d) = frame { text = String(decoding: d, as: UTF8.self) }
            if text.contains(#""type":"ready""#) { break }
            if text.contains("auth_failed") { throw TestServer.Failure(description: "the socket wasn't signed in") }
        }
    }

    func typing(to person: TestServer.Person) async throws {
        try await send(["type": "typing", "to": person.id])
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ frame: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
