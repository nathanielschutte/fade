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
    case badSecret
    case mismatch
    case notYourUsername

    var errorDescription: String? {
        switch self {
        // People type their email here (plan X32); usernames can't hold an @.
        case .emailAddress: "That's an email address. Sign in with your napsack username instead."
        case .cantUnlock: "Couldn't unlock your keys. Check your password."
        case .emailAsUsername: "Pick a username, not an email address: letters, numbers, _ and . only."
        case .shortPassword: "Passwords need at least 8 characters."
        case .badUsername: "Usernames are 3 to 20 characters: letters, numbers, dots, and underscores."
        case .badSecret: "Recovery keys are 32 letters and numbers; reset codes are 16."
        case .mismatch: "The new passwords don't match."
        case .notYourUsername: "That isn't your username. Type it exactly to delete your account."
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
    /// Right after sign-up, napsack recommends a passkey (Passkeys.swift): the
    /// new account's keys, still in memory, so adding one doesn't ask for the
    /// password again. Never kept anywhere; gone once the person decides, or
    /// signs out.
    var passkeyOffer: PasskeyOffer?

    struct PasskeyOffer {
        let keys: E2E.PasswordKeys
        /// The private key as the server keeps it, wrapped by the password.
        let wrapped: String
    }

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
    /// keeps what's here. A session from another server than this build's
    /// (signed in before NAPSACK_SERVER_URL changed) signs out: the app talks
    /// to one server only (#39).
    func restore(server: String) async {
        lastServer = server
        guard let kept = try? store.load() else {
            state = .signedOut
            await checkVersion(server: server)
            return
        }
        state = .signedIn(kept)
        if let configured = try? Server(server, transport: transport).address, kept.server != configured {
            reporter.report(.info, "session from another server signed out")
            await signOut()  // ended there too, if it can be reached
            notice = "This app now uses another server. Sign in again."
            await checkVersion(server: server)
            return
        }
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
        let inviteToken: String?
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
    /// With a friend's link (`inviteToken`, Links.swift) no invite code is
    /// needed, and the new account starts out friends with them.
    /// `offerPasskey`: passkeys work with this server, so a passkey is
    /// recommended right after (Nate, 2026-11-03: sign-up starts with a password).
    func signUp(server address: String, username typed: String, password: String, inviteCode: String?, inviteToken: String? = nil,
                offerPasskey: Bool = false) async throws {
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
                username: username, authKey: keys.authKey, inviteCode: inviteToken == nil && code?.isEmpty == false ? code : nil,
                inviteToken: inviteToken, publicKey: identity.publicKey, wrappedPrivateKey: identity.wrappedPrivateKey)))
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
        if inviteToken != nil { FriendLinks.shared.pending = nil }  // used: they're friends already
        if offerPasskey { passkeyOffer = PasskeyOffer(keys: keys, wrapped: answer.wrappedPrivateKey) }
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

    // ---------- forgot password (signed out; the web's recover form) ----------

    enum Secret: Equatable { case recoveryKey, resetCode }

    /// A recovery key is 32 letters and numbers; an Admin's reset code, 16 (spaces and dashes don't count).
    static func secretKind(_ text: String) -> Secret? {
        switch text.filter({ !$0.isWhitespace && $0 != "-" }).count {
        case 32: .recoveryKey
        case 16: .resetCode
        default: nil
        }
    }

    /// Back in after a forgotten password. With the recovery key: the same key,
    /// so every message stays readable. With an Admin's reset code: a new key
    /// (messages from before can't be read, and friends see a new safety code),
    /// then a new recovery key, shown once.
    func recover(server address: String, username typed: String, secret: String, newPassword: String) async throws {
        let username = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = Self.secretKind(secret) else { throw SignInError.badSecret }
        guard newPassword.count >= 8 else { throw SignInError.shortPassword }
        let server = try Server(address, transport: transport)
        notice = nil
        lastServer = server.address
        let next = try await deriveKeys(username, newPassword)
        let answer: SessionResponse
        let privateKey: Data
        switch kind {
        case .recoveryKey:
            let recovery = try E2E.deriveFromRecoveryKey(secret)
            struct Start: Encodable { let username: String; let recoveryAuthKey: String }
            struct Started: Decodable { let recoveryWrappedKey: String }
            let started = try await watchingForUpdates {
                try Server.decoder.decode(Started.self, from: await server.send("auth/recover/start", method: "POST",
                                                                                json: Start(username: username, recoveryAuthKey: recovery.authKey)))
            }
            let got = try E2E.recoverIdentity(recoveryWrapKey: recovery.wrapKey, recoveryWrapped: started.recoveryWrappedKey, newWrapKey: next.wrapKey)
            struct Finish: Encodable { let username: String; let recoveryAuthKey: String; let newAuthKey: String; let newWrappedPrivateKey: String }
            answer = try Server.decoder.decode(SessionResponse.self, from: await server.send("auth/recover/finish", method: "POST", json: Finish(
                username: username, recoveryAuthKey: recovery.authKey, newAuthKey: next.authKey, newWrappedPrivateKey: got.wrappedPrivateKey)))
            privateKey = got.privateKey.derRepresentation
            reporter.use(server: server.address, token: answer.token)
            reporter.report(.info, "recovered with recovery key")
        case .resetCode:
            let identity = try E2E.createIdentity(wrapKey: next.wrapKey)
            struct Reset: Encodable { let username: String; let code: String; let newAuthKey: String; let publicKey: String; let wrappedPrivateKey: String }
            answer = try await watchingForUpdates {
                try Server.decoder.decode(SessionResponse.self, from: await server.send("auth/reset", method: "POST", json: Reset(
                    username: username, code: secret.filter { !$0.isWhitespace }, newAuthKey: next.authKey,
                    publicKey: identity.publicKey, wrappedPrivateKey: identity.wrappedPrivateKey)))
            }
            privateKey = identity.privateKey.derRepresentation
            recoveryKeyToShow = try? await setUpRecovery(server, token: answer.token, keys: next, wrapped: answer.wrappedPrivateKey)
            reporter.use(server: server.address, token: answer.token)
            reporter.report(.info, "reset with code")
        }
        var account = Account(server: server.address, token: answer.token, user: answer.user, publicKey: answer.publicKey, privateKey: privateKey)
        if recoveryKeyToShow != nil {
            account.user = Me(id: account.user.id, username: account.user.username, displayName: account.user.displayName,
                              role: account.user.role, hasRecoveryKey: true, avatarId: account.user.avatarId)
        }
        try store.save(account)
        state = .signedIn(account)
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

    /// Deletes the account for good (the server's deletion.rs): the password,
    /// proven by its key, and the username typed again. Then nothing of it
    /// stays on the phone either, and the sign-in screen says it's done.
    func deleteAccount(password: String, typedUsername: String) async throws {
        let account = try signedIn()
        guard typedUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == account.user.username.lowercased() else {
            throw SignInError.notYourUsername
        }
        let keys = try await deriveKeys(account.user.username, password)
        struct Delete: Encodable { let authKey: String; let username: String }
        _ = try await Server(account.server, transport: transport).send(
            "me/delete", method: "POST", token: account.token,
            json: Delete(authKey: keys.authKey, username: typedUsername.trimmingCharacters(in: .whitespacesAndNewlines)))
        reporter.report(.info, "account deleted")
        await reporter.flush()
        endLocally(notice: "Your account was deleted. Everything of yours is gone from napsack.")
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

    // ---------- passkeys (Passkeys.swift; docs/design/passkeys.md) ----------

    /// The most an account has at once (the server's passkeys.rs, MAX_PASSKEYS).
    static let maxPasskeys = 10

    struct Passkey: Decodable, Identifiable, Equatable, Sendable {
        let id: Int64
        /// WebAuthn's id for it (base64url): how the phone's passkeys know it.
        let credentialId: String
        /// Where it's kept ("iCloud Keychain"), when its maker is a known one.
        let provider: String?
        let createdAt: Int64
        let lastUsedAt: Int64?
    }

    struct PasskeyList: Decodable, Equatable, Sendable {
        let passkeys: [Passkey]
        /// The site they belong to (napsack.io).
        let rpId: String
    }

    /// Signs in with a passkey: Face ID, then the server checks the passkey's
    /// signature over its challenge and hands back the passkey's own copy of
    /// the private key, which only that passkey's PRF secret opens. Kept in
    /// the Keychain as a password sign-in is. A passkey that can't give the
    /// secret signs nobody in: there'd be no key to read anything with.
    func signInWithPasskey(server address: String, using authenticator: any PasskeyAuthenticator) async throws {
        let server = try Server(address, transport: transport)
        notice = nil
        lastServer = server.address
        reporter.use(server: server.address, token: nil)
        struct Options: Decodable { let challenge: String; let rpId: String }
        let options = try await watchingForUpdates {
            try Server.decoder.decode(Options.self, from: await server.send("auth/passkey/options", method: "POST"))
        }
        guard authenticator.works(for: options.rpId), let challenge = Passkeys.data(b64url: options.challenge) else {
            throw PasskeyError.unavailable
        }
        let signed = try await authenticator.sign(rpID: options.rpId, challenge: challenge, allowed: [], prfInput: E2E.passkeyPrfInput())
        guard let secret = signed.prfSecret, let wrapKey = try? E2E.deriveFromPasskey(secret) else {
            reporter.report(.warn, "passkey gave no PRF secret")
            throw PasskeyError.cantUnlock  // and nothing's sent: a session with no key is no use
        }
        struct SignIn: Encodable { let credentialId, clientDataJson, authenticatorData, signature: String }
        struct Answer: Decodable { let token: String; let user: Me; let publicKey: String; let passkeyWrappedKey: String }
        let answer: Answer
        do {
            answer = try await watchingForUpdates {
                try Server.decoder.decode(Answer.self, from: await server.send("auth/passkey", method: "POST", json: SignIn(
                    credentialId: Passkeys.b64url(signed.credentialID), clientDataJson: Passkeys.b64url(signed.clientDataJSON),
                    authenticatorData: Passkeys.b64url(signed.authenticatorData), signature: Passkeys.b64url(signed.signature))))
            }
        } catch {
            reporter.report(.warn, "passkey sign-in failed", Reporter.fields(error))
            // One the server doesn't know (removed elsewhere, or never added):
            // the phone's told, so its sheet stops offering it.
            if Self.unknownPasskey(error) { await authenticator.forget(rpID: options.rpId, credentialID: signed.credentialID) }
            throw error
        }
        // Its copy has to open, and be the account's own key.
        guard let identity = try? E2E.unwrapWithPasskey(passkeyWrapKey: wrapKey, wrapped: answer.passkeyWrappedKey),
              let publicKey = try? P256.KeyAgreement.PublicKey(derRepresentation: E2E.fromB64(answer.publicKey)),
              identity.publicKey.rawRepresentation == publicKey.rawRepresentation
        else {
            reporter.report(.error, "unlocking with a passkey failed")
            try? await server.logout(token: answer.token)  // no key, no use: ended at once
            throw PasskeyError.cantUnlock
        }
        let account = Account(server: server.address, token: answer.token, user: answer.user,
                              publicKey: answer.publicKey, privateKey: identity.derRepresentation)
        try store.save(account)
        state = .signedIn(account)
        reporter.report(.info, "signed in with a passkey")
    }

    /// Yours, oldest first, and the site they belong to.
    func passkeys() async throws -> PasskeyList {
        let account = try signedIn()
        return try Server.decoder.decode(PasskeyList.self, from: await Server(account.server, transport: transport)
            .send("me/passkeys", token: account.token))
    }

    /// Adds a passkey from Security: the password first (`/auth/unlock`, as
    /// for a recovery key; a wrong one never gets as far as Face ID).
    func addPasskey(password: String, using authenticator: any PasskeyAuthenticator) async throws -> Passkey {
        let unlocked = try await unlock(password)
        return try await addPasskey(keys: unlocked.keys, wrapped: unlocked.wrapped, using: authenticator)
    }

    /// The passkey recommended after sign-up, with the keys sign-up kept.
    func addOfferedPasskey(using authenticator: any PasskeyAuthenticator) async throws -> Passkey {
        // Already decided ("Not now"): nothing to add, and nothing to say.
        guard let offer = passkeyOffer else { throw PasskeyError.canceled }
        let added = try await addPasskey(keys: offer.keys, wrapped: offer.wrapped, using: authenticator)
        passkeyOffer = nil
        return added
    }

    /// The phone makes a passkey for the account (Face ID), its PRF secret
    /// wraps a copy of the private key, and the server checks the new passkey
    /// and keeps it with that copy. Not every passkey gives the secret as it's
    /// made, so the new one alone is asked once more. One that can't give it
    /// isn't added, and the phone is told to drop it.
    private func addPasskey(keys: E2E.PasswordKeys, wrapped: String, using authenticator: any PasskeyAuthenticator) async throws -> Passkey {
        let account = try signedIn()
        let server = try Server(account.server, transport: transport)
        struct Options: Decodable { let challenge: String; let rpId: String; let userId: String; let userName: String; let exclude: [String] }
        let options = try Server.decoder.decode(Options.self, from: await server.send("me/passkeys/options", method: "POST", token: account.token))
        guard authenticator.works(for: options.rpId), let challenge = Passkeys.data(b64url: options.challenge),
              let userID = Passkeys.data(b64url: options.userId) else { throw PasskeyError.unavailable }
        let prfInput = E2E.passkeyPrfInput()
        let made = try await authenticator.create(rpID: options.rpId, challenge: challenge, userName: options.userName, userID: userID,
                                                  excluding: options.exclude.compactMap { Passkeys.data(b64url: $0) }, prfInput: prfInput)
        do {
            var secret = made.prfSecret
            if secret == nil, made.prfSupported != false {
                // Nobody checks this signature: only the secret is wanted, and only the new passkey's.
                let unchecked = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let signed = try await authenticator.sign(rpID: options.rpId, challenge: unchecked, allowed: [made.credentialID], prfInput: prfInput)
                secret = signed.credentialID == made.credentialID ? signed.prfSecret : nil
            }
            guard let secret, let passkeyKey = try? E2E.deriveFromPasskey(secret) else {
                reporter.report(.warn, "passkey refused: no PRF secret")
                throw PasskeyError.cantUnlock
            }
            let copy = try E2E.wrapForPasskey(wrapKey: keys.wrapKey, wrapped: wrapped, passkeyWrapKey: passkeyKey)
            struct Add: Encodable { let authKey, clientDataJson, attestationObject, wrappedKey: String }
            struct Added: Decodable { let id: Int64; let provider: String?; let createdAt: Int64 }
            let added = try Server.decoder.decode(Added.self, from: await server.send("me/passkeys", method: "POST", token: account.token, json: Add(
                authKey: keys.authKey, clientDataJson: Passkeys.b64url(made.clientDataJSON),
                attestationObject: Passkeys.b64url(made.attestationObject), wrappedKey: copy)))
            reporter.report(.info, "passkey added")
            return Passkey(id: added.id, credentialId: Passkeys.b64url(made.credentialID), provider: added.provider,
                           createdAt: added.createdAt, lastUsedAt: nil)
        } catch {
            if Self.surelyNotKept(error) { await authenticator.forget(rpID: options.rpId, credentialID: made.credentialID) }
            throw error
        }
    }

    /// The server's answer for a passkey it doesn't know, as it was removed or
    /// never added (passkeys.rs, `sign_in`). Only this answer: a passkey it
    /// knows whose signature didn't check out is still the person's.
    static func unknownPasskey(_ error: any Error) -> Bool {
        guard case ServerError.refused(let words, status: 400) = error else { return false }
        return words.contains("isn't set up for napsack any more")
    }

    /// Whether a passkey just made surely isn't on the server after this:
    /// anything but a lost connection (it may have arrived) or "already added".
    static func surelyNotKept(_ error: any Error) -> Bool {
        guard let error = error as? ServerError else { return true }
        if error.retryable { return false }
        if case .refused(_, status: 409) = error { return false }
        return true
    }

    /// It stops working, everywhere (the server marks it ended); the phone's
    /// password managers are told so they can drop it too.
    func removePasskey(_ passkey: Passkey, rpID: String, using authenticator: any PasskeyAuthenticator) async throws {
        let account = try signedIn()
        do {
            _ = try await Server(account.server, transport: transport)
                .send("me/passkeys/\(passkey.id)/remove", method: "POST", token: account.token)
            reporter.report(.info, "passkey removed")
        } catch ServerError.refused(_, status: 404) {
            // Removed already, from another device: just as good.
        }
        if let credential = Passkeys.data(b64url: passkey.credentialId) {
            await authenticator.forget(rpID: rpID, credentialID: credential)
        }
    }

    private func signedIn() throws -> Account {
        guard let account else { throw ServerError.sessionEnded }
        return account
    }

    /// Friends see when you're active or typing, and you theirs (both must share).
    func setShareActivity(_ on: Bool) async throws {
        let account = try signedIn()
        struct Settings: Encodable { let shareActivity: Bool }
        _ = try await Server(account.server, transport: transport).send("me/settings", method: "PUT", token: account.token,
                                                                        json: Settings(shareActivity: on))
        updateUser { var me = $0; me.shareActivity = on; return me }
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
    /// socket, and open chats go with the signed-in screens (NapsackApp); its
    /// notifications leave Notification Center and the icon; the
    /// system never kept its requests (NetworkTransport). Pins stay, per
    /// account, as on the web: public keys, which open nothing.
    private func endLocally(notice: String?) {
        if notice != nil { reporter.report(.info, "session ended") }
        try? store.delete()
        passkeyOffer = nil  // the new account's keys, if it was still offered
        UserDefaults.standard.removeObject(forKey: ChatList.dismissedAnnouncementKey)  // nothing of theirs stays
        ResponseCache.wipeAll()  // the kept chats (still encrypted, but theirs)
        Notifications.shared.signedOut()  // delivered ones and the badge; the server stops with the session
        AppLock.shared.signedOut()  // the lock was this account's choice
        self.notice = notice
        state = .signedOut
    }
}
