import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Friend requests, your add-me link, and invite links (the web app's Friends
/// sheet; friends.rs and invites.rs).
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

    struct Invite: Decodable, Identifiable, Equatable, Sendable {
        struct Joined: Decodable, Equatable, Sendable {
            let id: Int64
            let username: String
        }
        let id: Int64
        let createdAt: Int64
        let expiresAt: Int64
        let maxUses: Int
        let revokedAt: Int64?
        let live: Bool
        let joined: [Joined]
    }

    private(set) var requests = Requests(incoming: [], outgoing: [])
    private(set) var link: Link?
    private(set) var invites: [Invite] = []
    /// A one-time invite link just made: its address is shown only now.
    private(set) var madeInvite: String?

    private let account: Account
    private let transport: any Transport

    init(account: Account, transport: any Transport = NetworkTransport()) {
        self.account = account
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
        async let invites = server.send("invites", token: account.token)
        self.requests = try Server.decoder.decode(Requests.self, from: await requests)
        self.link = try Server.decoder.decode(Link.self, from: await link)
        self.invites = try Server.decoder.decode([Invite].self, from: await invites)
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

    /// The old link stops working at once; a new one starts.
    func resetLink() async throws {
        link = try Server.decoder.decode(Link.self, from: await server.send("friend-link/reset", method: "POST", token: account.token))
    }

    /// A one-time invite link: 10 people, 7 days.
    func makeInvite() async throws {
        struct Made: Decodable { let path: String }
        let made = try Server.decoder.decode(Made.self, from: await server.send("invites", method: "POST", token: account.token))
        madeInvite = address(made.path)
        invites = try Server.decoder.decode([Invite].self, from: await server.send("invites", token: account.token))
    }

    func revoke(_ invite: Invite) async throws {
        _ = try await server.send("invites/\(invite.id)/revoke", method: "POST", token: account.token)
        invites = try Server.decoder.decode([Invite].self, from: await server.send("invites", token: account.token))
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
/// their username), who you're waiting on, and more ways to invite.
struct FriendsScreen: View {
    @Environment(Session.self) private var session
    @State var model: FriendsModel
    @State private var username = ""
    @State private var note: String?
    @State private var linkNote: String?
    @State private var inviteNote: String?
    @State private var confirmingReset = false
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
            Section {
                Button("Reset my link", role: .destructive) { confirmingReset = true }
                Button("Make an invite link") {
                    act { try await model.makeInvite() } failed: { inviteNote = $0 }
                }
                if let made = model.madeInvite {
                    VStack(spacing: 8) {
                        QRCode(text: made).frame(width: 160, height: 160).padding(6)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        Text(made).font(.footnote).textSelection(.enabled)
                        ShareLink(item: URL(string: made)!) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    .frame(maxWidth: .infinity)
                }
                ForEach(model.invites) { invite in
                    HStack {
                        Text(describe(invite)).font(.footnote)
                        Spacer()
                        if invite.live {
                            Button("Turn off") {
                                act { try await model.revoke(invite); inviteNote = "That link no longer works." } failed: { inviteNote = $0 }
                            }
                            .buttonStyle(.bordered).font(.footnote)
                        }
                    }
                }
            } header: {
                Text("More")
            } footer: {
                Text([linkNote, inviteNote].compactMap { $0 }.first
                     ?? "Your code and link keep working until you reset them. If one got out to someone it shouldn't have, reset it: the old one stops working at once. Or make a one-time invite link: it works for 10 people for 7 days.")
            }
        }
        .navigationTitle("Friends")
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Reset your link?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset my link", role: .destructive) {
                act { try await model.resetLink(); copied = false; linkNote = "Your old code and link no longer work." } failed: { linkNote = $0 }
            }
        } message: {
            Text("Your current code and link stop working at once. Anyone you've shared them with will need the new one.")
        }
    }

    private func describe(_ invite: FriendsModel.Invite) -> String {
        let date = { (t: Int64) in Date(timeIntervalSince1970: TimeInterval(t)).formatted(date: .abbreviated, time: .omitted) }
        let state = invite.live ? "until \(date(invite.expiresAt))" : invite.revokedAt != nil ? "turned off" : "finished"
        let who = invite.joined.isEmpty ? "" : " · " + invite.joined.map(\.username).joined(separator: ", ")
        return "Link from \(date(invite.createdAt)) · \(invite.joined.count) of \(invite.maxUses) used, \(state)\(who)"
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
