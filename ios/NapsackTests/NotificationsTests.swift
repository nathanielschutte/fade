import Foundation
import Testing
@testable import Napsack

/// Where a tapped notification goes, and the token as the server takes it.
@MainActor struct NotificationsTests {
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
}
