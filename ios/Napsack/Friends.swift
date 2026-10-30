import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Friend requests and your add-a-friend link: one link that adds you and
/// signs someone new up as your friend, never changing (the web app's Friends
/// sheet; friends.rs and invites.rs; X39).
@MainActor @Observable final class FriendsModel {
    struct Request: Decodable, Identifiable, Equatable, Sendable {
        let id: Int64
        let username: String
        let createdAt: Int64
    }

    struct Requests: Decodable, Equatable, Sendable {
        var incoming: [Request]
        var outgoing: [Request]
    }

    struct Link: Decodable, Equatable, Sendable {
        let path: String
        let createdAt: Int64?
        let uses: Int?
    }

    private(set) var requests = Requests(incoming: [], outgoing: [])
    private(set) var link: Link?

    let account: Account
    private let transport: any Transport
    /// Friends' names as you call them (for the friend map); the chat list's.
    var friendNames: [Int64: String] = [:]

    init(account: Account, friendNames: [Int64: String] = [:], transport: any Transport = NetworkTransport()) {
        self.account = account
        self.friendNames = friendNames
        self.transport = transport
    }

    private var server: Server {
        get throws { try Server(account.server, transport: transport) }
    }

    /// A path the server gives (`/i/<token>`) as a link people can open.
    func address(_ path: String) -> String {
        account.server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
    }

    func load() async throws {
        let server = try server
        async let requests = server.send("friends/requests", token: account.token)
        async let link = server.send("friend-link", token: account.token)
        self.requests = try Server.decoder.decode(Requests.self, from: await requests)
        self.link = try Server.decoder.decode(Link.self, from: await link)
    }

    func loadRequests() async throws {
        requests = try Server.decoder.decode(Requests.self, from: await server.send("friends/requests", token: account.token))
    }

    /// Asks someone to be friends; if they'd asked you, you're friends now. In the web's words.
    func add(_ typed: String) async throws -> String {
        let username = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Ask: Encodable { let username: String }
        struct Answer: Decodable {
            struct User: Decodable { let username: String }
            let status: String
            let user: User
        }
        let answer = try Server.decoder.decode(Answer.self, from: await server.send(
            "friends/requests", method: "POST", token: account.token, json: Ask(username: username)))
        // An old username still finds them: say what they're called now.
        let was = answer.user.username.lowercased() != username.lowercased() ? " (was @\(username))" : ""
        try? await loadRequests()
        return answer.status == "friends"
            ? "You and \(answer.user.username)\(was) are now friends."
            : "Request sent to \(answer.user.username)\(was)."
    }

    func accept(_ request: Request) async throws {
        _ = try await server.send("friends/requests/\(request.id)/accept", method: "POST", token: account.token)
        try await loadRequests()
    }

    /// Declines theirs, or cancels yours.
    func dismiss(_ request: Request) async throws {
        _ = try await server.send("friends/requests/\(request.id)", method: "DELETE", token: account.token)
        try await loadRequests()
    }
}

/// A QR code for a link, drawn on the phone (CoreImage), crisp at any size.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .accessibilityLabel("QR code for your link")
        }
    }

    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Friends: who wants to be friends, adding someone (your code and link, or
/// their username), and who you're waiting on.
struct FriendsScreen: View {
    @Environment(Session.self) private var session
    @State var model: FriendsModel
    @State private var username = ""
    @State private var note: String?
    @State private var copied = false

    var body: some View {
        List {
            if !model.requests.incoming.isEmpty {
                Section("Wants to be friends") {
                    ForEach(model.requests.incoming) { request in
                        HStack {
                            Text(request.username)
                            Spacer()
                            Button("Accept") { act { try await model.accept(request) } }.buttonStyle(.borderedProminent)
                            Button("Decline") { act { try await model.dismiss(request) } }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section {
                if let link = model.link {
                    let address = model.address(link.path)
                    VStack(spacing: 12) {
                        QRCode(text: address).frame(width: 200, height: 200).padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        Text("They scan it with their phone's camera, or open your link. Someone new to napsack signs up with it and you're friends.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack {
                            ShareLink(item: URL(string: address)!) { Label("Share", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.borderedProminent)
                            Button(copied ? "Copied" : "Copy link", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = address
                                copied = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                HStack {
                    TextField("Add by username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                        .onSubmit(add)
                    Button("Send request", action: add).disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Add a friend")
            } footer: {
                Text(note ?? "Show them your code, send them your link, or type their username.")
            }
            Section {
                NavigationLink {
                    FriendMapScreen(model: FriendMapModel(account: model.account), names: model.friendNames, me: model.account.user.username)
                } label: {
                    Label("See your friend map", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            if !model.requests.outgoing.isEmpty {
                Section("Waiting on them") {
                    ForEach(model.requests.outgoing) { request in
                        HStack {
                            Text(request.username)
                            Spacer()
                            Button("Cancel request") { act { try await model.dismiss(request) } }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .refreshable { await load() }
        .task { await load() }
    }

    private func add() {
        let typed = username
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        act {
            note = try await model.add(typed)
            username = ""
        } failed: { note = $0 }
    }

    private func load() async {
        do { try await model.load() } catch {
            Reporter.shared.report(.warn, "loading friends failed", Reporter.fields(error))
            session.noticed(error)
        }
    }

    private func act(_ work: @escaping () async throws -> Void, failed: ((String) -> Void)? = nil) {
        Task {
            do { try await work() } catch {
                session.noticed(error)
                if let failed { failed(error.localizedDescription) } else { note = error.localizedDescription }
            }
        }
    }
}
