import CryptoKit
import Foundation
import NapsackCrypto

/// Everything a signed-in phone keeps: which server, the session token, who
/// it is, and the private key that opens their messages. Kept as one Keychain
/// item (AccountStore), so it's all there or none of it is.
struct Account: Codable, Equatable, Sendable {
    let server: String
    let token: String
    var user: Me
    let publicKey: String
    /// PKCS#8, as the identity was wrapped (crypto.js, createIdentity).
    let privateKey: Data

    func identity() throws -> P256.KeyAgreement.PrivateKey {
        try P256.KeyAgreement.PrivateKey(derRepresentation: privateKey)
    }
}

/// Where the account is kept between launches: the Keychain on a phone,
/// memory in tests.
protocol AccountStore: Sendable {
    func load() throws -> Account?
    func save(_ account: Account) throws
    func delete() throws
}

struct KeychainAccountStore: AccountStore {
    let item = "session"

    func load() throws -> Account? {
        try Keychain.read(account: item).map { try JSONDecoder().decode(Account.self, from: $0) }
    }

    func save(_ account: Account) throws {
        try Keychain.save(JSONEncoder().encode(account), account: item)
    }

    func delete() throws {
        try Keychain.delete(account: item)
    }
}

enum SignInError: LocalizedError, Equatable {
    case emailAddress
    case cantUnlock

    var errorDescription: String? {
        switch self {
        // People type their email here (plan X32); usernames can't hold an @.
        case .emailAddress: "That's an email address. Sign in with your napsack username instead."
        case .cantUnlock: "Couldn't unlock your keys. Check your password."
        }
    }
}

/// Who's signed in on this phone, as the app's screens see it. Signing in
/// works as the web app's does (app.js, auth): the password never leaves the
/// phone, only a key derived from it; the server hands back the private key
/// wrapped, and only the password unwraps it.
@MainActor @Observable final class Session {
    enum State: Equatable {
        /// Reading the Keychain, at launch.
        case starting
        case signedOut
        case signedIn(Account)
    }

    private(set) var state: State = .starting
    /// Something to tell the person on the sign-in screen ("Your session ended").
    var notice: String?

    private let transport: any Transport
    private let store: any AccountStore

    init(transport: any Transport = NetworkTransport(), store: any AccountStore = KeychainAccountStore()) {
        self.transport = transport
        self.store = store
    }

    var account: Account? {
        if case .signedIn(let account) = state { account } else { nil }
    }

    /// At launch: straight in with what the Keychain holds, then confirm with
    /// the server. A session the server has ended signs out; no connection
    /// keeps what's here.
    func restore() async {
        guard let kept = try? store.load() else {
            state = .signedOut
            return
        }
        state = .signedIn(kept)
        do {
            let me = try await Server(kept.server, transport: transport).me(token: kept.token)
            if me != kept.user, var updated = account, updated.token == kept.token {
                updated.user = me
                try? store.save(updated)
                state = .signedIn(updated)
            }
        } catch ServerError.sessionEnded {
            endLocally(notice: ServerError.sessionEnded.errorDescription)
        } catch {
            // Offline or the server's down: stay signed in, as the web app does.
        }
    }

    func signIn(server address: String, username typed: String, password: String) async throws {
        let username = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.contains("@") else { throw SignInError.emailAddress }
        let server = try Server(address, transport: transport)
        notice = nil
        // 600,000 rounds of PBKDF2: off the main thread.
        let keys = try await Task.detached(priority: .userInitiated) {
            try E2E.deriveFromPassword(username: username, password: password)
        }.value
        let answer = try await server.login(username: username, authKey: keys.authKey)
        let identity: P256.KeyAgreement.PrivateKey
        do {
            identity = try E2E.unwrapIdentity(wrapKey: keys.wrapKey, wrapped: answer.wrappedPrivateKey)
        } catch {
            throw SignInError.cantUnlock
        }
        let account = Account(server: server.address, token: answer.token, user: answer.user,
                              publicKey: answer.publicKey, privateKey: identity.derRepresentation)
        try store.save(account)
        state = .signedIn(account)
    }

    /// Ends the session on the server too, if it can be reached; this phone
    /// forgets it either way.
    func signOut() async {
        guard let account else { return }
        try? await Server(account.server, transport: transport).logout(token: account.token)
        endLocally(notice: nil)
    }

    private func endLocally(notice: String?) {
        try? store.delete()
        self.notice = notice
        state = .signedOut
    }
}
