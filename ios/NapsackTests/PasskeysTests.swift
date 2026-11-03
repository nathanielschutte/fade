import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Passkeys (Passkeys.swift, Session.swift) against a stand-in server and the
/// stand-in authenticator: when they're offered, what signing in sends and
/// opens (the vectors' account and its passkey copy, passkey1.json), adding
/// one after sign-up and from Security, and the passkeys that can't unlock
/// napsack, which sign nobody in and are never added.
@MainActor @Suite struct PasskeysTests {
    let v: [String: Any]
    let vk: [String: Any]
    var alice: [String: Any] { v["alice"] as! [String: Any] }
    var bob: [String: Any] { v["bob"] as! [String: Any] }
    var password: [String: Any] { v["password"] as! [String: Any] }
    let me: [String: Any] = ["id": 7, "username": "alice", "display_name": NSNull(), "role": "user", "has_recovery_key": true]
    static let challenge = Data(repeating: 7, count: 32)

    init() throws {
        let folder = try #require(Bundle.main.url(forResource: "vectors", withExtension: nil))
        v = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "format1.json"))) as! [String: Any]
        vk = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "passkey1.json"))) as! [String: Any]
    }

    static func hex(_ s: String) -> Data {
        let h = Array(s)
        return Data(stride(from: 0, to: h.count, by: 2).map { UInt8(String(h[$0..<$0 + 2]), radix: 16)! })
    }

    // ---------- when they're offered ----------

    @Test func offeredOnlyWhereTheServersSiteIsTheApps() {
        let staging = ["staging.napsack.io"]
        #expect(Passkeys.offered(rpID: "staging.napsack.io", sites: staging))
        #expect(Passkeys.offered(rpID: "Staging.Napsack.IO", sites: staging))
        #expect(!Passkeys.offered(rpID: "napsack.io", sites: staging))  // another site's passkeys
        #expect(!Passkeys.offered(rpID: "localhost", sites: staging))  // a development server
        #expect(!Passkeys.offered(rpID: nil, sites: staging))  // a server from before passkeys
        #expect(!Passkeys.offered(rpID: "", sites: staging))
        #expect(!Passkeys.offered(rpID: "staging.napsack.io", sites: []))  // a build without the site association
        // This build's site is its entitlement's (Info.plist repeats NAPSACK_LINK_HOST), never a development server.
        #expect(Bundle.main.object(forInfoDictionaryKey: "NapsackLinkHost") != nil)
        #expect(!Passkeys.offered(rpID: "localhost") && Passkeys.sites.count <= 1)
    }

    @Test func theServersConfigSaysWhetherToOfferThem() throws {
        func config(_ rpID: String?) throws -> ServerConfig {
            var object: [String: Any] = ["api_version": 1, "build": "abc", "server_version": "0.50.0", "environment": NSNull(),
                                         "invite_required": false, "message_formats": [1, 2], "min_client_versions": [:]]
            if let rpID { object["passkey_rp_id"] = rpID }
            return try ServerConfig.decode(json(object))
        }
        #expect(try config("napsack.io").passkeyRpId == "napsack.io" && config(nil).passkeyRpId == nil)
        let support = PasskeySupport()
        #expect(support.offered == nil)
        support.learn(nil)  // couldn't ask: still unknown
        #expect(support.offered == nil)
        support.learn(try config("localhost"))
        #expect(support.offered == false)
        if let site = Passkeys.sites.first {
            support.learn(try config(site))
            #expect(support.offered == true)
        }
        support.learn(try config(nil))  // before passkeys
        #expect(support.offered == false)
    }

    @Test func base64urlAsWebAuthnWritesIt() {
        let bytes = Data([0xfb, 0xff, 0xfe, 0x00, 0x3e, 0x3f])
        #expect(Passkeys.b64url(bytes) == "-__-AD4_")
        #expect(Passkeys.data(b64url: "-__-AD4_") == bytes)
        #expect(Passkeys.data(b64url: "_-4") == Data([0xff, 0xee]) && Passkeys.data(b64url: "_-4=") == Data([0xff, 0xee]))
        #expect(Passkeys.data(b64url: "not base64!") == nil)
    }

    // ---------- signing in ----------

    /// A server whose passkey sign-in hands back the vectors' account and its
    /// passkey copy (or `copy`), whatever passkey answers.
    func signInServer(copy: String? = nil) -> StubServer {
        let answer = json(["token": "pk-token", "user": me, "public_key": alice["spki"]!, "wrapped_private_key": password["wrapped_private_key"]!,
                           "passkey_wrapped_key": copy ?? vk["passkey_wrapped_key"]!])
        let options = json(["challenge": Passkeys.b64url(Self.challenge), "rp_id": "localhost"])
        return StubServer { request in
            switch request.url!.path {
            case "/api/auth/passkey/options": (200, options)
            case "/api/auth/passkey": (200, answer)
            case "/api/auth/logout": (200, json(["ok": true]))
            default: (404, json(["error": "not here"]))
            }
        }
    }

    /// The stand-in, holding one passkey whose PRF secret is the vectors'.
    func vectorPasskey() async throws -> StandInPasskeys {
        let passkeys = StandInPasskeys()
        passkeys.fixedSecret = Self.hex(vk["prf_secret_hex"] as! String)
        _ = try await passkeys.create(rpID: "localhost", challenge: Self.challenge, userName: "alice", userID: Data([0, 0, 0, 0, 0, 0, 0, 7]),
                                      excluding: [], prfInput: E2E.passkeyPrfInput())
        return passkeys
    }

    @Test func signsInWithAPasskeyAndItsCopyOfTheKey() async throws {
        let server = signInServer(), store = MemoryStore(), passkeys = try await vectorPasskey()
        let session = Session(transport: server, store: store, reporter: Reporter())
        try await session.signInWithPasskey(server: "https://napsack.test", using: passkeys)

        let sent = await server.requests
        #expect(sent.map { $0.url!.path } == ["/api/auth/passkey/options", "/api/auth/passkey"])
        #expect(passkeys.signed.map { $0.rpID } == ["localhost"] && passkeys.signed[0].allowed.isEmpty)  // any of the site's
        let answer = body(sent[1])
        #expect(answer["credential_id"] as? String == Passkeys.b64url(passkeys.credentials[0].id))
        let client = try JSONSerialization.jsonObject(with: #require(Passkeys.data(b64url: answer["client_data_json"] as? String ?? ""))) as? [String: Any]
        #expect(client?["type"] as? String == "webauthn.get" && client?["challenge"] as? String == Passkeys.b64url(Self.challenge))
        #expect(answer["authenticator_data"] is String && answer["signature"] is String && answer.count == 4)

        // In with Alice's own key, from the passkey's copy: it opens Bob's text, and it's kept.
        let account = try #require(session.account)
        #expect(account.token == "pk-token" && account.publicKey == alice["spki"] as? String)
        #expect(try store.load() == account)
        let text = v["text"] as! [String: Any]
        let key = try E2E.pairKey(mine: account.identity(), theirs: bob["spki"] as! String, myId: alice["id"] as! Int64, theirId: bob["id"] as! Int64)
        #expect(try E2E.decryptText(key, text["ciphertext"] as! String, sender: text["from"] as! Int64, recipient: text["to"] as! Int64)
                == text["plaintext"] as! String)
    }

    @Test func aPasskeyWithoutItsSecretSignsNobodyIn() async throws {
        let server = signInServer(), passkeys = try await vectorPasskey()
        passkeys.prf = false
        let session = Session(transport: server, store: MemoryStore(), reporter: Reporter())
        await #expect(throws: PasskeyError.cantUnlock) { try await session.signInWithPasskey(server: "https://napsack.test", using: passkeys) }
        #expect(await server.requests.map { $0.url!.path } == ["/api/auth/passkey/options"])  // nothing signed in
        #expect(session.account == nil)
        #expect(PasskeyError.cantUnlock.errorDescription == "This passkey can't unlock napsack here. Use your password.")
    }

    @Test func closingTheSheetIsNotAnError() async throws {
        let server = signInServer(), passkeys = try await vectorPasskey()
        passkeys.closesSheet = true
        let session = Session(transport: server, store: MemoryStore(), reporter: Reporter())
        await #expect(throws: PasskeyError.canceled) { try await session.signInWithPasskey(server: "https://napsack.test", using: passkeys) }
        #expect(await server.requests.count == 1 && session.account == nil && session.notice == nil)
    }

    @Test func aCopyTheSecretDoesntOpenEndsTheSessionAtOnce() async throws {
        // The password's copy where the passkey's should be: it can't open, so no key and no session.
        let server = signInServer(copy: password["wrapped_private_key"] as? String), passkeys = try await vectorPasskey()
        let session = Session(transport: server, store: MemoryStore(), reporter: Reporter())
        await #expect(throws: PasskeyError.cantUnlock) { try await session.signInWithPasskey(server: "https://napsack.test", using: passkeys) }
        let sent = await server.requests
        #expect(sent.last?.url?.path == "/api/auth/logout" && sent.last?.value(forHTTPHeaderField: "Authorization") == "Bearer pk-token")
        #expect(session.account == nil)
    }

    // ---------- adding one ----------

    /// Sign-up, a recovery key, and passkeys: options for `newbie`, and adding
    /// answers as the server does (or `addStatus`'s refusal).
    func signUpServer(addStatus: Int = 200, exclude: [String] = []) -> StubServer {
        let me = json(["id": 9, "username": "newbie", "display_name": NSNull(), "role": "user", "has_recovery_key": false])
        let options = json(["challenge": Passkeys.b64url(Self.challenge), "rp_id": "localhost", "rp_name": "napsack",
                            "user_id": Passkeys.b64url(Data([0, 0, 0, 0, 0, 0, 0, 9])), "user_name": "newbie", "exclude": exclude])
        return StubServer { request in
            switch request.url!.path {
            case "/api/auth/register":
                let sent = body(request)
                return (200, json(["token": "new-token", "user": try JSONSerialization.jsonObject(with: me),
                                   "public_key": sent["public_key"]!, "wrapped_private_key": sent["wrapped_private_key"]!]))
            case "/api/me/recovery": return (200, json(["ok": true]))
            case "/api/me/passkeys/options": return (200, options)
            case "/api/me/passkeys":
                return addStatus == 200 ? (200, json(["id": 3, "provider": "iCloud Keychain", "created_at": 1_793_300_000]))
                    : (addStatus, json(["error": "That passkey couldn't be added. Try again."]))
            case "/api/auth/unlock": return (400, json(["error": "Your current password isn't right."]))
            case "/api/me/passkeys/3/remove": return (404, json(["error": "That passkey isn't there any more."]))
            default: return (404, json(["error": "not here"]))
            }
        }
    }

    func signedUp(_ server: StubServer, offer: Bool = true) async throws -> Session {
        let session = Session(transport: server, store: MemoryStore(), reporter: Reporter())
        try await session.signUp(server: "https://napsack.test", username: "newbie", password: "a long password", inviteCode: nil, offerPasskey: offer)
        return session
    }

    @Test func afterSignUpAPasskeyIsAddedWithTheKeysStillInMemory() async throws {
        let server = signUpServer(), passkeys = StandInPasskeys()
        let session = try await signedUp(server)
        #expect(session.recoveryKeyToShow != nil && session.passkeyOffer != nil)  // the recovery key, then the offer
        let added = try await session.addOfferedPasskey(using: passkeys)
        #expect(session.passkeyOffer == nil)  // decided: the keys are gone from memory
        #expect(added.id == 3 && added.provider == "iCloud Keychain" && added.credentialId == Passkeys.b64url(passkeys.credentials[0].id))
        #expect(passkeys.signed.isEmpty)  // its secret came as it was made

        let sent = await server.requests
        #expect(sent.map { $0.url!.path } == ["/api/auth/register", "/api/me/recovery", "/api/me/passkeys/options", "/api/me/passkeys"])
        let add = body(sent[3])
        let keys = try E2E.deriveFromPassword(username: "newbie", password: "a long password")
        #expect(add["auth_key"] as? String == keys.authKey)  // the password, proven without being asked again
        let client = try JSONSerialization.jsonObject(with: #require(Passkeys.data(b64url: add["client_data_json"] as? String ?? ""))) as? [String: Any]
        #expect(client?["type"] as? String == "webauthn.create" && client?["challenge"] as? String == Passkeys.b64url(Self.challenge))
        #expect(Passkeys.data(b64url: add["attestation_object"] as? String ?? "") != nil)
        // The copy it sent opens with the passkey's secret alone, to this account's key.
        let secret = try #require(passkeys.secret(of: passkeys.credentials[0].id, for: E2E.passkeyPrfInput()))
        let opened = try E2E.unwrapWithPasskey(passkeyWrapKey: E2E.deriveFromPasskey(secret), wrapped: add["wrapped_key"] as! String)
        #expect(try opened.publicKey.rawRepresentation == #require(session.account).identity().publicKey.rawRepresentation)
        for request in sent { #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("a long password")) }
    }

    @Test func noOfferUnlessPasskeysWorkWithTheServer() async throws {
        let session = try await signedUp(signUpServer(), offer: false)
        #expect(session.recoveryKeyToShow != nil && session.passkeyOffer == nil)
        await #expect(throws: ServerError.sessionEnded) { _ = try await session.addOfferedPasskey(using: StandInPasskeys()) }
    }

    @Test func aPasskeyThatGivesItsSecretOnlyWhenUsedIsAskedOnce() async throws {
        let passkeys = StandInPasskeys()
        passkeys.prfAsMade = false
        let session = try await signedUp(signUpServer())
        _ = try await session.addOfferedPasskey(using: passkeys)
        #expect(passkeys.signed.count == 1 && passkeys.signed[0].allowed == [passkeys.credentials[0].id])  // the new one alone
        #expect(passkeys.forgotten.isEmpty)
    }

    @Test func aPasskeyThatCantUnlockIsNeverAdded() async throws {
        let server = signUpServer(), passkeys = StandInPasskeys()
        passkeys.prf = false
        let session = try await signedUp(server)
        await #expect(throws: PasskeyError.cantUnlock) { _ = try await session.addOfferedPasskey(using: passkeys) }
        #expect(await server.requests.map { $0.url!.path }.last == "/api/me/passkeys/options")  // nothing sent to add
        #expect(passkeys.signed.isEmpty)  // it said it can't: not asked again
        #expect(passkeys.forgotten == passkeys.credentials.map(\.id))  // the phone's told to drop it
        #expect(session.passkeyOffer != nil)  // still offered: another passkey, or not now
    }

    @Test func aPasskeyTheServerRefusedIsDroppedFromThePhone() async throws {
        let passkeys = StandInPasskeys()
        let session = try await signedUp(signUpServer(addStatus: 400))
        await #expect(throws: ServerError.refused("That passkey couldn't be added. Try again.", status: 400)) {
            _ = try await session.addOfferedPasskey(using: passkeys)
        }
        #expect(passkeys.forgotten == passkeys.credentials.map(\.id))
        // Only when it surely isn't on the server: a lost connection may have delivered it, and "already added" means it's there.
        #expect(Session.surelyNotKept(ServerError.refused("no", status: 400)) && Session.surelyNotKept(PasskeyError.canceled))
        #expect(!Session.surelyNotKept(ServerError.refused("already", status: 409)) && !Session.surelyNotKept(ServerError.unreachable)
                && !Session.surelyNotKept(ServerError.refused("gateway", status: 504)))
    }

    @Test func fromSecurityAWrongPasswordNeverReachesThePasskey() async throws {
        let server = signUpServer(), passkeys = StandInPasskeys()
        let session = try await signedUp(server, offer: false)
        await #expect(throws: ServerError.refused("Your current password isn't right.", status: 400)) {
            _ = try await session.addPasskey(password: "not my password", using: passkeys)
        }
        #expect(passkeys.credentials.isEmpty && passkeys.signed.isEmpty)
        #expect(await server.requests.map { $0.url!.path }.last == "/api/auth/unlock")
    }

    @Test func removingOneAlreadyRemovedElsewhereIsJustAsGood() async throws {
        let session = try await signedUp(signUpServer(), offer: false), passkeys = StandInPasskeys()
        let gone = Session.Passkey(id: 3, credentialId: "AAEC", provider: nil, createdAt: 1_793_300_000, lastUsedAt: nil)
        try await session.removePasskey(gone, rpID: "localhost", using: passkeys)
        #expect(passkeys.forgotten == [Data([0, 1, 2])])  // and the phone's told to drop it
    }

    @Test func signingOutForgetsTheOffer() async throws {
        let session = try await signedUp(signUpServer())
        #expect(session.passkeyOffer != nil)
        await session.signOut()
        #expect(session.passkeyOffer == nil && session.account == nil)
    }

    @Test func aRowSaysWhereItsKeptAndWhenItWasUsed() {
        let added = Date(timeIntervalSince1970: 1_793_300_000).formatted(date: .abbreviated, time: .omitted)
        let unused = Session.Passkey(id: 1, credentialId: "AA", provider: nil, createdAt: 1_793_300_000, lastUsedAt: nil)
        #expect(PasskeyRow.when(unused) == "Added \(added) · Not used yet")
        let used = Session.Passkey(id: 2, credentialId: "AB", provider: "iCloud Keychain", createdAt: 1_793_300_000, lastUsedAt: 1_793_300_000)
        #expect(PasskeyRow.when(used) == "Added \(added) · Last used \(added)")
    }
}
