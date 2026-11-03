import Foundation
import NapsackCrypto
import SwiftUI
import Testing
import UIKit
import UserNotifications
@testable import Napsack

/// A stand-in for the phone's notifications: what the app asked of it.
@MainActor final class RecordedNotifications: NotificationSystem {
    var status: UNAuthorizationStatus = .denied
    var allows = false
    /// Runs while the person is being asked (to sign out meanwhile, say).
    var whileAsking: () -> Void = {}
    private(set) var asked = 0, registered = 0, unregistered = 0, cleared = 0
    /// Every number put on the icon, in order.
    private(set) var badges: [Int] = []

    func authorization() async -> UNAuthorizationStatus { status }
    func askToNotify() async -> Bool { asked += 1; whileAsking(); return allows }
    func register() { registered += 1 }
    func unregister() { unregistered += 1 }
    func clearDelivered() { cleared += 1 }
    func setBadge(_ count: Int) { badges.append(count) }
}

/// Where a tapped notification goes and when, the icon's number, asking, and signing out.
@MainActor struct NotificationsTests {
    let system = RecordedNotifications()
    let account = Account(server: "http://127.0.0.1:9", token: "session", user: Me(id: 1, username: "ana", displayName: nil, role: "user", hasRecoveryKey: true),
                          publicKey: "", privateKey: Data())

    @Test func theServersUrlsOpenTheirChat() {
        #expect(Notifications.Destination(url: "/#chat=7") == .chat(.friend(7)))
        #expect(Notifications.Destination(url: "/#group=3") == .chat(.group(3)))
        #expect(Notifications.Destination(url: "/#friends") == .friends)
        for nothing in ["", "/", "/#", "/#chat=", "/#chat=abc", "/#chat=-1", "/#chat=0", "/#elsewhere=2", "chat=7"] {
            #expect(Notifications.Destination(url: nothing) == nil, "\(nothing)")
        }
    }

    @Test func tokensGoAsLowercaseHex() {
        #expect(Notifications.hex(Data([0x00, 0x0f, 0xab, 0xff])) == "000fabff")
        #expect(Notifications.hex(Data(repeating: 0xcd, count: 32)).count == 64)
    }

    /// Xcode builds (these tests) use Apple's sandbox; Release builds production.
    @Test func debugBuildsAreTheSandboxs() {
        #expect(Notifications.environment == "sandbox")
    }

    @Test func aTapOpensItsChatAtOnceWhenNapsackIsntLocked() {
        let notifications = Notifications(system: system, lock: AppLock(enabled: false))
        notifications.tap(url: "/#chat=7")
        #expect(notifications.opened == .chat(.friend(7)))
        notifications.opened = nil  // the chat list took it
        #expect(notifications.opened == nil)
        notifications.tap(url: "/#elsewhere")
        #expect(notifications.opened == nil, "not one of ours")
    }

    /// Locked, the chat waits: it's read only once someone who can see it unlocks.
    @Test func aTapWaitsWhileNapsackIsLocked() {
        let lock = AppLock(enabled: true)  // locked as the app opens: a cold launch
        let notifications = Notifications(system: system, lock: lock)
        notifications.tap(url: "/#group=3")
        #expect(notifications.opened == nil)
        lock.signedOut()  // the lock coming off (Face ID itself can't run in a test)
        #expect(notifications.opened == .chat(.group(3)))
    }

    /// Back after a minute away, the lock comes down before the tap is heard,
    /// whichever iOS reports first: the tap, or the app coming back.
    @Test func aTapAfterAMinuteAwayLocksFirst() {
        let lock = AppLock(enabled: true, locked: false)
        lock.left(at: .now.addingTimeInterval(-120))
        let notifications = Notifications(system: system, lock: lock)
        notifications.tap(url: "/#chat=5")
        #expect(lock.locked)
        #expect(notifications.opened == nil)
        lock.returned()  // the scene's own return, after: nothing changes
        #expect(lock.locked)

        let soon = AppLock(enabled: true, locked: false)
        soon.left(at: .now.addingTimeInterval(-10))
        let quick = Notifications(system: system, lock: soon)
        quick.tap(url: "/#chat=5")
        #expect(!soon.locked)
        #expect(quick.opened == .chat(.friend(5)))
    }

    /// The icon counts chats, not messages, and not muted or hidden ones (as apns.rs).
    @Test func theBadgeCountsTheChatsWithADot() {
        func row(_ id: Int64, _ waiting: ChatRow.Waiting?, muted: Bool = false, hidden: Bool = false) -> ChatRow {
            ChatRow(kind: .friend(id), name: "x", preview: "", waiting: waiting, time: nil, favorite: false, muted: muted, hidden: hidden)
        }
        let rows = [row(1, .text), row(2, .snap), row(3, nil), row(4, .text, muted: true), row(5, .snap, hidden: true),
                    ChatRow(kind: .group(6), name: "g", preview: "", waiting: .text, time: nil, favorite: true, muted: false, hidden: false)]
        #expect(Notifications.badge(rows) == 3)
        #expect(Notifications.badge([]) == 0)
    }

    @Test func asksOnceAndRegistersOnlyWhenAllowed() async {
        let notifications = Notifications(system: system, lock: AppLock(enabled: false))
        system.status = .notDetermined
        await notifications.start(for: account)
        #expect(system.asked == 1 && system.registered == 0, "said no")
        system.allows = true
        await notifications.start(for: account)
        #expect(system.asked == 2 && system.registered == 1, "said yes")
        system.status = .denied
        await notifications.start(for: account)
        #expect(system.asked == 2 && system.registered == 1, "turned off in Settings: not asked again")
        system.status = .authorized
        await notifications.start(for: account)
        #expect(system.asked == 2 && system.registered == 2, "every launch registers")
    }

    /// The question waits on the person; signed out by the time they answer, nothing registers.
    @Test func signingOutWhileAskedRegistersNothing() async {
        let notifications = Notifications(system: system, lock: AppLock(enabled: false))
        system.status = .notDetermined
        system.allows = true
        system.whileAsking = { notifications.signedOut() }
        await notifications.start(for: account)
        #expect(system.asked == 1 && system.registered == 0)
    }

    /// Nothing of the account stays: not a tap waiting, not in Notification
    /// Center, not on the icon, and Apple stops delivering until the next sign-in.
    @Test func signingOutLeavesNothing() async {
        let notifications = Notifications(system: system, lock: AppLock(enabled: false))
        notifications.tap(url: "/#chat=7")
        await notifications.received(token: Data(repeating: 1, count: 32))  // no account yet: nothing goes to a server
        #expect(notifications.deviceToken != nil)
        notifications.signedOut()
        #expect(notifications.opened == nil)
        #expect(notifications.deviceToken == nil)
        #expect(system.cleared == 1 && system.badges == [0] && system.unregistered == 1)
    }
}

/// Registering against a real server (a local one): accepted, and again on
/// the next launch without fuss. Runs only with NAPSACK_TEST_SERVER set.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveNotificationsTests {
    let live = LiveChatListTests()

    @Test func theTokenRegistersForTheSession() async throws {
        let phone = Session(store: MemoryStore(), reporter: Reporter())
        let name = "push_\(UUID().uuidString.prefix(6).lowercased())"
        try await phone.signUp(server: live.address, username: name, password: "correct horse battery", inviteCode: live.invite)
        let account = try #require(phone.account)
        let server = try Server(account.server)
        let token = Notifications.hex(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        try await server.registerAPNs(token: token, environment: "sandbox", auth: account.token)
        try await server.registerAPNs(token: token, environment: "sandbox", auth: account.token)
        await #expect(throws: (any Error).self) {
            try await server.registerAPNs(token: "not hex", environment: "sandbox", auth: account.token)
        }
        await #expect(throws: (any Error).self) {
            try await server.registerAPNs(token: token, environment: "https://elsewhere.example", auth: account.token)
        }
    }

    /// A notification tapped while signed out was for whoever was here before:
    /// signing in fresh doesn't open it.
    @Test func aTapFromBeforeSigningInIsDropped() async throws {
        let notifications = Notifications(system: RecordedNotifications(), lock: AppLock(enabled: false))
        let phone = Session(store: MemoryStore(), reporter: Reporter(), notifications: notifications)
        await phone.restore(server: live.address)
        #expect(phone.state == .signedOut)
        notifications.tap(url: "/#chat=424242")
        #expect(notifications.opened == .chat(.friend(424242)), "waiting, until someone signs in")
        let name = "tap_\(UUID().uuidString.prefix(6).lowercased())"
        try await phone.signUp(server: live.address, username: name, password: "correct horse battery", inviteCode: live.invite)
        #expect(notifications.opened == nil)
    }
}

/// Tapping notifications, through the real chat list in a window, against a
/// real server: at a cold launch (the tap before the list exists) and warm,
/// for a direct chat, a group, and a friend request. Each chat opens and is
/// read, and the icon's number follows as the phone reads them. Runs only
/// with NAPSACK_TEST_SERVER set.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(2)))
struct LiveNotificationTapTests {
    let live = LiveChatListTests()
    struct Text: Encodable { let ciphertext: String; let format: Int }
    struct GroupText: Encodable { let text: String }

    @Test func aTapOpensItsChatAndReadsIt() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben"), cal = try await live.newAccount("cal")
        try await LiveGroupsTests().befriend(ana, ben)
        let server = try Server(live.address)
        let key = try E2E.pairKey(mine: ana.identity(), theirs: ben.publicKey, myId: ana.user.id, theirId: ben.user.id)
        let sealed = try E2E.encryptText2(key, "come look", replyTo: nil, sender: ana.user.id, recipient: ben.user.id)
        _ = try await server.send("chats/\(ben.user.id)/messages", method: "POST", token: ana.token, json: Text(ciphertext: sealed, format: 2))
        let group = try await GroupModel.create(name: "Tapped", members: [ben.user.id], account: ana)
        _ = try await server.send("groups/\(group)/messages", method: "POST", token: ana.token, json: GroupText(text: "in here too"))
        _ = try await FriendsModel(account: cal).add(ben.user.username)

        // Ben's phone, signed in. Pins from an earlier run (ids repeat on a fresh server) mustn't count.
        try KeychainPinStore(server: ben.server).save(Pins(), account: ben.user.id)
        let session = Session(store: MemoryStore(ben), reporter: Reporter())
        await session.restore(server: live.address)
        let system = RecordedNotifications()
        let notifications = Notifications(system: system, lock: AppLock(enabled: false))

        // A cold launch: the tap comes before the chat list is there.
        notifications.tap(url: "/#chat=\(ana.user.id)")
        let window = try Self.show(ChatListScreen(account: ben, notifications: notifications).environment(session))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await until("Ana's text is read") { try await self.readByBen(ana: ana, ben: ben) }
        #expect(notifications.opened == nil)
        // Read here, the icon drops to the one chat still waiting: the group.
        try await until("the badge says 1") { system.badges.last == 1 }

        // Warm: a group's notification, while Ana's chat is open. It takes that chat's place.
        notifications.tap(url: "/#group=\(group)")
        try await until("the group is read") { try await self.unread(group, for: ben) == 0 }
        try await until("the badge says 0") { system.badges.last == 0 }

        // A friend request's (Cal's): out of the group, into Friends.
        notifications.tap(url: "/#friends")
        try await until("Friends is open") { Self.titles(window.rootViewController).contains("Friends") }

        // A text's, while Friends is open (left there, then a new text): out of Friends, into the chat.
        let again = try E2E.encryptText2(key, "and again", replyTo: nil, sender: ana.user.id, recipient: ben.user.id)
        _ = try await server.send("chats/\(ben.user.id)/messages", method: "POST", token: ana.token, json: Text(ciphertext: again, format: 2))
        try await until("Ana's new text is waiting") { try await !self.allReadByBen(ana: ana, ben: ben) }
        notifications.tap(url: "/#chat=\(ana.user.id)")
        try await until("Ana's new text is read") { try await self.allReadByBen(ana: ana, ben: ben) }
        try await until("Friends is closed") { !Self.titles(window.rootViewController).contains("Friends") }
    }

    /// With napsack locked, a tapped chat waits for the lock to come off, then opens and is read.
    @Test func aTapWhileLockedOpensOnUnlocking() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        try await LiveGroupsTests().befriend(ana, ben)
        let server = try Server(live.address)
        let key = try E2E.pairKey(mine: ana.identity(), theirs: ben.publicKey, myId: ana.user.id, theirId: ben.user.id)
        let sealed = try E2E.encryptText2(key, "locked out", replyTo: nil, sender: ana.user.id, recipient: ben.user.id)
        _ = try await server.send("chats/\(ben.user.id)/messages", method: "POST", token: ana.token, json: Text(ciphertext: sealed, format: 2))

        try KeychainPinStore(server: ben.server).save(Pins(), account: ben.user.id)
        let session = Session(store: MemoryStore(ben), reporter: Reporter())
        await session.restore(server: live.address)
        let lock = AppLock(enabled: true, locked: false)
        let notifications = Notifications(system: RecordedNotifications(), lock: lock)
        let window = try Self.show(ChatListScreen(account: ben, notifications: notifications).environment(session))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await until("the list is in") { Self.titles(window.rootViewController).contains("Chats") }

        // Back after a while away: the tap locks napsack first, and the chat waits.
        lock.left(at: .now.addingTimeInterval(-120))
        notifications.tap(url: "/#chat=\(ana.user.id)")
        #expect(lock.locked)
        #expect(try await !readByBen(ana: ana, ben: ben))
        lock.signedOut()  // the lock coming off (Face ID itself can't run in a test)
        try await until("Ana's text is read") { try await self.readByBen(ana: ana, ben: ben) }
    }

    /// Whether Ben has read everything Ana sent him, as Ana sees it.
    private func allReadByBen(ana: Account, ben: Account) async throws -> Bool {
        let data = try await Server(live.address).send("chats/\(ben.user.id)/messages", token: ana.token)
        return try Server.decoder.decode([DirectMessage].self, from: data).allSatisfy { $0.readAt != nil }
    }

    /// Whether Ben has read Ana's text, as Ana sees it.
    private func readByBen(ana: Account, ben: Account) async throws -> Bool {
        let data = try await Server(live.address).send("chats/\(ben.user.id)/messages", token: ana.token)
        return try Server.decoder.decode([DirectMessage].self, from: data).contains { $0.readAt != nil }
    }

    private func unread(_ group: Int64, for account: Account) async throws -> Int? {
        let data = try await Server(live.address).send("groups", token: account.token)
        return try Server.decoder.decode([GroupSummary].self, from: data).first { $0.id == group }?.unread
    }

    /// Polls until `check` holds: what's checked is on the server or the
    /// screen, which say nothing when they change.
    private func until(_ what: String, _ check: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < end {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("waited 30 seconds for: \(what)")
        throw CancellationError()
    }

    /// The view in a window of its own, on the app's screen, as a phone shows it.
    static func show(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    /// The titles of the navigation bars showing, wherever they are.
    static func titles(_ controller: UIViewController?) -> [String] {
        guard let controller else { return [] }
        var titles: [String] = []
        if let navigation = controller as? UINavigationController, let title = navigation.navigationBar.topItem?.title {
            titles.append(title)
        }
        for child in controller.children { titles += Self.titles(child) }
        return titles + Self.titles(controller.presentedViewController)
    }
}
