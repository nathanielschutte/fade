import AuthenticationServices
import CryptoKit
import NapsackCrypto
import SwiftUI

/// Passkeys (F26, docs/design/passkeys.md): signing in with Face ID instead
/// of the password. A passkey alone only proves who you are; napsack also
/// needs the private key on the phone, so each passkey wraps a third copy of
/// it, beside the password's and the recovery key's, with a secret only that
/// passkey produces: WebAuthn's PRF extension (iOS 18). The server keeps the
/// passkey's public key and the copy, and never sees the secret.
///
/// Here: when passkeys are offered, the phone's passkeys behind a small
/// protocol (the system's sheet can't be driven in tests, which use a
/// stand-in), and the screens: the offer after sign-up, and Profile ›
/// Security › Passkeys. Signing in and adding one are Session's.
enum Passkeys {
    /// The site this build's passkeys belong to: the `webcredentials:` site in
    /// Napsack.entitlements (NAPSACK_LINK_HOST: staging's for Xcode builds,
    /// napsack.io in Release), repeated in Info.plist for the app to read.
    /// None for a build without the entitlement (Local.xcconfig.example).
    static let sites: [String] = [Bundle.main.object(forInfoDictionaryKey: "NapsackLinkHost") as? String]
        .compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }

    /// Whether passkeys can work with a server: iOS makes and uses them only
    /// for a site the app is associated with, so the server's relying party
    /// (`passkey_rp_id`, /api/config) must be one. A development server
    /// ("localhost"), or one from before passkeys (it says nothing), never
    /// shows a button that can't work.
    static func offered(rpID: String?, sites: [String] = sites) -> Bool {
        guard let rpID = rpID?.lowercased(), !rpID.isEmpty else { return false }
        return sites.contains(rpID)
    }

    /// Base64url without padding, as WebAuthn and the server write it.
    static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(b64url text: String) -> Data? {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }
}

/// A passkey just made, as the phone hands it back.
struct NewPasskey: Sendable {
    let credentialID: Data
    let clientDataJSON: Data
    let attestationObject: Data
    /// Whether it can give a PRF secret at all (nil: it didn't say).
    let prfSupported: Bool?
    /// The PRF secret, if it gave one as it was made (not every passkey does).
    let prfSecret: SymmetricKey?
}

/// A passkey's answer to a challenge.
struct PasskeySignature: Sendable {
    let credentialID: Data
    let clientDataJSON: Data
    let authenticatorData: Data
    let signature: Data
    /// What opens napsack's copy of the key; nil when this passkey can't give it.
    let prfSecret: SymmetricKey?
}

/// The phone's passkeys: the system's sheet (SystemPasskeys), or a stand-in
/// in tests. Each call shows the sheet (Face ID) and waits for it.
@MainActor protocol PasskeyAuthenticator: AnyObject {
    /// Whether it can make and use passkeys for this site.
    func works(for rpID: String) -> Bool
    /// Makes a passkey for the account (`userID` is the server's handle for
    /// it), never a second one beside those `excluding`, asking for the PRF
    /// secret of `prfInput` too.
    func create(rpID: String, challenge: Data, userName: String, userID: Data, excluding: [Data], prfInput: Data) async throws -> NewPasskey
    /// One of the site's passkeys (any, or one of `allowed`) signs `challenge`
    /// and gives the PRF secret of `prfInput`.
    func sign(rpID: String, challenge: Data, allowed: [Data], prfInput: Data) async throws -> PasskeySignature
    /// Tells the phone's password managers a passkey doesn't work any more, so they can drop it.
    func forget(rpID: String, credentialID: Data) async
}

/// What goes wrong with a passkey, in words for the person.
enum PasskeyError: LocalizedError, Equatable {
    /// The person closed the sheet: nothing to say.
    case canceled
    /// No PRF secret, or one that doesn't open napsack's copy of the key.
    case cantUnlock
    /// Their password manager already has a passkey for this account.
    case alreadyAdded
    /// iOS wouldn't do it (why is in the log), or passkeys don't work with this server.
    case unavailable

    var errorDescription: String? {
        switch self {
        case .canceled: "Canceled."
        case .cantUnlock: "This passkey can't unlock napsack here. Use your password."
        case .alreadyAdded: "You already have a passkey for napsack here."
        case .unavailable: "Passkeys aren't working on this phone right now. Use your password."
        }
    }
}

/// The phone's own passkeys, through the system's sheet: iCloud Keychain, or
/// whichever password manager the person uses. User verification is always
/// required (Face ID or the passcode): the server checks it, and a PRF secret
/// made without it would be a different one.
@MainActor final class SystemPasskeys: PasskeyAuthenticator {
    static let shared = SystemPasskeys()

    func works(for rpID: String) -> Bool { Passkeys.offered(rpID: rpID) }

    func create(rpID: String, challenge: Data, userName: String, userID: Data, excluding: [Data], prfInput: Data) async throws -> NewPasskey {
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
            .createCredentialRegistrationRequest(challenge: challenge, name: userName, userID: userID)
        request.userVerificationPreference = .required
        request.attestationPreference = ASAuthorizationPublicKeyCredentialAttestationKind.none  // any passkey will do
        request.excludedCredentials = excluding.map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:))
        request.prf = .inputValues(.saltInput1(prfInput))
        guard let made = try await SheetRun(request).answer() as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = made.rawAttestationObject else { throw PasskeyError.unavailable }
        return NewPasskey(credentialID: made.credentialID, clientDataJSON: made.rawClientDataJSON, attestationObject: attestation,
                          prfSupported: made.prf?.isSupported, prfSecret: made.prf?.first)
    }

    func sign(rpID: String, challenge: Data, allowed: [Data], prfInput: Data) async throws -> PasskeySignature {
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
            .createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        request.allowedCredentials = allowed.map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:))
        request.prf = .inputValues(.saltInput1(prfInput))
        guard let used = try await SheetRun(request).answer() as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyError.unavailable
        }
        return PasskeySignature(credentialID: used.credentialID, clientDataJSON: used.rawClientDataJSON,
                                authenticatorData: used.rawAuthenticatorData, signature: used.signature, prfSecret: used.prf?.first)
    }

    func forget(rpID: String, credentialID: Data) async {
        // iOS 26.2 tells every password manager on the phone; before it, there's no way to.
        if #available(iOS 26.2, *) {
            try? await ASCredentialDataManager().reportUnknownPublicKeyCredential(relyingPartyIdentifier: rpID, credentialID: credentialID)
        }
    }
}

/// One trip through the system's sheet: ASAuthorizationController, awaited.
@MainActor private final class SheetRun: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let controller: ASAuthorizationController
    private var waiting: CheckedContinuation<any ASAuthorizationCredential, any Error>?

    init(_ request: ASAuthorizationRequest) {
        controller = ASAuthorizationController(authorizationRequests: [request])
    }

    /// Shows the sheet; the passkey's answer, or why there isn't one. (The
    /// caller holds this until it returns: the controller's delegate is weak.)
    func answer() async throws -> any ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        waiting?.resume(returning: authorization.credential)
        waiting = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        waiting?.resume(throwing: Self.meaning(error))
        waiting = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first { return window }
        return scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
    }

    /// The sheet's errors, in napsack's words. Closing it isn't one.
    static func meaning(_ error: any Error) -> PasskeyError {
        switch (error as? ASAuthorizationError)?.code {
        case .canceled:
            Reporter.shared.report(.debug, "passkey sheet closed")
            return .canceled
        case .matchedExcludedCredential:
            return .alreadyAdded
        default:
            // Most often the site association (webcredentials) isn't in place for this build.
            Reporter.shared.report(.warn, "passkey sheet failed", ["code": String((error as NSError).code)])
            return .unavailable
        }
    }
}

/// Whether this build's server takes passkeys this phone can use, as its
/// /api/config last said: learned once per launch (the sign-in screen tells
/// it too), since servers from before passkeys say nothing.
@MainActor @Observable final class PasskeySupport {
    static let shared = PasskeySupport()
    /// Nil until a server's config has been read.
    private(set) var offered: Bool?

    func learn(_ config: ServerConfig?) {
        guard let config else { return }  // couldn't ask: keep what's known
        offered = Passkeys.offered(rpID: config.passkeyRpId)
    }

    func check(server: String) async {
        learn(try? await Server(server).config())
    }
}

/// Profile › Security's row: there unless this server is known not to take
/// passkeys this phone can use (a development server, or one from before them).
struct PasskeysLink: View {
    let account: Account
    @State private var support = PasskeySupport.shared

    var body: some View {
        if support.offered != false {
            NavigationLink("Passkeys") { PasskeysScreen(account: account) }
                .task { if support.offered == nil { await support.check(server: account.server) } }
        }
    }
}

/// Profile › Security › Passkeys: yours, where each is kept, when it was added
/// and last used; adding one (the password, then Face ID); and removing one
/// (swipe, then confirm). It stops working everywhere; the password doesn't.
struct PasskeysScreen: View {
    @Environment(Session.self) private var session
    let account: Account
    var authenticator: any PasskeyAuthenticator = SystemPasskeys.shared
    /// Nil while loading.
    @State private var list: Session.PasskeyList?
    @State private var problem: String?
    @State private var note: String?
    @State private var adding = false
    @State private var removing: Session.Passkey?
    @State private var support = PasskeySupport.shared

    /// Adding works with this server: as its config said, or the list's own site.
    private var canAdd: Bool {
        support.offered == true || list.map { authenticator.works(for: $0.rpId) } == true
    }

    var body: some View {
        List {
            Section {
                if let list {
                    if list.passkeys.isEmpty {
                        Text("No passkeys yet.").foregroundStyle(.secondary)
                    }
                    ForEach(list.passkeys) { passkey in
                        PasskeyRow(passkey: passkey)
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Remove") { removing = passkey }.tint(.red)
                            }
                    }
                } else if let problem {
                    Text(problem).foregroundStyle(.red)
                } else {
                    Text("Loading…").foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A passkey signs you in with \(AppLock.method) instead of your password, and unlocks your messages too. Your password and recovery key keep working.")
                    if list?.passkeys.isEmpty == false { Text("Swipe left on one to remove it.") }
                }
            }
            if canAdd {
                Section {
                    Button("Add a passkey") { note = nil; adding = true }
                        .disabled((list?.passkeys.count ?? 0) >= Session.maxPasskeys)
                } footer: {
                    if let note {
                        Text(note)
                    } else if let count = list?.passkeys.count, count >= Session.maxPasskeys {
                        Text("You have \(Session.maxPasskeys) passkeys, the most there can be. Remove one first.")
                    }
                }
            }
        }
        .navigationTitle("Passkeys")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) {
            AddPasskeySheet(authenticator: authenticator) { added in
                // Shown at once; the list from the server follows.
                if let current = list, !current.passkeys.contains(where: { $0.id == added.id }) {
                    list = Session.PasskeyList(passkeys: current.passkeys + [added], rpId: current.rpId)
                }
                note = "Passkey added. Next time, sign in with it."
                Task { await load() }
            }
        }
        .confirmationDialog("Remove this passkey?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { passkey in
            Button("Remove passkey", role: .destructive) { Task { await remove(passkey) } }
        } message: { _ in
            Text("It stops signing you in to napsack, on every device. Your password still works.")
        }
    }

    private func load() async {
        do {
            list = try await session.passkeys()
            problem = nil
        } catch {
            if list == nil { problem = error.localizedDescription }  // keep what's shown
            session.noticed(error)
        }
    }

    private func remove(_ passkey: Session.Passkey) async {
        guard let current = list else { return }
        do {
            try await session.removePasskey(passkey, rpID: current.rpId, using: authenticator)
            list = Session.PasskeyList(passkeys: current.passkeys.filter { $0.id != passkey.id }, rpId: current.rpId)
            note = "Passkey removed."
        } catch {
            note = error.localizedDescription
            session.noticed(error)
            await load()
        }
    }
}

/// One passkey: where it's kept ("iCloud Keychain", when it's a known one),
/// when it was added, and when it last signed you in.
struct PasskeyRow: View {
    let passkey: Session.Passkey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(passkey.provider ?? "Passkey")
            Text(Self.when(passkey)).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Added Nov 3, 2026 · Last used Nov 5, 2026", or "· Not used yet".
    static func when(_ passkey: Session.Passkey) -> String {
        func day(_ t: Int64) -> String { Date(timeIntervalSince1970: TimeInterval(t)).formatted(date: .abbreviated, time: .omitted) }
        return "Added \(day(passkey.createdAt)) · " + (passkey.lastUsedAt.map { "Last used \(day($0))" } ?? "Not used yet")
    }
}

/// Adding a passkey from Security: the password first (it unlocks the key, so
/// the passkey can keep its own copy; a session alone can't add one), then
/// Face ID makes the passkey.
struct AddPasskeySheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let authenticator: any PasskeyAuthenticator
    let added: (Session.Passkey) -> Void
    @State private var password = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(submit)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enter your password to add a passkey. It unlocks your key here, so the passkey can unlock it too.")
                        if let problem { Text(problem).foregroundStyle(.red) }
                    }
                }
                Section {
                    Button(working ? "Adding…" : "Add a passkey", action: submit)
                        .disabled(working || password.isEmpty)
                }
            }
            .navigationTitle("Add a passkey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) } }
            .interactiveDismissDisabled(working)
        }
    }

    private func submit() {
        guard !working, !password.isEmpty else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                added(try await session.addPasskey(password: password, using: authenticator))
                dismiss()
            } catch PasskeyError.canceled {
                // Closed the sheet: nothing to say, and nothing was added.
            } catch {
                problem = error.localizedDescription
                session.noticed(error)
            }
        }
    }
}

/// Right after signing up, after the recovery key (Nate, 2026-11-03): napsack
/// recommends a passkey. It's added with the keys sign-up still holds in
/// memory, so the password isn't asked for again; "Not now" lets them go.
struct PasskeyOfferScreen: View {
    @Environment(Session.self) private var session
    var authenticator: any PasskeyAuthenticator = SystemPasskeys.shared
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Sign in with \(AppLock.method) next time")
                            .font(.title3.bold())
                        Text("A passkey signs you in without your password, and unlocks your messages too. Your password and recovery key keep working.")
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                Section {
                    Button(action: add) { Text(working ? "Adding…" : "Add a passkey").bold() }
                        .disabled(working)
                    Button("Not now") { session.passkeyOffer = nil }
                        .disabled(working)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem { Text(problem).foregroundStyle(.red) }
                        Text("You can add or remove passkeys any time in Profile › Security.")
                    }
                }
            }
            .navigationTitle("Sign in faster")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func add() {
        guard !working else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                _ = try await session.addOfferedPasskey(using: authenticator)  // the offer's done: this closes
            } catch PasskeyError.canceled {
                // Closed the sheet: still here, to try again or say not now.
            } catch {
                problem = error.localizedDescription
                session.noticed(error)
            }
        }
    }
}
