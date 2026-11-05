import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Passkeys against a real napsack server (a local one; it makes accounts),
/// with the stand-in authenticator (StandInPasskeys): one added with the
/// password, then back in with the passkey alone (the same key: a friend's
/// text still opens), listed with when it was used, removed, and refused
/// after; the one recommended after sign-up; and one that can't unlock
/// napsack, never added. Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LivePasskeysTests {
    let live = LiveChatListTests()
    let password = testPassword

    func signedUp(_ name: String, offerPasskey: Bool = false) async throws -> Session {
        let session = Session(store: MemoryStore(), reporter: Reporter())
        try await session.signUp(server: live.address, username: "\(name)_\(UUID().uuidString.prefix(6).lowercased())", password: password,
                                 inviteCode: live.invite, offerPasskey: offerPasskey)
        return session
    }

    @Test func addedThenSignedInWithListedAndRemoved() async throws {
        let phone = try await signedUp("pk"), ben = try await live.newAccount("pkben")
        let ana = try #require(phone.account)
        let server = try Server(live.address)
        _ = try await server.send("friends/requests", method: "POST", token: ana.token, json: LiveChatListTests.Request(username: ben.user.username))
        _ = try await server.send("friends/requests", method: "POST", token: ben.token, json: LiveChatListTests.Request(username: ana.user.username))
        let sealing = try E2E.pairKey(mine: ben.identity(), theirs: ana.publicKey, myId: ben.user.id, theirId: ana.user.id)
        let text = try E2E.encryptText2(sealing, "opened with a passkey 🔑", replyTo: nil, sender: ben.user.id, recipient: ana.user.id)
        _ = try await server.sendText(to: ana.user.id, ciphertext: text, clientId: Conversation.newClientId(), token: ben.token)

        // Added with her password; a wrong one never gets as far as the passkey.
        let passkeys = StandInPasskeys(server: live.address)
        await #expect(throws: ServerError.self) { _ = try await phone.addPasskey(password: "not my password", using: passkeys) }
        #expect(passkeys.credentials.isEmpty)
        let added = try await phone.addPasskey(password: password, using: passkeys)
        #expect(added.provider == "iCloud Keychain")
        var list = try await phone.passkeys()
        #expect(list.rpId == "localhost" && list.passkeys.map(\.id) == [added.id] && list.passkeys[0].lastUsedAt == nil)

        // Signed out, then back in with the passkey alone: her own key, so Ben's text opens.
        await phone.signOut()
        let back = Session(store: MemoryStore(), reporter: Reporter())
        try await back.signInWithPasskey(server: live.address, using: passkeys)
        let again = try #require(back.account)
        #expect(again.user.id == ana.user.id && again.publicKey == ana.publicKey)
        #expect(try again.identity().publicKey.rawRepresentation == ana.identity().publicKey.rawRepresentation)
        let newest = try #require(try await server.directMessages(friend: ben.user.id, before: nil, limit: 10, token: again.token).last)
        let opening = try E2E.pairKey(mine: again.identity(), theirs: ben.publicKey, myId: again.user.id, theirId: ben.user.id)
        #expect(try E2E.decryptAnyText(opening, try #require(newest.ciphertext), format: newest.format, sender: ben.user.id,
                                       recipient: again.user.id).text == "opened with a passkey 🔑")

        // Listed with when it last signed her in; removed, it stops working.
        list = try await back.passkeys()
        #expect(list.passkeys.first?.lastUsedAt != nil)
        try await back.removePasskey(list.passkeys[0], rpID: list.rpId, using: passkeys)
        #expect(try await back.passkeys().passkeys.isEmpty)
        #expect(passkeys.forgotten == [passkeys.credentials[0].id])  // the phone's told to drop it
        let refused = Session(store: MemoryStore(), reporter: Reporter())
        do {
            try await refused.signInWithPasskey(server: live.address, using: passkeys)
            Issue.record("a removed passkey signed in")
        } catch ServerError.refused(let words, _) {
            #expect(words.contains("isn't set up for napsack"))
        }
        #expect(refused.account == nil)

        // Removed from another device: a laptop's sheet still has it, until the server's answer drops it there too.
        let laptop = StandInPasskeys(sharing: passkeys)
        await #expect(throws: ServerError.self) { try await Session(store: MemoryStore(), reporter: Reporter()).signInWithPasskey(server: live.address, using: laptop) }
        #expect(laptop.forgotten == [passkeys.credentials[0].id])
    }

    @Test func theOneRecommendedAfterSignUp() async throws {
        let phone = try await signedUp("pkoffer", offerPasskey: true)
        #expect(phone.recoveryKeyToShow != nil && phone.passkeyOffer != nil)
        let passkeys = StandInPasskeys(server: live.address)
        passkeys.prfAsMade = false  // as some password managers: the secret only from a signature
        _ = try await phone.addOfferedPasskey(using: passkeys)
        #expect(phone.passkeyOffer == nil)
        #expect(passkeys.signed.map { $0.allowed } == [[passkeys.credentials[0].id]])  // asked once more, the new one alone

        let laptop = Session(store: MemoryStore(), reporter: Reporter())
        try await laptop.signInWithPasskey(server: live.address, using: passkeys)
        let mine = try #require(phone.account), theirs = try #require(laptop.account)
        #expect(theirs.user.id == mine.user.id && theirs.publicKey == mine.publicKey)
        #expect(try theirs.identity().publicKey.rawRepresentation == mine.identity().publicKey.rawRepresentation)
    }

    @Test func oneThatCantUnlockNapsackIsNeverAdded() async throws {
        let phone = try await signedUp("pknoprf", offerPasskey: true)
        let passkeys = StandInPasskeys(server: live.address)
        passkeys.prf = false
        await #expect(throws: PasskeyError.cantUnlock) { _ = try await phone.addOfferedPasskey(using: passkeys) }
        #expect(try await phone.passkeys().passkeys.isEmpty)
        #expect(passkeys.forgotten == passkeys.credentials.map(\.id) && passkeys.credentials.count == 1)
        #expect(phone.passkeyOffer != nil)  // still offered: another passkey, or not now
    }
}
