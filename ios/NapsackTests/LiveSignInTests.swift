import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Signing up and in against a real napsack server: a local one, never
/// production (it makes an account). Runs only when told where:
///
///   cd server && FADE_INVITE_CODE=letmein cargo run      (in another terminal)
///   xcodebuild test ... TEST_RUNNER_NAPSACK_TEST_SERVER=http://127.0.0.1:8080
///
/// (docs/ios-onboarding.md, The daily loop). The invite code is
/// NAPSACK_TEST_INVITE, "letmein" if it isn't set.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil))
struct LiveSignInTests {
    let address = ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] ?? ""
    let invite = ProcessInfo.processInfo.environment["NAPSACK_TEST_INVITE"] ?? "letmein"

    struct Register: Encodable {
        let username: String
        let authKey: String
        let publicKey: String
        let wrappedPrivateKey: String
        let inviteCode: String
    }

    @Test func signsUpThenInThenOut() async throws {
        let username = "ios_\(UUID().uuidString.prefix(8).lowercased())"
        let password = "correct horse battery"

        // An account made the way sign-up makes one (as the web app does).
        let keys = try E2E.deriveFromPassword(username: username, password: password)
        let identity = try E2E.createIdentity(wrapKey: keys.wrapKey)
        let server = try Server(address)
        _ = try await server.send("auth/register", method: "POST", json: Register(
            username: username, authKey: keys.authKey, publicKey: identity.publicKey,
            wrappedPrivateKey: identity.wrappedPrivateKey, inviteCode: invite))

        let session = Session(store: MemoryStore())
        try await session.signIn(server: address, username: username.uppercased(), password: password)
        let account = try #require(session.account)
        #expect(account.user.username == username)
        #expect(account.publicKey == identity.publicKey)
        #expect(try account.identity().publicKey.derRepresentation == identity.privateKey.publicKey.derRepresentation)
        #expect(try await server.me(token: account.token).username == username)

        await session.signOut()
        await #expect(throws: ServerError.sessionEnded) { try await server.me(token: account.token) }
    }

    @Test func aWrongPasswordIsRefusedInTheServersWords() async throws {
        let session = Session(store: MemoryStore())
        await #expect(throws: ServerError.self) {
            try await session.signIn(server: address, username: "nobody_\(UUID().uuidString.prefix(6).lowercased())", password: "not a password")
        }
    }
}
