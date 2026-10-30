import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Creating an account and its recovery key, and the update screen's triggers,
/// against a stand-in server.
@MainActor @Suite struct SignUpTests {
    let me: [String: Any] = ["id": 9, "username": "newbie", "display_name": NSNull(), "role": "user", "has_recovery_key": false, "is_admin": false]

    /// Register answers with what it was sent (as the server does); recovery answers `recoveryStatus`.
    func signUpServer(recoveryStatus: Int = 200) -> StubServer {
        let me = json(self.me)
        return StubServer { request in
            switch request.url!.path {
            case "/api/auth/register":
                let sent = body(request)
                let user = try JSONSerialization.jsonObject(with: me)
                return (200, json(["token": "new-token", "user": user, "public_key": sent["public_key"]!, "wrapped_private_key": sent["wrapped_private_key"]!]))
            case "/api/me/recovery":
                return (recoveryStatus, json(recoveryStatus == 200 ? ["ok": true] : ["error": "Something went wrong."]))
            default:
                return (404, json(["error": "not here"]))
            }
        }
    }

    @Test func makesTheKeysHereAndARecoveryKeyThatReallyRecovers() async throws {
        let server = signUpServer(), store = MemoryStore()
        let session = Session(transport: server, store: store)
        try await session.signUp(server: "https://napsack.test", username: " newbie ", password: "a long password", inviteCode: " letmein ")

        let sent = await server.requests
        #expect(sent.map { $0.url!.path } == ["/api/auth/register", "/api/me/recovery"])
        let register = body(sent[0]), recovery = body(sent[1])
        #expect(register["username"] as? String == "newbie" && register["invite_code"] as? String == "letmein")
        let keys = try E2E.deriveFromPassword(username: "newbie", password: "a long password")
        #expect(register["auth_key"] as? String == keys.authKey && recovery["auth_key"] as? String == keys.authKey)
        #expect(sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
        for request in sent {
            #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("a long password"))
        }

        // Signed in with the new key, and the key shown once really gets it back.
        let account = try #require(session.account)
        #expect(account.user.hasRecoveryKey)
        #expect(try store.load() == account)
        let shown = try #require(session.recoveryKeyToShow)
        let recoveryKeys = try E2E.deriveFromRecoveryKey(shown)
        #expect(recovery["recovery_auth_key"] as? String == recoveryKeys.authKey)
        let newPassword = try E2E.deriveFromPassword(username: "newbie", password: "a new password")
        let recovered = try E2E.recoverIdentity(recoveryWrapKey: recoveryKeys.wrapKey,
                                                recoveryWrapped: recovery["recovery_wrapped_key"] as! String, newWrapKey: newPassword.wrapKey)
        #expect(recovered.privateKey.derRepresentation == account.privateKey)
    }

    @Test func noInviteCodeIsSentWhenTheServerDoesntAsk() async throws {
        let server = signUpServer()
        let session = Session(transport: server, store: MemoryStore())
        try await session.signUp(server: "https://napsack.test", username: "newbie", password: "a long password", inviteCode: nil)
        #expect(body(try #require(await server.requests.first))["invite_code"] == nil)
    }

    @Test func aFailedRecoveryKeyStillLeavesAWorkingAccount() async throws {
        let session = Session(transport: signUpServer(recoveryStatus: 500), store: MemoryStore())
        try await session.signUp(server: "https://napsack.test", username: "newbie", password: "a long password", inviteCode: nil)
        #expect(session.account?.user.hasRecoveryKey == false)
        #expect(session.recoveryKeyToShow == nil)
    }

    @Test func refusesWhatTheWebAppRefusesBeforeAskingTheServer() async throws {
        let server = signUpServer()
        let session = Session(transport: server, store: MemoryStore())
        await #expect(throws: SignInError.shortPassword) {
            try await session.signUp(server: "https://napsack.test", username: "newbie", password: "short", inviteCode: nil)
        }
        await #expect(throws: SignInError.emailAsUsername) {
            try await session.signUp(server: "https://napsack.test", username: "me@example.com", password: "a long password", inviteCode: nil)
        }
        #expect(await server.requests.isEmpty)
    }

    func configServer(minimumIOS: String?) -> StubServer {
        let config = json(["api_version": 1, "build": "abc", "server_version": "0.42.1", "environment": NSNull(), "invite_required": false,
                           "message_formats": [1, 2], "min_client_versions": minimumIOS.map { ["ios": $0] } ?? [:]])
        return StubServer { _ in (200, config) }
    }

    @Test func aServerThatNeedsANewerAppSaysSoAtLaunch() async {
        let session = Session(transport: configServer(minimumIOS: "99.0.0"), store: MemoryStore())
        await session.restore(server: "https://napsack.test")
        #expect(session.updateNeeded == "This version of napsack is too old. Update to 99.0.0 or newer to keep using it.")

        let fine = Session(transport: configServer(minimumIOS: nil), store: MemoryStore())
        await fine.restore(server: "https://napsack.test")
        #expect(fine.updateNeeded == nil && fine.state == .signedOut)
    }

    @Test func aTooOldAnswerToAnyRequestShowsTheUpdateScreen() async {
        let session = Session(transport: StubServer { _ in (426, json(["error": "Update to 1.2.0 or newer."])) }, store: MemoryStore())
        await #expect(throws: ServerError.self) {
            try await session.signIn(server: "https://napsack.test", username: "ana", password: "whatever")
        }
        #expect(session.updateNeeded == "Update to 1.2.0 or newer.")
    }
}
