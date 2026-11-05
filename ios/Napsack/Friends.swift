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
    /// Your friends (the chat list's), for the list of them and the friend map's names.
    var friends: [Int64: Friend] = [:]
    /// Friends' names as you call them (for the friend map).
    var friendNames: [Int64: String] { friends.mapValues(\.name) }

    init(account: Account, friends: [Int64: Friend] = [:], transport: any Transport = NetworkTransport()) {
        self.account = account
        self.friends = friends
        self.transport = transport
    }

    /// Your friends as a list, by name: not Team Napsack (no one to visit).
    var friendList: [Person] {
        friends.values.filter { $0.system != true }.map(Person.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var server: Server {
        get throws { try Server(account.server, transport: transport) }
    }

    /// The site's address, when the server says it (links must open the
    /// site, not the API's own name).
    private(set) var site: String?

    /// A path the server gives (`/i/<token>`) as a link people can open: on
    /// the site, or the server's own address in development.
    func address(_ path: String) -> String {
        (site ?? account.server).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
    }

    func load() async throws {
        let server = try server
        async let requests = server.send("friends/requests", token: account.token)
        async let link = server.send("friend-link", token: account.token)
        async let config = server.config()
        self.requests = try Server.decoder.decode(Requests.self, from: await requests)
        self.link = try Server.decoder.decode(Link.self, from: await link)
        site = (try? await config)?.siteUrl
    }

    func loadRequests() async throws {
        requests = try Server.decoder.decode(Requests.self, from: await server.send("friends/requests", token: account.token))
    }

    /// Asks someone to be friends; if they'd asked you, you're friends now. In the web's words.
    func add(_ typed: String) async throws -> String {
        try await ask(typed).words
    }

    /// The same, and whether you're friends now.
    func ask(_ typed: String) async throws -> (friends: Bool, words: String) {
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
            ? (true, "You and \(answer.user.username)\(was) are now friends.")
            : (false, "Request sent to \(answer.user.username)\(was).")
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
    /// Your friends, as the chat list has them now (a request accepted here joins them).
    var friends: [Int64: Friend] = [:]
    @State private var username = ""
    @State private var note: String?
    @State private var copied = false
    @State private var scanning = false
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        List {
            if !model.requests.incoming.isEmpty {
                Section("Wants to be friends") {
                    ForEach(model.requests.incoming) { request in
                        // Not friends yet: their username and the initial (X45); a tap opens what their profile can show.
                        PersonLink(person: Person(id: request.id, username: request.username, friends: [:]), account: model.account,
                                   standing: .askedYou) {
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
                        Text("Friends can scan this with their phone's camera, or open your link. Someone new to napsack signs up with it and you're friends.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        // A matched, quiet pair: the same style, size, and width, icon and words in
                        // the text's own color (the pale accent is hard to read as a fill or as text).
                        // Side by side while their words fit on one line each; otherwise one above the other.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { linkButtons(address) }
                            VStack(spacing: 12) { linkButtons(address) }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .task(id: copied) {
                            guard copied else { return }
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Button("Scan their code", systemImage: "qrcode.viewfinder") { scanning = true }
                // With the largest text, the button under the field, so neither is squeezed to a sliver.
                (textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
                    TextField("Add by username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                        .onSubmit(add)
                    Button("Send request", action: add).disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .buttonStyle(.borderless)  // each its own tap, not the whole row's
            } header: {
                Text("Add a friend")
            } footer: {
                Text(note ?? "Show them your code, scan theirs, send them your link, or type their username.")
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
                        PersonLink(person: Person(id: request.id, username: request.username, friends: [:]), account: model.account,
                                   standing: .youAsked) {
                            Button("Cancel request") { act { try await model.dismiss(request) } }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            let friends = model.friendList
            if !friends.isEmpty {
                Section("Your friends (\(friends.count))") {
                    ForEach(friends) { person in
                        PersonLink(person: person, account: model.account, friends: model.friends)
                    }
                }
            }
        }
        .navigationTitle("Friends")
        // What it finds is offered as any opened link is (ChatListScreen).
        .sheet(isPresented: $scanning) { ScanScreen { url in Task { await FriendLinks.shared.open(url) } } }
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: friends, initial: true) { _, now in model.friends = now }
    }

    /// Share and Copy link, laid out by whoever holds them.
    @ViewBuilder private func linkButtons(_ address: String) -> some View {
        ShareLink(item: URL(string: address)!) {
            LinkButtonLabel(text: "Share", symbol: "square.and.arrow.up")
        }
        Button {
            UIPasteboard.general.string = address
            copied = true
        } label: {
            LinkButtonLabel(text: copied ? "Copied" : "Copy link", symbol: copied ? "checkmark" : "link")
        }
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

/// Share and Copy link's insides: the icon at the words' size and in their color.
private struct LinkButtonLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
    }
}
