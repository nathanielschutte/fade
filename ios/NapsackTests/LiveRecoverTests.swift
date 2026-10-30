import Foundation
import Testing
@testable import Napsack

/// Forgot password, against a real napsack server (a local one; it makes
/// accounts): back in with the recovery key (the same key, every message
/// readable), and with an Admin's reset code (a new key, and a new recovery
/// key shown). Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how);
/// the reset code needs NAPSACK_TEST_ADMIN too.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveRecoverTests {
    let live = LiveChatListTests()

    @Test func backInWithTheRecoveryKey() async throws {
        let first = Session(store: MemoryStore(), reporter: Reporter())
        let name = "rec_\(UUID().uuidString.prefix(6).lowercased())"
        try await first.signUp(server: live.address, username: name, password: "correct horse battery", inviteCode: live.invite)
        let key = try #require(first.recoveryKeyToShow)
        let publicKey = try #require(first.account?.publicKey)

        let phone = Session(store: MemoryStore(), reporter: Reporter())
        await #expect(throws: SignInError.badSecret) {
            try await phone.recover(server: live.address, username: name, secret: "too short", newPassword: "a brand new one")
        }
        try await phone.recover(server: live.address, username: name, secret: key.lowercased(), newPassword: "a brand new one")
        #expect(phone.account?.publicKey == publicKey && phone.recoveryKeyToShow == nil)  // the same key: nothing lost
        let again = Session(store: MemoryStore(), reporter: Reporter())
        try await again.signIn(server: live.address, username: name, password: "a brand new one")
        #expect(again.account?.publicKey == publicKey)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_ADMIN"] != nil))
    func backInWithAnAdminsResetCode() async throws {
        let user = try await live.newAccount("reset")
        let admin = Session(store: MemoryStore(), reporter: Reporter())
        let adminName = ProcessInfo.processInfo.environment["NAPSACK_TEST_ADMIN"]!
        do {
            try await admin.signUp(server: live.address, username: adminName, password: "correct horse battery", inviteCode: live.invite)
        } catch {
            try await admin.signIn(server: live.address, username: adminName, password: "correct horse battery")
        }
        struct Code: Decodable { let code: String }
        let code = try Server.decoder.decode(Code.self, from: await Server(live.address).send(
            "admin/users/\(user.user.id)/reset-code", method: "POST", token: try #require(admin.account?.token))).code
        let phone = Session(store: MemoryStore(), reporter: Reporter())
        #expect(Session.secretKind(code) == .resetCode)
        try await phone.recover(server: live.address, username: user.user.username, secret: code, newPassword: "a brand new one")
        #expect(phone.account?.publicKey != user.publicKey)  // a new key
        #expect(phone.recoveryKeyToShow != nil && phone.account?.user.hasRecoveryKey == true)
    }
}
