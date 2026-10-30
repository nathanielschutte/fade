import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// A server that answers from a script, and remembers what it was asked.
actor StubServer: Transport {
    typealias Answer = @Sendable (URLRequest) throws -> (Int, Data)
    private let answer: Answer
    private(set) var requests: [URLRequest] = []

    init(_ answer: @escaping Answer) { self.answer = answer }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = try answer(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class MemoryStore: AccountStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: Account?

    init(_ account: Account? = nil) { kept = account }
    func load() throws -> Account? { lock.withLock { kept } }
    func save(_ account: Account) throws { lock.withLock { kept = account } }
    func delete() throws { lock.withLock { kept = nil } }
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

/// Signing in, keeping, and ending a session, against a stand-in server and
/// the vectors' account (tests/vectors/format1.json: its password, auth key,
/// and wrapped private key are known).
@MainActor @Suite struct SessionTests {
    let v: [String: Any]
    let password: [String: Any]
    var me: [String: Any] { ["id": 7, "username": password["username"]!, "display_name": NSNull(), "role": "user", "has_recovery_key": true, "is_admin": false] }

    init() throws {
        let file = try #require(Bundle.main.url(forResource: "vectors", withExtension: nil)).appending(path: "format1.json")
        v = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        password = v["password"] as! [String: Any]
    }

    /// A server whose login hands back the vectors' account, whatever key it's given.
    func vectorServer() -> StubServer {
        let answer = json(["token": "the-token", "user": me, "public_key": (v["alice"] as! [String: Any])["spki"]!,
                           "wrapped_private_key": password["wrapped_private_key"]!])
        return StubServer { request in
            request.url!.path == "/api/auth/login" ? (200, answer) : (404, json(["error": "not here"]))
        }
    }

    @Test func signsInWithoutTheServerEverSeeingThePassword() async throws {
        let server = vectorServer(), store = MemoryStore()
        let session = Session(transport: server, store: store)
        try await session.signIn(server: "https://napsack.test", username: " \(password["username"]!) ", password: password["password"] as! String)

        let sent = await server.requests
        #expect(sent.count == 1)
        #expect(sent[0].url?.absoluteString == "https://napsack.test/api/auth/login")
        #expect(sent[0].value(forHTTPHeaderField: "X-Napsack-Client")?.hasPrefix("ios/") == true)
        #expect(body(sent[0])["username"] as? String == password["username"] as? String)  // trimmed
        #expect(body(sent[0])["auth_key"] as? String == password["auth_key"] as? String)
        #expect(!String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self).contains(password["password"] as! String))

        // Signed in, and the key it kept opens the vectors' message from Bob.
        let account = try #require(session.account)
        #expect(account.token == "the-token" && account.user.id == 7)
        #expect(try store.load() == account)
        let bob = v["bob"] as! [String: Any], text = v["text"] as! [String: Any]
        let key = try E2E.pairKey(mine: account.identity(), theirs: bob["spki"] as! String,
                                  myId: (v["alice"] as! [String: Any])["id"] as! Int64, theirId: bob["id"] as! Int64)
        #expect(try E2E.decryptText(key, text["ciphertext"] as! String, sender: text["from"] as! Int64, recipient: text["to"] as! Int64)
                == text["plaintext"] as! String)
    }

    @Test func theServersRefusalIsWhatThePersonSees() async throws {
        let server = StubServer { _ in (400, json(["error": "Wrong username or password."])) }
        let session = Session(transport: server, store: MemoryStore())
        await #expect(throws: ServerError.refused("Wrong username or password.", status: 400)) {
            try await session.signIn(server: "https://napsack.test", username: "ana", password: "nope nope")
        }
        #expect(session.state == .starting)  // never signed in
    }

    @Test func aWrongPasswordTheServerLetThroughStillCantUnlock() async throws {
        let session = Session(transport: vectorServer(), store: MemoryStore())
        await #expect(throws: SignInError.cantUnlock) {
            try await session.signIn(server: "https://napsack.test", username: password["username"] as! String, password: "not the password")
        }
        #expect(session.account == nil)
    }

    @Test func anEmailAddressIsCaughtBeforeAskingTheServer() async throws {
        let server = vectorServer()
        let session = Session(transport: server, store: MemoryStore())
        await #expect(throws: SignInError.emailAddress) {
            try await session.signIn(server: "https://napsack.test", username: "ana@example.com", password: "whatever")
        }
        #expect(await server.requests.isEmpty)
    }

    @Test func anOutOfDateAppIsToldSo() async throws {
        let server = StubServer { _ in (426, json(["error": "Update napsack to keep using it."])) }
        let session = Session(transport: server, store: MemoryStore())
        await #expect(throws: ServerError.updateRequired("Update napsack to keep using it.")) {
            try await session.signIn(server: "https://napsack.test", username: "ana", password: "whatever")
        }
    }

    func keptAccount() throws -> Account {
        let me = try JSONDecoder.snake.decode(Me.self, from: json(self.me))
        return Account(server: "https://napsack.test", token: "kept-token", user: me, publicKey: "pk", privateKey: P256.KeyAgreement.PrivateKey().derRepresentation)
    }

    @Test func aKeptSessionTheServerEndedSignsOut() async throws {
        let store = MemoryStore(try keptAccount())
        let session = Session(transport: StubServer { _ in (401, json(["error": "Sign in first."])) }, store: store)
        await session.restore(server: "https://napsack.test")
        #expect(session.state == .signedOut)
        #expect(session.notice == "Your session ended. Sign in again.")
        #expect(try store.load() == nil)
    }

    @Test func aKeptSessionStaysWhenTheServerIsOutOfReach() async throws {
        let kept = try keptAccount()
        let session = Session(transport: StubServer { _ in throw URLError(.notConnectedToInternet) }, store: MemoryStore(kept))
        await session.restore(server: "https://napsack.test")
        #expect(session.state == .signedIn(kept))
    }

    @Test func signingOutEndsTheSessionAndForgetsTheKeys() async throws {
        let store = MemoryStore(try keptAccount())
        let meAnswer = json(me)
        let server = StubServer { request in
            request.url!.path == "/api/me" ? (200, meAnswer) : (200, json(["ok": true]))
        }
        let session = Session(transport: server, store: store)
        await session.restore(server: "https://napsack.test")
        await session.signOut()
        let logout = try #require(await server.requests.last)
        #expect(logout.url?.path == "/api/auth/logout" && logout.httpMethod == "POST")
        #expect(logout.value(forHTTPHeaderField: "Authorization") == "Bearer kept-token")
        #expect(session.state == .signedOut && session.notice == nil)
        #expect(try store.load() == nil)
    }

    /// Nothing of the account stays (CLAUDE.md, Security): no session, no
    /// reports sent as it, nothing the system kept for its requests. Its pins
    /// stay, as on the web: public keys only.
    @Test func signingOutLeavesNothingOfTheAccount() async throws {
        let store = MemoryStore(try keptAccount())
        let meAnswer = json(me)
        let server = StubServer { request in
            request.url!.path == "/api/me" ? (200, meAnswer) : (204, Data())
        }
        let reporter = Reporter(transport: server)
        let session = Session(transport: server, store: store, reporter: reporter)
        await session.restore(server: "https://napsack.test")
        #expect(reporter.signedIn)
        let pins = MemoryPinStore()
        var pinned = Pins()
        _ = pinned.see(7, "a friend's public key")
        try pins.save(pinned, account: 3)

        await session.signOut()
        #expect(try store.load() == nil && session.account == nil)
        #expect(!reporter.signedIn)
        // The system never kept the account's requests: no cache, no cookies.
        let config = NetworkTransport.session.configuration
        #expect(config.urlCache == nil && config.httpCookieStorage == nil && !config.httpShouldSetCookies)
        #expect(pins.load(account: 3) == pinned)
    }

    @Test func signingOutOfflineStillForgetsTheKeys() async throws {
        let store = MemoryStore(try keptAccount())
        let session = Session(transport: StubServer { _ in throw URLError(.notConnectedToInternet) }, store: store)
        await session.restore(server: "https://napsack.test")
        await session.signOut()
        #expect(session.state == .signedOut)
        #expect(try store.load() == nil)
    }
}

extension JSONDecoder {
    static var snake: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Roles as the server names them (roles.md): the app shows its debugging tools to Admins only.
@Test func rolesFromTheServer() {
    func me(_ role: String) -> Me { Me(id: 1, username: "nate", displayName: nil, role: role, hasRecoveryKey: true) }
    #expect(me("admin").isAdmin && me("admin").isPowerUser)
    #expect(!me("power").isAdmin && me("power").isPowerUser)
    #expect(!me("powerxtreme").isAdmin && me("powerxtreme").isPowerUser)
    #expect(!me("user").isAdmin && !me("user").isPowerUser)
    #expect(!me("something new").isAdmin)
}

/// The one server is named outside production only (Nate, 2026-10-30).
@Test func theServerIsNamedOnlyOutsideProduction() {
    #expect(AppInfo.serverLabel(environment: nil, server: "https://napsack.io") == nil)
    #expect(AppInfo.serverLabel(environment: "staging", server: "https://staging.napsack.io") == "staging.napsack.io (staging)")
    #expect(AppInfo.serverLabel(environment: nil, server: "http://Nates-Laptop.local:8080")?.lowercased() == "nates-laptop.local")
}
