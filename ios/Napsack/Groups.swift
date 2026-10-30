import PhotosUI
import SwiftUI

/// A group's details and what members can change (groups.rs): its name and
/// picture (neither end-to-end encrypted: every client says so), who's in it,
/// adding friends, removing people (the owner only), and leaving.
@MainActor @Observable final class GroupModel {
    struct Member: Decodable, Identifiable, Sendable {
        let id: Int64
        let username: String
        let role: String
        let joinedAt: Int64
    }

    struct Detail: Decodable, Sendable {
        let id: Int64
        let name: String
        let role: String
        let members: [Member]
    }

    private(set) var detail: Detail?
    let id: Int64
    private let account: Account
    private let transport: any Transport

    init(id: Int64, account: Account, transport: any Transport = NetworkTransport()) {
        self.id = id
        self.account = account
        self.transport = transport
    }

    private var server: Server { get throws { try Server(account.server, transport: transport) } }
    var isOwner: Bool { detail?.role == "owner" }

    func load() async throws {
        detail = try Server.decoder.decode(Detail.self, from: await server.send("groups/\(id)", token: account.token))
    }

    func rename(_ name: String) async throws {
        struct Name: Encodable { let name: String }
        _ = try await server.send("groups/\(id)", method: "PATCH", token: account.token, json: Name(name: name.trimmingCharacters(in: .whitespaces)))
        try await load()
    }

    func add(_ friend: Int64) async throws {
        struct Add: Encodable { let userId: Int64 }
        _ = try await server.send("groups/\(id)/members", method: "POST", token: account.token, json: Add(userId: friend))
        try await load()
    }

    /// Removes someone (the owner only), or yourself: you leave. Nothing they sent goes.
    func remove(_ member: Int64) async throws {
        _ = try await server.send("groups/\(id)/members/\(member)", method: "DELETE", token: account.token)
        if member != account.user.id { try await load() }
    }

    /// The group's picture: squared and made small here; the server re-encodes it (images::clean).
    func setPicture(_ image: UIImage) async throws {
        guard let data = ProfileModel.avatarJPEG(image) else { throw ServerError.refused("Couldn't use that picture.", status: 400) }
        _ = try await server.upload("groups/\(id)/avatar", data: data, contentType: "image/jpeg", token: account.token)
    }

    /// A new group with some friends; you're its owner. Returns its id.
    static func create(name: String, members: [Int64], account: Account, transport: any Transport = NetworkTransport()) async throws -> Int64 {
        struct New: Encodable { let name: String; let memberIds: [Int64] }
        struct Made: Decodable { let id: Int64 }
        let data = try await Server(account.server, transport: transport).send(
            "groups", method: "POST", token: account.token, json: New(name: name.trimmingCharacters(in: .whitespaces), memberIds: members))
        return try Server.decoder.decode(Made.self, from: data).id
    }
}

/// The group notice, in every client's words (CLAUDE.md, Security).
let groupPrivacyNote = "Messages and pics are end-to-end encrypted. The group's name and picture aren't: the napsack server can see them, so don't put anything private there. Reactions in groups aren't encrypted yet either."

/// A new group: a name and some friends.
struct NewGroupScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let account: Account
    /// Friends who can be added (not Team Napsack, not turned off).
    let friends: [Friend]
    let created: (Int64) -> Void
    @State private var name = ""
    @State private var picked: Set<Int64> = []
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group name", text: $name).onChange(of: name) { _, n in if n.count > 40 { name = String(n.prefix(40)) } }
                } footer: {
                    Text(groupPrivacyNote)
                }
                Section("Friends") {
                    if friends.isEmpty { Text("Add some friends first.").foregroundStyle(.secondary) }
                    ForEach(friends) { friend in
                        Button {
                            if picked.contains(friend.id) { picked.remove(friend.id) } else { picked.insert(friend.id) }
                        } label: {
                            HStack {
                                Avatar(kind: .friend(friend.id), avatarId: friend.avatarId, name: friend.name, size: 32)
                                Text(friend.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: picked.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(friend.id) ? Color.accentColor : .secondary)
                            }
                        }
                        .accessibilityAddTraits(picked.contains(friend.id) ? .isSelected : [])
                    }
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Creating…" : "Create") { create() }
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
                }
            }
        }
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            do {
                let id = try await GroupModel.create(name: name, members: Array(picked), account: account)
                Reporter.shared.report(.info, "group created", ["group_id": String(id), "members": String(picked.count)])
                dismiss()
                created(id)
            } catch {
                problem = error.localizedDescription
                session.noticed(error)
            }
        }
    }
}

/// A group's info: the notice, its name and picture, members, adding friends, leaving.
struct GroupInfoScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(Pictures.self) private var pictures: Pictures?
    @State var model: GroupModel
    let account: Account
    let avatarId: Int64?
    /// Your friends, for adding and for names.
    let friends: [Int64: Friend]
    let left: () -> Void
    @State private var name = ""
    @State private var picked: PhotosPickerItem?
    @State private var note: String?
    @State private var confirmingLeave = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Avatar(kind: .group(model.id), avatarId: avatarId, name: model.detail?.name ?? "", size: 88)
                    PhotosPicker("Change group picture", selection: $picked, matching: .images).font(.callout)
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text(groupPrivacyNote)
            }
            Section("Name") {
                HStack {
                    TextField("Group name", text: $name)
                    Button("Rename") { act { try await model.rename(name); note = "Renamed." } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == model.detail?.name)
                }
            }
            if let detail = model.detail {
                Section {
                    ForEach(detail.members) { member in
                        HStack {
                            Text(display(member))
                            Spacer()
                            if member.role == "owner" { Text("Owner").font(.caption).foregroundStyle(.secondary) }
                        }
                        .swipeActions {
                            if model.isOwner && member.id != account.user.id {
                                Button("Remove", role: .destructive) { act { try await model.remove(member.id); note = "Removed \(display(member)). Everything they sent stays." } }
                            }
                        }
                    }
                } header: {
                    Text("Members (\(detail.members.count))")
                } footer: {
                    Text(model.isOwner ? "You're the owner, so you can remove people (swipe). Everything they sent stays in the chat."
                         : "Only \(detail.members.first { $0.role == "owner" }.map(display) ?? "the owner") can remove people. You can add your friends.")
                }
                let addable = friends.values.filter { f in f.system != true && f.deactivated != true && !detail.members.contains { $0.id == f.id } }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if !addable.isEmpty {
                    Section("Add friends") {
                        ForEach(addable) { friend in
                            HStack {
                                Text(friend.name)
                                Spacer()
                                Button("Add") { act { try await model.add(friend.id); note = "Added \(friend.name). They'll see messages from now on." } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            Section {
                Button("Leave group", role: .destructive) { confirmingLeave = true }
            } footer: {
                if let note { Text(note) }
            }
        }
        .navigationTitle(model.detail?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                try await model.load()
                name = model.detail?.name ?? ""
            } catch {
                note = error.localizedDescription
                session.noticed(error)
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                defer { picked = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    note = "Couldn't open that picture."
                    return
                }
                act {
                    try await model.setPicture(image)
                    note = "Group picture changed."
                }
            }
        }
        .confirmationDialog("Leave \(model.detail?.name ?? "this group")?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                act {
                    try await model.remove(account.user.id)
                    left()
                    dismiss()
                }
            }
        } message: {
            Text("You won't get its new messages. Someone in it can add you back.")
        }
    }

    private func display(_ member: GroupModel.Member) -> String {
        member.id == account.user.id ? "You" : friends[member.id]?.name ?? member.username
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch {
                note = error.localizedDescription
                session.noticed(error)
            }
        }
    }
}
