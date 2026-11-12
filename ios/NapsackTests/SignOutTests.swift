import CryptoKit
import Foundation
import Testing
@testable import Napsack

/// A phone of its own for a test (PhoneData): its own Keychain service,
/// settings suite, kept answers, and temporary folder, so signing out here
/// never touches the app's own, or another test's.
@MainActor struct TestPhone {
    let phone: PhoneData
    let folder: URL

    init() throws {
        let id = UUID().uuidString
        folder = FileManager.default.temporaryDirectory.appending(path: "napsack-phone-test-\(id)", directoryHint: .isDirectory)
        phone = PhoneData(keychainService: "napsack.test.\(id)", defaults: "napsack.test.\(id)", cache: folder.appending(path: "cache"),
                          temporary: folder.appending(path: "tmp"), systemCaches: false)
        try FileManager.default.createDirectory(at: phone.temporary, withIntermediateDirectories: true)
    }

    var store: KeychainAccountStore { KeychainAccountStore(phone: phone) }
    func pins(_ server: String) -> KeychainPinStore { KeychainPinStore(server: server, service: phone.keychainService) }
    var settings: UserDefaults { UserDefaults(suiteName: phone.defaults)! }

    /// What a signed-in account leaves on a phone: its session, its pins, the
    /// settings, kept chats and pictures, a text not yet sent (sealed, its key
    /// in the Keychain), and a video opened a moment ago.
    func fill(_ account: Account) throws {
        try store.save(account)
        leftovers(of: account.user.id, server: account.server)
    }

    /// The same, without a session: what a phone signed out by an older napsack held.
    /// (Pins for `id`, of someone else's key.)
    func leftovers(of id: Int64, server: String) {
        var pinned = Pins()
        _ = pinned.see(id + 1, "someone else's public key")
        try? pins(server).save(pinned, account: id)
        settings.set(true, forKey: AppLock.enabledKey)
        settings.set(42, forKey: ChatList.dismissedAnnouncementKey)
        let cache = ResponseCache(account: id, root: phone.cache)
        cache.write(Data("[{\"id\":8}]".utf8), "friends")
        cache.pictures.write(Data([1, 2, 3]), "users-8-avatar-1", replacing: "users-8-avatar-", limit: 10)
        let unsent = UnsentTexts(account: id, cache: cache, keychainService: phone.keychainService)
        unsent.load()
        unsent.keep([UnsentTexts.Text(id: "u\(id)", text: "a text not yet sent", replyTo: nil)], for: "d8")
        ResponseCache.settle()
        try? Data("a video".utf8).write(to: phone.temporary.appending(path: "napsack-\(UUID().uuidString).mp4"))
    }

    func clean() {
        phone.forget()
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: phone.defaults)
    }
}

/// Signing out, a session the server ended, and deleting the account leave
/// nothing of it on the phone (CLAUDE.md, Security; PhoneData): no Keychain
/// item (the session and the pins too: Nate, 2026-11-06), no settings, no
/// kept answers or pictures, no temporary files. Signing in clears what any
/// earlier account left before anything is used, and so does opening the
/// app. Each test has a phone of its own (TestPhone).
@MainActor @Suite struct SignOutTests {
    let s = try! SessionTests()
    let phone = try! TestPhone()

    /// A server that knows the kept session, and takes signing out and deleting.
    func server() -> StubServer {
        let meAnswer = json(s.me)
        return StubServer { request in
            request.url!.path == "/api/me" ? (200, meAnswer) : (200, json(["ok": true]))
        }
    }

    func signedIn(_ transport: StubServer, notifications: Notifications? = nil) async throws -> (Session, Account) {
        let account = try s.keptAccount()
        try phone.fill(account)
        let session = Session(transport: transport, store: phone.store, reporter: Reporter(transport: transport), notifications: notifications)
        await session.restore(server: "https://napsack.test")
        #expect(session.account == account)
        let kept = phone.phone.kept()
        #expect(kept.contains("keychain: session") && kept.contains { $0.hasPrefix("keychain: pins:") }, "there was something to forget")
        #expect(kept.contains("setting: \(AppLock.enabledKey)") && kept.contains { $0.contains("/cache/") } && kept.contains { $0.contains("/tmp/") })
        #expect(kept.contains("keychain: \(UnsentTexts.keyName(account.user.id))") && kept.contains { $0.contains("/unsent/") }, "a text not yet sent")
        return (session, account)
    }

    @Test func signingOutLeavesNothing() async throws {
        defer { phone.clean() }
        let system = RecordedNotifications()
        let (session, _) = try await signedIn(server(), notifications: Notifications(system: system, lock: AppLock(enabled: false)))
        session.recoveryKeyToShow = "a new account's recovery key"
        await session.signOut()
        #expect(session.state == .signedOut && session.account == nil)
        #expect(phone.phone.kept() == [])
        #expect(session.recoveryKeyToShow == nil && session.passkeyOffer == nil)
        #expect(system.cleared > 0 && system.badges.last == 0 && system.unregistered == 1)  // Notification Center, the icon
    }

    @Test func anEndedSessionLeavesNothing() async throws {
        defer { phone.clean() }
        let account = try s.keptAccount()
        try phone.fill(account)
        let session = Session(transport: StubServer { _ in (401, json(["error": "Sign in first."])) }, store: phone.store)
        await session.restore(server: "https://napsack.test")
        #expect(session.state == .signedOut && session.notice == "Your session ended. Sign in again.")
        #expect(phone.phone.kept() == [])
    }

    @Test func anEndedSessionNoticedLaterLeavesNothing() async throws {
        defer { phone.clean() }
        let (session, _) = try await signedIn(server())
        session.noticed(ServerError.sessionEnded)  // any screen's request, answered 401
        #expect(session.state == .signedOut)
        #expect(phone.phone.kept() == [])
    }

    @Test func deletingTheAccountLeavesNothing() async throws {
        defer { phone.clean() }
        let transport = server()
        let (session, account) = try await signedIn(transport)
        try await session.deleteAccount(password: s.password["password"] as! String, typedUsername: account.user.username)
        #expect(await transport.requests.contains { $0.url?.path == "/api/me/delete" })
        #expect(session.state == .signedOut && session.notice?.contains("deleted") == true)
        #expect(phone.phone.kept() == [])
    }

    /// Another account's leftovers (an older napsack kept pins at sign-out)
    /// are gone before the next account uses anything: it starts with its
    /// session alone, and no pins.
    @Test func aNewSessionStartsFromNothing() async throws {
        defer { phone.clean() }
        phone.leftovers(of: 3, server: "https://napsack.test")
        #expect(!phone.phone.kept().isEmpty)
        let session = Session(transport: s.vectorServer(), store: phone.store)
        try await session.signIn(server: "https://napsack.test", username: s.password["username"] as! String, password: s.password["password"] as! String)
        let account = try #require(session.account)
        #expect(account.user.id == 7)
        #expect(phone.phone.kept() == ["keychain: session"])
        #expect(phone.pins(account.server).load(account: 3) == Pins())
        #expect(phone.pins(account.server).load(account: 7) == Pins())
        #expect(ResponseCache(account: 3, root: phone.phone.cache).read("friends") == nil)
    }

    /// Opening the app: signed out, what an older napsack left goes; signed
    /// in, what another account left goes, and this one's stays.
    @Test func leftoversGoAtLaunch() throws {
        defer { phone.clean() }
        phone.leftovers(of: 3, server: "https://napsack.test")
        Session.forgetLeftovers(store: phone.store)
        #expect(phone.phone.kept() == [])

        let account = try s.keptAccount()
        try phone.fill(account)
        phone.leftovers(of: 3, server: "https://napsack.test")
        Session.forgetLeftovers(store: phone.store)
        let keychain = phone.phone.kept().filter { $0.hasPrefix("keychain: ") }
        #expect(keychain == ["keychain: \(phone.pins(account.server).key(account.user.id))", "keychain: session",
                             "keychain: \(UnsentTexts.keyName(account.user.id))"])
        #expect(try phone.store.load() == account)
        #expect(ResponseCache(account: 3, root: phone.phone.cache).read("friends") == nil)
        #expect(ResponseCache(account: account.user.id, root: phone.phone.cache).read("friends") != nil)
        // This account's unsent texts can still be read: their key stayed.
        let unsent = UnsentTexts(account: account.user.id, cache: ResponseCache(account: account.user.id, root: phone.phone.cache),
                                 keychainService: phone.phone.keychainService)
        #expect(unsent.load() && unsent.chats["d8"]?.map(\.text) == ["a text not yet sent"])
    }

    /// A load that finishes after signing out (its answer was on the way)
    /// keeps nothing: not its pins, not its answers, even through a store or
    /// cache made only then for the screens of before.
    @Test func nothingFromBeforeASignOutIsKeptAfterIt() throws {
        defer { phone.clean() }
        let pins = phone.pins("https://napsack.test")
        let before = Keychain.wipes(service: phone.phone.keychainService)
        let cacheBefore = ResponseCache.generation(root: phone.phone.cache)
        phone.phone.forget()  // signed out
        var pinned = Pins()
        _ = pinned.see(8, "a friend's public key")
        try pins.save(pinned, account: 7)
        try KeychainPinStore(server: "https://napsack.test", service: phone.phone.keychainService, after: before).save(pinned, account: 7)
        ResponseCache(account: 7, root: phone.phone.cache, after: cacheBefore).write(Data("[]".utf8), "friends")
        ResponseCache.settle()
        #expect(phone.phone.kept() == [])
        // A new session's store keeps them, as ever.
        try phone.pins("https://napsack.test").save(pinned, account: 7)
        #expect(phone.pins("https://napsack.test").load(account: 7) == pinned)
    }

    /// The app forgets its own places: every item under its Keychain service,
    /// its settings, its kept answers, the temporary folder, and the system's
    /// shared caches.
    @Test func theAppForgetsItsOwnPlaces() {
        let app = PhoneData.phone
        #expect(app.keychainService == Keychain.service && app.defaults == Bundle.main.bundleIdentifier)
        #expect(app.cache == ResponseCache.root && app.temporary == FileManager.default.temporaryDirectory && app.systemCaches)
        #expect(KeychainAccountStore().phone == app)
        #expect(KeychainPinStore(server: "https://napsack.test").service == Keychain.service)
    }
}
