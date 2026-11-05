import NapsackCrypto
import SwiftUI

// Lists of people (a group's members, Friends, requests, the pickers,
// Blocked): each person with their picture, named the one way the app names
// anyone, and a tap opens their profile (plan X45 to X47).

/// Someone in a list of people. Names follow one rule everywhere (X47):
/// your nickname for them, else their display name, else their username,
/// with `@username` beside it wherever the name shown differs. A display
/// name and a picture come only for friends (the server's rule, CLAUDE.md),
/// so anyone else is their username and the initial stand-in.
struct Person: Identifiable, Equatable, Sendable {
    let id: Int64
    let username: String
    /// Your friend, if they are one.
    let friend: Friend?

    init(_ friend: Friend) {
        id = friend.id
        username = friend.username
        self.friend = friend
    }

    /// Whoever has this id: a friend if they're in `friends`, else just their username.
    init(id: Int64, username: String, friends: [Int64: Friend]) {
        self.id = id
        friend = friends[id]
        self.username = friend?.username ?? username
    }

    /// What the app calls them (Friend.name for a friend).
    var name: String { friend?.name ?? username }
    /// "@username", shown beside the name only where the two differ.
    var handle: String? { Self.handle(name: name, username: username) }
    var avatarId: Int64? { friend?.avatarId }
    /// Team Napsack (team-napsack.md): no profile to open.
    var isTeam: Bool { friend?.system == true }
    var reportable: Reportable { Reportable(id: id, name: name) }

    static func handle(name: String, username: String) -> String? {
        name == username ? nil : "@\(username)"
    }
}

/// A person's picture (or initial), their name, and `@username` under it
/// where it differs; then whatever the row offers (`trailing`). Large text
/// or a narrow phone stacks the offers under the name.
struct PersonRow<Trailing: View>: View {
    let person: Person
    /// Yourself, in a group's members: "You", with your own picture.
    var me: Me? = nil
    var size: CGFloat = 36
    /// A line under the name ("Blocked Nov 3").
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                avatar
                HStack(spacing: 8) {
                    names
                    Spacer(minLength: 0)
                    trailing()
                }
            }
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 8) {
                    names
                    HStack(spacing: 8) { trailing() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A long name, or the largest text on the narrowest phone: the offers one above the other, under
            // the picture too, and with the largest text a size smaller, so their words fit ("Accept", not "Acce…").
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    avatar
                    names
                }
                VStack(alignment: .leading, spacing: 8) { trailing() }.controlSize(textSize.isAccessibilitySize ? .small : .regular)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var avatar: some View {
        Avatar(kind: .friend(person.id), avatarId: me?.avatarId ?? person.avatarId, name: me?.username ?? person.name, size: size)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(me == nil ? person.name : "You").foregroundStyle(.primary)
            if me == nil, let handle = person.handle {
                Text(handle).font(.caption).foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .lineLimit(textSize.isAccessibilitySize ? 3 : 1)  // the largest text: a long name wraps rather than ending at its first letters
    }
}

extension PersonRow where Trailing == EmptyView {
    init(person: Person, me: Me? = nil, size: CGFloat = 36, detail: String? = nil) {
        self.init(person: person, me: me, size: size, detail: detail, trailing: { EmptyView() })
    }
}

/// A person's row that opens their profile when tapped (X46), as a chat's
/// title does: a friend's whole profile, or what anyone else's can show.
/// Yourself and Team Napsack have none here. A pushed screen, so it works in
/// every list (each is in a navigation stack already).
struct PersonLink<Trailing: View>: View {
    let person: Person
    let account: Account
    /// Your friends, for naming the people a profile lists.
    var friends: [Int64: Friend] = [:]
    var standing: PersonProfileScreen.Standing = .stranger
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        if person.id == account.user.id {
            PersonRow(person: person, me: account.user, detail: detail, trailing: trailing)
        } else if person.isTeam {
            PersonRow(person: person, detail: detail, trailing: trailing)
        } else {
            NavigationLink {
                ProfileOf(person: person, account: account, friends: friends, standing: standing)
            } label: {
                PersonRow(person: person, detail: detail, trailing: trailing)
            }
            .accessibilityHint("Opens their profile")
        }
    }
}

extension PersonLink where Trailing == EmptyView {
    init(person: Person, account: Account, friends: [Int64: Friend] = [:], standing: PersonProfileScreen.Standing = .stranger,
         detail: String? = nil) {
        self.init(person: person, account: account, friends: friends, standing: standing, detail: detail, trailing: { EmptyView() })
    }
}

/// The profile a person's row opens.
struct ProfileOf: View {
    let person: Person
    let account: Account
    var friends: [Int64: Friend] = [:]
    var standing: PersonProfileScreen.Standing = .stranger

    var body: some View {
        if let friend = person.friend {
            FriendProfileScreen(friend: friend, account: account, safetyCode: E2E.safetyCode(account.publicKey, friend.publicKey),
                                unfriended: {}, model: ProfileModel(account: account), friends: friends)
        } else {
            PersonProfileScreen(person: person, account: account, standing: standing)
        }
    }
}

/// Someone who isn't your friend (a group's member, a request, someone you
/// blocked): the server shows profiles to friends only, so this is what the
/// app knows, their username, and what you can do: add them, report them,
/// block or unblock them.
struct PersonProfileScreen: View {
    /// Where you stand with them, for what the screen offers.
    enum Standing: Equatable, Sendable {
        case stranger
        /// They asked to be friends: adding them accepts.
        case askedYou
        /// You asked them; waiting.
        case youAsked
        /// Blocked by you, then (Unix seconds).
        case blocked(Int64)
        /// Friends now, from here (their profile is theirs to open from the list).
        case friends
    }

    @Environment(Session.self) private var session
    let person: Person
    let account: Account
    @State var standing: Standing
    var transport: any Transport = NetworkTransport()
    @State private var note: String?
    @State private var working = false
    @State private var reporting: ReportTarget?
    @State private var blocking: Reportable?
    @State private var confirmingUnblock = false

    init(person: Person, account: Account, standing: Standing = .stranger, transport: any Transport = NetworkTransport()) {
        self.person = person
        self.account = account
        _standing = State(initialValue: standing)
        self.transport = transport
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Avatar(kind: .friend(person.id), avatarId: nil, name: person.name, size: 96)
                    Text(person.name).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(Self.standingWords(standing)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text("Only friends see each other's profiles, pictures, and names.").frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            Section {
                switch standing {
                case .stranger, .askedYou:
                    Button(standing == .askedYou ? "Accept" : "Add friend", systemImage: "person.badge.plus") { add() }
                        .disabled(working)
                case .youAsked:
                    Button("Ask again", systemImage: "person.badge.plus") { add() }.disabled(working)
                case .blocked:
                    Button("Unblock \(person.name)", systemImage: "hand.raised.slash") { confirmingUnblock = true }
                        .disabled(working)
                case .friends:
                    Label("Your chat with them is in Chats.", systemImage: "bubble.left.and.bubble.right")
                }
            } footer: {
                if let note { Text(note) }
            }
            Section {
                Button("Report \(person.name)", systemImage: "exclamationmark.bubble") {
                    reporting = ReportTarget(what: .person, person: person.reportable)
                }
                if case .blocked = standing {} else {
                    Button("Block \(person.name)", systemImage: "hand.raised", role: .destructive) { blocking = person.reportable }
                }
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reporting) { target in
            ReportSheet(target: target, account: account, alreadyBlocked: standing.isBlocked, blocked: { _ in blocked() }, transport: transport)
        }
        .blockQuestion($blocking) { who in
            act {
                try await Moderation.block(who.id, account: account, transport: transport)
                Reporter.shared.report(.info, "blocked", ["user_id": String(who.id)])
                blocked()
            }
        }
        .confirmationDialog("Unblock \(person.name)?", isPresented: $confirmingUnblock, titleVisibility: .visible) {
            Button("Unblock") {
                act {
                    try await Moderation.unblock(person.id, account: account, transport: transport)
                    Reporter.shared.report(.info, "unblocked", ["user_id": String(person.id)])
                    standing = .stranger
                    note = "Unblocked \(person.name)."
                }
            }
        } message: {
            Text(Moderation.unblockWords)
        }
    }

    /// Under their name: where you stand (the web's words, `#profile-sub`).
    static func standingWords(_ standing: Standing) -> String {
        switch standing {
        case .stranger: "Not your friend"
        case .askedYou: "Wants to be friends"
        case .youAsked: "You asked to be friends"
        case .blocked(let at): "You block them, since \(Date(timeIntervalSince1970: TimeInterval(at)).formatted(date: .abbreviated, time: .omitted))"
        case .friends: "You're friends now"
        }
    }

    private func blocked() {
        standing = .blocked(Int64(Date().timeIntervalSince1970))
        note = "Blocked \(person.name). You can unblock them here or in Profile › Blocked."
    }

    /// Asks to be friends, by username (FriendsModel.add): if they'd asked you, you're friends now. In the server's words.
    private func add() {
        act {
            let answer = try await FriendsModel(account: account, transport: transport).ask(person.username)
            Reporter.shared.report(.info, "friend request from a profile", ["user_id": String(person.id)])
            note = answer.words
            standing = answer.friends ? .friends : .youAsked
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do { try await work() } catch {
                Reporter.shared.report(.warn, "profile action failed", Reporter.fields(error, ["user_id": String(person.id)]))
                session.noticed(error)
                note = error.localizedDescription
            }
        }
    }
}

extension PersonProfileScreen.Standing {
    var isBlocked: Bool { if case .blocked = self { true } else { false } }
}
