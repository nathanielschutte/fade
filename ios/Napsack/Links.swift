import SwiftUI
import VisionKit

/// Add-a-friend links (`/i/<token>`, invites.rs), as the web app reads them
/// (app.js, `readInviteLink`): opened from anywhere on the phone (Universal
/// Links: the site's apple-app-site-association names this app) or scanned
/// from a friend's QR here. Signed in, it asks "Add Ana?" (ChatListScreen);
/// signed out, the sign-up form says who invited you, and the new account
/// starts out friends with them (SignInScreen).
@MainActor @Observable final class FriendLinks {
    static let shared = FriendLinks()

    struct Inviter: Decodable, Equatable, Sendable {
        let id: Int64
        let username: String
    }

    /// A link opened: whose it is, once the server says, or why it doesn't work.
    struct Invite: Equatable {
        let token: String
        var inviter: Inviter?
        var problem: String?
    }

    var pending: Invite?

    /// The token in a napsack link: `/i/` and 22 characters, as the server
    /// makes them. Any host: the server this build talks to decides whether
    /// it's a link it knows.
    nonisolated static func token(in url: URL) -> String? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "i", parts[1].count == 22,
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return String(parts[1])
    }

    /// A link was opened or scanned: look up whose it is (signed in or out).
    /// Returns false if it isn't a napsack link.
    @discardableResult
    func open(_ url: URL, server: String = AppInfo.server) async -> Bool {
        guard let token = Self.token(in: url) else { return false }
        var invite = Invite(token: token)
        pending = invite
        do {
            struct Lookup: Decodable { let inviter: Inviter }
            let data = try await Server(server).send("invites/lookup/\(token)")
            invite.inviter = try Server.decoder.decode(Lookup.self, from: data).inviter
        } catch {
            invite.problem = error.localizedDescription
            Reporter.shared.report(.info, "friend link didn't work")
        }
        if pending?.token == token { pending = invite }  // unless another link came since
        return true
    }

    /// Signed in: become friends with whoever's link it is (`POST /api/invites/accept`).
    static func accept(_ token: String, account: Account) async throws -> Inviter {
        struct Accept: Encodable { let token: String }
        struct Answer: Decodable { let friend: Inviter }
        let data = try await Server(account.server).send("invites/accept", method: "POST", token: account.token, json: Accept(token: token))
        return try Server.decoder.decode(Answer.self, from: data).friend
    }
}

/// The camera, looking for a napsack QR code (VisionKit's data scanner). The
/// first one it sees is the answer; anything else is ignored.
struct QRScanner: UIViewControllerRepresentable {
    let found: (URL) -> Void

    /// Phones with a camera that can scan (not the Simulator).
    static var available: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (URL) -> Void
        private var done = false

        init(found: @escaping (URL) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let code) = item, let text = code.payloadStringValue,
                      let url = URL(string: text), FriendLinks.token(in: url) != nil else { continue }
                done = true
                found(url)
            }
        }
    }
}

/// The scanner as a sheet: point it at a friend's code.
struct ScanScreen: View {
    @Environment(\.dismiss) private var dismiss
    let found: (URL) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if QRScanner.available {
                    QRScanner { url in
                        dismiss()
                        found(url)
                    }
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Can't scan here", systemImage: "qrcode.viewfinder",
                                           description: Text("Scanning needs the camera. Allow it in Settings › napsack, or open their link instead."))
                }
            }
            .navigationTitle("Scan their code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
