import PhotosUI
import SwiftUI
import UIKit

/// Profile and group pictures for this session: fetched with the session's
/// token, kept in memory only (gone with the session), each fetched once even
/// when several rows ask at the same time.
@MainActor @Observable final class Pictures {
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: [String: Task<Void, Never>] = [:]
    private let account: Account
    private let transport: any Transport

    init(account: Account, transport: any Transport = NetworkTransport()) {
        self.account = account
        self.transport = transport
    }

    static func path(_ kind: ChatRow.Kind, avatar: Int64) -> String {
        switch kind {
        case .friend(let id): "users/\(id)/avatar/\(avatar)"
        case .group(let id): "groups/\(id)/avatar/\(avatar)"
        }
    }

    func load(_ path: String) async {
        if images[path] != nil { return }
        if let pending = loading[path] { return await pending.value }  // already on its way
        let account = account, transport = transport
        let task = Task { [weak self] in
            let data = try? await Server(account.server, transport: transport).send(path, token: account.token)
            if let data, let image = UIImage(data: data) { self?.images[path] = image }
            self?.loading[path] = nil
        }
        loading[path] = task
        await task.value
    }

    /// A picture just changed: fetch it again next time.
    func forget(_ path: String) {
        images[path] = nil
    }
}

/// Saves one at a time, in order, keeping only the newest of those waiting:
/// a setting changed many times quickly (a date wheel spun) sends the value
/// it stopped on, and never an older value after a newer one.
@MainActor final class LatestSave {
    private var newest = 0
    private var last: Task<Void, Never>?

    func save(after delay: Duration = .milliseconds(600), _ work: @escaping @MainActor () async throws -> Void,
              done: @escaping @MainActor ((any Error)?) -> Void) {
        newest += 1
        let mine = newest
        let previous = last
        last = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            await previous?.value  // after the one before has finished: the order holds down the chain
            // A newer one is waiting and will send. (One already on its way
            // is never cut off: the server may have it.)
            guard let self, mine == self.newest else { return }
            do { try await work(); done(nil) } catch { done(error) }
        }
    }
}

/// A picture shown big, from tapping it (a profile's or a group's).
struct BigPicture: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .accessibilityAddTraits(.isButton).accessibilityLabel("Close")
    }
}

/// A friend's or group's picture, or their initial until it's in.
struct Avatar: View {
    @Environment(Pictures.self) private var pictures: Pictures?
    let kind: ChatRow.Kind
    let avatarId: Int64?
    let name: String
    var size: CGFloat = 44
    /// Tapping it shows it big (profiles and group info, not the list).
    var enlarges = false
    @State private var big: UIImage?

    var body: some View {
        let path = avatarId.map { Pictures.path(kind, avatar: $0) }
        let group = if case .group = kind { true } else { false }
        Group {
            if let path, let image = pictures?.images[path] {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(group ? AnyShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)) : AnyShape(Circle()))
                    .accessibilityHidden(!enlarges)
                    .onTapGesture { if enlarges { big = image } }
                    .accessibilityAddTraits(enlarges ? .isButton : [])
                    .accessibilityLabel(enlarges ? "Picture of \(name). Tap to see it big" : "")
            } else {
                Initial(name: name, group: group, size: size)
            }
        }
        .task(id: path) { if let path { await pictures?.load(path) } }
        .fullScreenCover(item: Binding(get: { big.map(IdentifiedImage.init) }, set: { big = $0?.image })) { BigPicture(image: $0.image) }
    }
}

// ---------- a friend's profile ----------

struct Profile: Decodable, Sendable {
    struct Birthday: Decodable, Sendable, Equatable {
        let month: Int
        let day: Int
        let year: Int?
    }
    struct Person: Decodable, Sendable, Identifiable {
        let id: Int64
        let username: String
        let since: Int64
    }
    struct Together: Decodable, Sendable {
        let texts: Int
        let pics: Int
        let firstMessageAt: Int64?
    }
    struct Streak: Decodable, Sendable {
        let current: Int
        let expiring: Bool
        let longest: Int
    }

    let kind: String
    let id: Int64
    let username: String
    let displayName: String?
    let nickname: String?
    let avatarId: Int64?
    let joinedAt: Int64
    let birthday: Birthday?
    let friendsSince: Int64?
    let friendCount: Int?
    let mutualFriends: [Person]?
    let together: Together?
    let streak: Streak?
    let pastUsernames: [String]
}

extension Profile.Birthday {
    /// "March 4" or "March 4, 1990".
    var words: String {
        var parts = DateComponents()
        parts.month = month
        parts.day = day
        parts.year = year ?? 2000
        guard let date = Calendar(identifier: .gregorian).date(from: parts) else { return "" }
        return year == nil ? date.formatted(.dateTime.month(.wide).day()) : date.formatted(date: .long, time: .omitted)
    }
}

/// Profiles and what you can change about them (profiles.rs, people.rs).
@MainActor @Observable final class ProfileModel {
    private(set) var profile: Profile?
    private let account: Account
    private let transport: any Transport

    init(account: Account, transport: any Transport = NetworkTransport()) {
        self.account = account
        self.transport = transport
    }

    private var server: Server { get throws { try Server(account.server, transport: transport) } }

    func load(_ id: Int64) async throws {
        let tz = URLQueryItem(name: "tz", value: String(TimeZone.current.secondsFromGMT() / 60))
        profile = try Server.decoder.decode(Profile.self, from: await server.send("users/\(id)/profile", token: account.token, query: [tz]))
    }

    private struct Name: Encodable { let name: String }

    /// A name only you see for them; empty clears it.
    func setNickname(_ name: String, for id: Int64) async throws {
        _ = try await server.send("friends/\(id)/nickname", method: "PUT", token: account.token, json: Name(name: name.trimmingCharacters(in: .whitespaces)))
        try await load(id)
    }

    /// Ends the friendship. History stays (Rule 1); you can be friends again.
    func unfriend(_ id: Int64) async throws {
        _ = try await server.send("friends/\(id)", method: "DELETE", token: account.token)
    }

    // ---------- your own ----------

    /// Your display name, seen by friends; empty clears it.
    func setName(_ name: String) async throws {
        _ = try await server.send("me/name", method: "PUT", token: account.token, json: Name(name: name.trimmingCharacters(in: .whitespaces)))
        try await load(account.user.id)
    }

    /// Your birthday for friends, the year optional; nil clears it.
    func setBirthday(month: Int?, day: Int?, year: Int?) async throws {
        struct Birthday: Encodable {
            let month: Int?, day: Int?, year: Int?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeIfPresent(month, forKey: .month)  // `{}` clears it
                try c.encodeIfPresent(day, forKey: .day)
                try c.encodeIfPresent(year, forKey: .year)
            }
            enum CodingKeys: String, CodingKey { case month, day, year }
        }
        _ = try await server.send("me/birthday", method: "PUT", token: account.token, json: Birthday(month: month, day: day, year: year))
        try await load(account.user.id)
    }

    /// A new picture: squared and made small on the phone (the server takes up
    /// to 128 KB and re-encodes it anyway; CLAUDE.md, images::clean).
    func setPicture(_ image: UIImage) async throws {
        guard let data = Self.avatarJPEG(image) else { throw ServerError.refused("Couldn't use that picture.", status: 400) }
        _ = try await server.upload("me/avatar", data: data, contentType: "image/jpeg", token: account.token)
        try await load(account.user.id)
    }

    func removePicture() async throws {
        _ = try await server.send("me/avatar", method: "DELETE", token: account.token)
        try await load(account.user.id)
    }

    /// The middle square, 512 pixels, as a JPEG under 128 KB.
    nonisolated static func avatarJPEG(_ image: UIImage, edge: CGFloat = 512, limit: Int = 120_000) -> Data? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format).image { _ in
            image.draw(in: CGRect(x: -crop.minX * edge / side, y: -crop.minY * edge / side,
                                  width: image.size.width * edge / side, height: image.size.height * edge / side))
        }
        for quality in stride(from: 0.85, through: 0.3, by: -0.1) {
            if let data = square.jpegData(compressionQuality: quality), data.count <= limit { return data }
        }
        return nil
    }
}

/// A friend's profile: who they are, what you share, and what you can do.
struct FriendProfileScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let friend: Friend
    let account: Account
    let safetyCode: String
    let unfriended: () -> Void
    @State var model: ProfileModel
    @State private var nickname = ""
    @State private var problem: String?
    @State private var confirmingUnfriend = false
    @State private var showingCode = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Avatar(kind: .friend(friend.id), avatarId: model.profile?.avatarId ?? friend.avatarId, name: friend.name, size: 96, enlarges: true)
                    Text(model.profile?.displayName ?? friend.username).font(.title2.bold())
                    Text("@\(friend.username)").foregroundStyle(.secondary)
                    if let past = model.profile?.pastUsernames, !past.isEmpty {
                        Text("Was " + past.map { "@\($0)" }.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            Section {
                HStack {
                    TextField("A name only you see", text: $nickname).onSubmit(saveNickname)
                    Button("Save", action: saveNickname).disabled(nickname == (model.profile?.nickname ?? ""))
                }
            } header: {
                Text("Nickname")
            }
            if let profile = model.profile {
                Section {
                    if let since = profile.friendsSince { LabeledContent("Friends since", value: date(since)) }
                    if let birthday = profile.birthday { LabeledContent("Birthday", value: birthday.words) }
                    if let streak = profile.streak, streak.current >= 3 || streak.longest >= 3 {
                        LabeledContent("Streak", value: "\(streak.current) days" + (streak.expiring ? " ⌛" : "") + " · longest \(streak.longest)")
                    }
                    if let together = profile.together {
                        LabeledContent("Texts together", value: "\(together.texts)")
                        LabeledContent("Pics together", value: "\(together.pics)")
                    }
                }
                if let mutual = profile.mutualFriends, !mutual.isEmpty {
                    Section("Friends in common") {
                        ForEach(mutual) { Text($0.username) }
                    }
                }
            }
            Section {
                Button("Compare safety codes", systemImage: "lock") { showingCode = true }
                Button("Unfriend", role: .destructive) { confirmingUnfriend = true }
            } footer: {
                if let problem { Text(problem).foregroundStyle(.red) }
            }
        }
        .navigationTitle(friend.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                try await model.load(friend.id)
                nickname = model.profile?.nickname ?? ""
            } catch {
                problem = error.localizedDescription
                session.noticed(error)
            }
        }
        .sheet(isPresented: $showingCode) {
            SafetyCodeScreen(username: friend.username, code: safetyCode, keyChanged: false) {}
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Unfriend \(friend.name)?", isPresented: $confirmingUnfriend, titleVisibility: .visible) {
            Button("Unfriend", role: .destructive) {
                Task {
                    do {
                        try await model.unfriend(friend.id)
                        Reporter.shared.report(.info, "unfriended", ["friend_id": String(friend.id)])
                        unfriended()
                        dismiss()
                    } catch {
                        problem = error.localizedDescription
                        session.noticed(error)
                    }
                }
            }
        } message: {
            Text("Your chat stays, but you can't send to each other until you're friends again.")
        }
    }

    private func date(_ t: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(t)).formatted(date: .long, time: .omitted)
    }

    private func saveNickname() {
        Task {
            do { try await model.setNickname(nickname, for: friend.id) } catch {
                problem = error.localizedDescription
                session.noticed(error)
            }
        }
    }
}

struct IdentifiedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
