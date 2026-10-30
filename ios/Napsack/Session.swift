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
    case emailAsUsername
    case shortPassword
    case badUsername

    var errorDescription: String? {
        switch self {
        // People type their email here (plan X32); usernames can't hold an @.
        case .emailAddress: "That's an email address. Sign in with your napsack username instead."
        case .cantUnlock: "Couldn't unlock your keys. Check your password."
        case .emailAsUsername: "Pick a username, not an email address: letters, numbers, _ and . only."
        case .shortPassword: "Passwords need at least 8 characters."
        case .badUsername: "Usernames are 3 to 20 characters: letters, numbers, dots, and underscores."
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

    private(set) var state: State = .starting {
        // The app's reports go as whoever's signed in.
        didSet { if let account { reporter.use(server: account.server, token: account.token) } else { reporter.use(server: lastServer, token: nil) } }
    }
    /// Where sign-in last went, for reports while signed out.
    private var lastServer: String?
    /// Something to tell the person on the sign-in screen ("Your session ended").
    var notice: String?
    /// The server needs a newer app: what it says. The app shows nothing else until it's updated.
    private(set) var updateNeeded: String?
    /// A new account's recovery key, shown once until the person says they've saved it.
    var recoveryKeyToShow: String?

    private let transport: any Transport
    private let store: any AccountStore
    private let reporter: Reporter

    init(transport: any Transport = NetworkTransport(), store: any AccountStore = KeychainAccountStore(), reporter: Reporter? = nil) {
        self.transport = transport
        self.store = store
        self.reporter = reporter ?? .shared
    }

    var account: Account? {
        if case .signedIn(let account) = state { account } else { nil }
    }

    /// At launch: straight in with what the Keychain holds, then confirm with
    /// the server. A session the server has ended signs out; no connection
    /// keeps what's here.
    func restore(defaultServer: String) async {
        lastServer = defaultServer
        guard let kept = try? store.load() else {
            state = .signedOut
            await checkVersion(server: defaultServer)
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
        } catch ServerError.updateRequired(let message) {
            updateNeeded = message
        } catch {
            // Offline or the server's down: stay signed in, as the web app does.
        }
    }

    /// At launch (mobile.md, Version handshake): if the server's oldest supported
    /// iOS app is newer than this one, say so before anything else happens.
    /// (Every request also hears it, as a 426.) A server that can't be reached says nothing.
    func checkVersion(server address: String) async {
        guard let server = try? Server(address, transport: transport),
              let minimum = try? await server.config().minimumIOS,
              ClientVersion.isOlder(AppInfo.version, than: minimum)
        else { return }
        updateNeeded = "This version of napsack is too old. Update to \(minimum) or newer to keep using it."
    }

    /// What any screen does with a server's error: an ended session signs out
    /// (and says so), a too-old app shows the update screen. Others are the screen's to show.
    func noticed(_ error: any Error) {
        switch error {
        case ServerError.sessionEnded: endLocally(notice: ServerError.sessionEnded.errorDescription)
        case ServerError.updateRequired(let message): updateNeeded = message
        default: break
        }
    }

    /// Development builds only: back to signing in, to pick another server.
    /// (A server that needs a newer app refuses this one's every request anyway.)
    func leaveUpdateScreen() {
        updateNeeded = nil
    }

    /// Notes a "too old" answer for the update screen, and passes every error on.
    private func watchingForUpdates<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch ServerError.updateRequired(let message) {
            updateNeeded = message
            throw ServerError.updateRequired(message)
        }
    }

    /// 600,000 rounds of PBKDF2: off the main thread.
    private func deriveKeys(_ username: String, _ password: String) async throws -> E2E.PasswordKeys {
        try await Task.detached(priority: .userInitiated) {
            try E2E.deriveFromPassword(username: username, password: password)
        }.value
    }

    func signIn(server address: String, username typed: String, password: String) async throws {
        let username = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.contains("@") else { throw SignInError.emailAddress }
        let server = try Server(address, transport: transport)
        notice = nil
        lastServer = server.address
        reporter.use(server: server.address, token: nil)
        let keys = try await deriveKeys(username, password)
        let answer: SessionResponse
        do {
            answer = try await watchingForUpdates { try await server.login(username: username, authKey: keys.authKey) }
        } catch {
            reporter.report(.warn, "sign in failed", Reporter.fields(error))
            throw error
        }
        let identity: P256.KeyAgreement.PrivateKey
        do {
            identity = try E2E.unwrapIdentity(wrapKey: keys.wrapKey, wrapped: answer.wrappedPrivateKey)
        } catch {
            reporter.report(.error, "unlocking the private key failed")
            throw SignInError.cantUnlock
        }
        let account = Account(server: server.address, token: answer.token, user: answer.user,
                              publicKey: answer.publicKey, privateKey: identity.derRepresentation)
        try store.save(account)
        state = .signedIn(account)
    }

    struct Register: Encodable {
        let username: String
        let authKey: String
        let inviteCode: String?
        let publicKey: String
        let wrappedPrivateKey: String
    }

    struct SetRecovery: Encodable {
        let authKey: String
        let recoveryAuthKey: String
        let recoveryWrappedKey: String
    }

    /// A new account, as the web app makes one: keys made here from the
    /// password, a new key pair (the private key goes to the server only
    /// wrapped), then a recovery key, registered and shown once.
    func signUp(server address: String, username typed: String, password: String, inviteCode: String?) async throws {
        let username = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.contains("@") else { throw SignInError.emailAsUsername }
        guard password.count >= 8 else { throw SignInError.shortPassword }
        let server = try Server(address, transport: transport)
        notice = nil
        let keys = try await deriveKeys(username, password)
        let identity = try E2E.createIdentity(wrapKey: keys.wrapKey)
        let code = inviteCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = try await watchingForUpdates {
            try Server.decoder.decode(SessionResponse.self, from: await server.send("auth/register", method: "POST", json: Register(
                username: username, authKey: keys.authKey, inviteCode: code?.isEmpty == false ? code : nil,
                publicKey: identity.publicKey, wrappedPrivateKey: identity.wrappedPrivateKey)))
        }
        var account = Account(server: server.address, token: answer.token, user: answer.user,
                              publicKey: answer.publicKey, privateKey: identity.privateKey.derRepresentation)
        // The recovery key, while the password is at hand. If this fails the
        // account still works; the web app asks for one later (has_recovery_key).
        if let recoveryKey = try? await setUpRecovery(server, token: answer.token, keys: keys, wrapped: answer.wrappedPrivateKey) {
            account.user = Me(id: account.user.id, username: account.user.username, displayName: account.user.displayName,
                              role: account.user.role, hasRecoveryKey: true)
            recoveryKeyToShow = recoveryKey
        }
        try store.save(account)
        state = .signedIn(account)
    }

    /// Makes and registers a recovery key: a second copy of the private key,
    /// wrapped by it. Returns it, for showing once.
    private func setUpRecovery(_ server: Server, token: String, keys: E2E.PasswordKeys, wrapped: String) async throws -> String {
        let recoveryKey = E2E.newRecoveryKey()
        let recovery = try E2E.deriveFromRecoveryKey(recoveryKey)
        let copy = try E2E.wrapForRecovery(wrapKey: keys.wrapKey, wrapped: wrapped, recoveryWrapKey: recovery.wrapKey)
        _ = try await server.send("me/recovery", method: "PUT", token: token, json: SetRecovery(
            authKey: keys.authKey, recoveryAuthKey: recovery.authKey, recoveryWrappedKey: copy))
        return recoveryKey
    }

    // ---------- your account (SettingsScreen; the web's Security panel) ----------

    struct Security: Decodable, Equatable, Sendable {
        let recoverySetAt: Int64?
        let keyResetAt: Int64?
        let activeSessions: Int
    }

    /// When the recovery key was set, and how many devices are signed in.
    func security() async throws -> Security {
        let account = try signedIn()
        return try Server.decoder.decode(Security.self, from: await Server(account.server, transport: transport)
            .send("me/security", token: account.token))
    }

    /// Proves the password: the keys made from it, and the private key the
    /// server keeps wrapped under it (`/auth/unlock`).
    private func unlock(_ password: String) async throws -> (keys: E2E.PasswordKeys, wrapped: String) {
        let account = try signedIn()
        struct Unlock: Encodable { let authKey: String }
        struct Wrapped: Decodable { let wrappedPrivateKey: String }
        let keys = try await deriveKeys(account.user.username, password)
        let answer = try Server.decoder.decode(Wrapped.self, from: await Server(account.server, transport: transport)
            .send("auth/unlock", method: "POST", token: account.token, json: Unlock(authKey: keys.authKey)))
        return (keys, answer.wrappedPrivateKey)
    }

    /// The same key, locked under a new password. Other devices are signed
    /// out; returns how many.
    func changePassword(current: String, new: String) async throws -> Int {
        guard new.count >= 8 else { throw SignInError.shortPassword }
        let account = try signedIn()
        let old = try await unlock(current)
        let next = try await deriveKeys(account.user.username, new)
        let rewrapped = try E2E.rewrapIdentity(oldWrapKey: old.keys.wrapKey, wrapped: old.wrapped, newWrapKey: next.wrapKey)
        struct Change: Encodable { let authKey: String; let newAuthKey: String; let newWrappedPrivateKey: String }
        struct Ended: Decodable { let sessionsEnded: Int? }
        let answer = try Server.decoder.decode(Ended.self, from: await Server(account.server, transport: transport).send(
            "me/password", method: "POST", token: account.token,
            json: Change(authKey: old.keys.authKey, newAuthKey: next.authKey, newWrappedPrivateKey: rewrapped)))
        reporter.report(.info, "password changed")
        return answer.sessionsEnded ?? 0
    }

    /// A new recovery key (replacing any old one), shown once.
    func makeRecoveryKey(password: String) async throws {
        let account = try signedIn()
        let unlocked = try await unlock(password)
        recoveryKeyToShow = try await setUpRecovery(Server(account.server, transport: transport), token: account.token,
                                                    keys: unlocked.keys, wrapped: unlocked.wrapped)
        updateUser { Me(id: $0.id, username: $0.username, displayName: $0.displayName, role: $0.role, hasRecoveryKey: true, avatarId: $0.avatarId) }
        reporter.report(.info, "recovery key set")
    }

    /// Signs out every other device; returns how many.
    func endOtherSessions() async throws -> Int {
        let account = try signedIn()
        struct Ended: Decodable { let sessionsEnded: Int? }
        let answer = try Server.decoder.decode(Ended.self, from: await Server(account.server, transport: transport)
            .send("me/sessions/end-others", method: "POST", token: account.token))
        return answer.sessionsEnded ?? 0
    }

    /// A new username: the keys are made from it (it's the salt), so the
    /// password unlocks the key under the old name and locks it under the new.
    func changeUsername(to typed: String, password: String) async throws {
        let username = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.range(of: #"^[A-Za-z0-9_.]{3,20}$"#, options: .regularExpression) != nil else {
            throw SignInError.badUsername
        }
        let account = try signedIn()
        let old = try await unlock(password)
        let next = try await deriveKeys(username, password)
        let rewrapped = try E2E.rewrapIdentity(oldWrapKey: old.keys.wrapKey, wrapped: old.wrapped, newWrapKey: next.wrapKey)
        struct Rename: Encodable { let username: String; let authKey: String; let newAuthKey: String; let newWrappedPrivateKey: String }
        struct Renamed: Decodable { let username: String }
        let answer = try Server.decoder.decode(Renamed.self, from: await Server(account.server, transport: transport).send(
            "me/username", method: "POST", token: account.token,
            json: Rename(username: username, authKey: old.keys.authKey, newAuthKey: next.authKey, newWrappedPrivateKey: rewrapped)))
        updateUser { Me(id: $0.id, username: answer.username, displayName: $0.displayName, role: $0.role, hasRecoveryKey: $0.hasRecoveryKey, avatarId: $0.avatarId) }
        reporter.report(.info, "username changed")
    }

    private func signedIn() throws -> Account {
        guard let account else { throw ServerError.sessionEnded }
        return account
    }

    /// The signed-in person, changed here and in the Keychain.
    private func updateUser(_ change: (Me) -> Me) {
        guard var account else { return }
        account.user = change(account.user)
        try? store.save(account)
        state = .signedIn(account)
    }

    /// Ends the session on the server too, if it can be reached; this phone
    /// forgets it either way.
    func signOut() async {
        guard let account else { return }
        await reporter.flush()  // what's waiting goes as this account, before it's gone
        try? await Server(account.server, transport: transport).logout(token: account.token)
        endLocally(notice: nil)
    }

    /// Signing out leaves nothing of the account on the phone (CLAUDE.md,
    /// Security): the account and its key go from the Keychain; the chats, the
    /// socket, and open chats go with the signed-in screens (NapsackApp); the
    /// system never kept its requests (NetworkTransport). Pins stay, per
    /// account, as on the web: public keys, which open nothing.
    private func endLocally(notice: String?) {
        if notice != nil { reporter.report(.info, "session ended") }
        try? store.delete()
        self.notice = notice
        state = .signedOut
    }
}
