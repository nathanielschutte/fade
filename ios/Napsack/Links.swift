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

/// A link in a text to a chat in napsack itself: the app's own site with a
/// route after the `#`, as the web app reads them (`#chat=7`, `#group=3`),
/// optionally at one message (`&message=12`). Team Napsack's warnings carry
/// one ("Open it: <site>/#group=3&message=12", report-and-block.md). Only
/// these become tappable in a text, and they open inside the app; no other
/// link does (no data detectors), so a text can't send anyone to a site of
/// its choosing.
struct ChatLink: Equatable, Sendable {
    let kind: ChatRow.Kind
    /// The message to show, if it names one.
    let message: Int64?

    init(kind: ChatRow.Kind, message: Int64?) {
        self.kind = kind
        self.message = message
    }

    /// The route in a link to `site`, the app's own: its scheme, host, and
    /// port exactly, nothing else before the `#`, and a route after it. Nil for anything else.
    init?(_ url: URL, site: String?) {
        guard let site, let own = URLComponents(string: site.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))),
              let ownScheme = own.scheme?.lowercased(), ["https", "http"].contains(ownScheme),
              let ownHost = own.host?.lowercased(), !ownHost.isEmpty,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == ownScheme, parts.host?.lowercased() == ownHost, parts.port == own.port,
              parts.user == nil, parts.password == nil, parts.query == nil,
              ["", "/"].contains(parts.percentEncodedPath),
              let route = Self.route(parts.percentEncodedFragment) else { return nil }
        (kind, message) = route
    }

    /// `chat=<id>` or `group=<id>`, then `&message=<id>` or nothing: digits only, every id above 0.
    private static func route(_ fragment: String?) -> (ChatRow.Kind, Int64?)? {
        guard let fragment else { return nil }
        let pairs = fragment.split(separator: "&", omittingEmptySubsequences: false).map {
            $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        }
        func id(_ s: String) -> Int64? {
            guard (1...18).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int64(s), n > 0 else { return nil }
            return n
        }
        guard (1...2).contains(pairs.count), pairs.allSatisfy({ $0.count == 2 }), let chat = id(pairs[0][1]) else { return nil }
        let kind: ChatRow.Kind
        switch pairs[0][0] {
        case "chat": kind = .friend(chat)
        case "group": kind = .group(chat)
        default: return nil
        }
        guard pairs.count == 2 else { return (kind, nil) }
        guard pairs[1][0] == "message", let message = id(pairs[1][1]) else { return nil }
        return (kind, message)
    }

    /// Punctuation around a link in a sentence, which isn't part of it.
    private static let punctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "(", ")", "[", "]", "{", "}", "'", "\"", "<", ">"]

    /// A text with its links to the app's own chats tappable, each where it's
    /// written and as written; everything else stays plain text, links to
    /// anywhere else included.
    static func linked(_ text: String, site: String?) -> AttributedString {
        var attributed = AttributedString(text)
        // Cheap first: almost no text has one.
        guard site != nil, text.contains("#chat=") || text.contains("#group=") else { return attributed }
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            var lower = word.startIndex, upper = word.endIndex
            while lower < upper, Self.punctuation.contains(text[lower]) { lower = text.index(after: lower) }
            while upper > lower, Self.punctuation.contains(text[text.index(before: upper)]) { upper = text.index(before: upper) }
            let candidate = String(text[lower..<upper])
            guard candidate.contains("#"), let url = URL(string: candidate), ChatLink(url, site: site) != nil,
                  let range = Range(lower..<upper, in: attributed) else { continue }
            attributed[range].link = url
        }
        return attributed
    }
}

extension EnvironmentValues {
    /// The app's own site (`site_url`, or the server's address where there's
    /// none): links in texts to it open their chat (ChatLink).
    @Entry var ownSite: String? = nil
    /// Opens a chat from a link in a text (the chat list sets it).
    @Entry var openChatLink: OpenChatLink? = nil
}

/// Opens a chat from a link in a text, at its message if it names one, and
/// says why not if it can't. Always equal to another: the chat list's own
/// state is what it works on, so a newer copy does nothing different, and
/// screens needn't redraw for one.
struct OpenChatLink: Equatable {
    let run: @MainActor (ChatLink) async -> String?

    @MainActor func callAsFunction(_ link: ChatLink) async -> String? { await run(link) }

    static func == (_: OpenChatLink, _: OpenChatLink) -> Bool { true }
}
