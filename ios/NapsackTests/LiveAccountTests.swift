import Foundation
import Testing
@testable import Napsack

/// The account's safety against a real napsack server (a local one; it makes
/// accounts): other devices, the password, the recovery key, and the username,
/// each proven by signing in again afterwards. Runs only with
/// NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil))
struct LiveAccountTests {
    let live = LiveChatListTests()
    let password = "correct horse battery"

    func session(_ username: String, password: String) async throws -> Session {
        let session = Session(store: MemoryStore(), reporter: Reporter())
        try await session.signIn(server: live.address, username: username, password: password)
        return session
    }

    @Test func otherDevicesPasswordRecoveryAndUsername() async throws {
        let phone = Session(store: MemoryStore(), reporter: Reporter())
        let name = "acct_\(UUID().uuidString.prefix(6).lowercased())"
        try await phone.signUp(server: live.address, username: name, password: password, inviteCode: live.invite)
        phone.recoveryKeyToShow = nil
        var security = try await phone.security()
        #expect(security.recoverySetAt != nil && security.activeSessions == 1)

        // Another device, then signed out from here.
        let laptop = try await session(name, password: password)
        #expect(try await phone.security().activeSessions == 2)
        #expect(try await phone.endOtherSessions() == 1)
        await #expect(throws: ServerError.sessionEnded) { _ = try await laptop.security() }
        #expect(try await phone.security().activeSessions == 1)

        // A new password: the old one stops working, the new one opens the same key.
        await #expect(throws: (any Error).self) { _ = try await phone.changePassword(current: "not my password", new: "a whole new one") }
        _ = try await phone.changePassword(current: password, new: "a whole new one")
        await #expect(throws: (any Error).self) { _ = try await session(name, password: password) }
        let again = try await session(name, password: "a whole new one")
        #expect(again.account?.publicKey == phone.account?.publicKey)

        // A new recovery key, shown once.
        try await phone.makeRecoveryKey(password: "a whole new one")
        #expect(phone.recoveryKeyToShow?.isEmpty == false && phone.account?.user.hasRecoveryKey == true)
        security = try await phone.security()
        #expect(security.recoverySetAt != nil)

        // A new username: sign in under it, with the same password and key.
        await #expect(throws: SignInError.badUsername) { try await phone.changeUsername(to: "no spaces allowed", password: "a whole new one") }
        let renamed = name + "_r"
        try await phone.changeUsername(to: renamed, password: "a whole new one")
        #expect(phone.account?.user.username == renamed)
        let underNewName = try await session(renamed, password: "a whole new one")
        #expect(underNewName.account?.publicKey == phone.account?.publicKey)
    }
}
