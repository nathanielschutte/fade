import Foundation
import Testing
@testable import Napsack

/// Deleting your account against a real server (a local one; it makes
/// accounts): refused without the right username or password, then gone, with
/// nothing kept on the phone and the friend's chat gone too. Runs only with
/// NAPSACK_TEST_SERVER set.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveDeletionTests {
    let live = LiveChatListTests()
    let password = "correct horse battery"

    func newSession(_ prefix: String, store: MemoryStore = MemoryStore()) async throws -> Session {
        let session = Session(store: store, reporter: Reporter())
        try await session.signUp(server: live.address, username: "\(prefix)_\(UUID().uuidString.prefix(6).lowercased())",
                                 password: password, inviteCode: live.invite)
        session.recoveryKeyToShow = nil
        return session
    }

    @Test func deletingTheAccountLeavesNothing() async throws {
        let store = MemoryStore()
        let ana = try await newSession("dela", store: store)
        let ben = try await newSession("delb")
        let anaAccount = try #require(ana.account), benAccount = try #require(ben.account)
        let server = try Server(live.address)
        struct Ask: Encodable { let username: String }
        _ = try await server.send("friends/requests", method: "POST", token: benAccount.token, json: Ask(username: anaAccount.user.username))
        _ = try await server.send("friends/requests/\(benAccount.user.id)/accept", method: "POST", token: anaAccount.token)

        await #expect(throws: SignInError.notYourUsername) {
            try await ana.deleteAccount(password: password, typedUsername: benAccount.user.username)
        }
        await #expect(throws: (any Error).self) {
            try await ana.deleteAccount(password: "not my password", typedUsername: anaAccount.user.username)
        }
        #expect(ana.account != nil, "still signed in")

        try await ana.deleteAccount(password: password, typedUsername: anaAccount.user.username.uppercased())
        #expect(ana.state == .signedOut)
        #expect(ana.notice?.contains("deleted") == true)
        #expect(try store.load() == nil, "nothing of it on the phone")
        struct Friend: Decodable { let id: Int64 }
        let friends = try Server.decoder.decode([Friend].self, from: await server.send("friends", token: benAccount.token))
        #expect(!friends.map(\.id).contains(anaAccount.user.id), "Ben lost the chat")
        let again = Session(store: MemoryStore(), reporter: Reporter())
        await #expect(throws: (any Error).self) {
            try await again.signIn(server: live.address, username: anaAccount.user.username, password: password)
        }
    }
}
