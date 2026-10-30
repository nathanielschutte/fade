import SwiftUI

/// The chat list: friends and groups together, newest first, favorites on
/// top, each row with its newest message (decrypted here). Pull to refresh;
/// tapping a row opens the chat, and coming back refreshes the list.
struct ChatListScreen: View {
    @Environment(Session.self) private var session
    let account: Account
    @State private var list = ChatList()
    @State private var showDeveloper = false
    @State private var signingOut = false

    var body: some View {
        NavigationStack {
            List {
                if let problem = list.problem {
                    Text(problem).foregroundStyle(.red)
                }
                if !list.loaded {
                    if list.problem == nil {
                        Label("Loading…", systemImage: "ellipsis").foregroundStyle(.secondary)
                    }
                } else if list.rows.filter({ !$0.hidden }).isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Friends you add show up here."))
                } else if list.favorites.isEmpty {
                    rows(list.others)
                } else {
                    Section("Favorites") { rows(list.favorites) }
                    Section("Chats") { rows(list.others) }
                }
            }
            .listStyle(.plain)
            .refreshable { await load() }
            .task { await load() }
            .navigationTitle("Chats")
            .navigationDestination(isPresented: $showDeveloper) { DeveloperScreen() }
            .navigationDestination(for: ChatRow.Kind.self) { kind in
                if let conversation = conversation(kind) {
                    ChatScreen(conversation: conversation)
                        .onDisappear { Task { await load() } }  // reads and new messages since
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("@\(account.user.username) on \(URL(string: account.server)?.host() ?? account.server)") {
                            Button("Developer", systemImage: "hammer") { showDeveloper = true }
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                signingOut = true
                                Task { await session.signOut() }
                            }
                            .disabled(signingOut)
                        }
                    } label: {
                        Image(systemName: "person.crop.circle").accessibilityLabel("Account")
                    }
                }
            }
        }
    }

    private func rows(_ rows: [ChatRow]) -> some View {
        ForEach(rows) { row in
            NavigationLink(value: row.kind) { ChatRowView(row: row) }
        }
    }

    private func conversation(_ kind: ChatRow.Kind) -> Conversation? {
        guard let reader = list.reader else { return nil }
        switch kind {
        case .friend(let id): return reader.friends[id].map { Conversation(.friend($0), account: account, reader: reader) }
        case .group(let id): return list.groups[id].map { Conversation(.group($0), account: account, reader: reader) }
        }
    }

    private func load() async {
        do {
            try await list.load(account)
        } catch {
            session.noticed(error)
        }
    }
}

struct ChatRowView: View {
    let row: ChatRow

    var body: some View {
        HStack(spacing: 12) {
            Initial(name: row.name, group: row.isGroup)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.headline).lineLimit(1)
                    if row.muted {
                        Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Muted")
                    }
                    Spacer(minLength: 8)
                    if let time = row.time {
                        Text(Self.when(time)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(row.preview)
                        .lineLimit(1)
                        .foregroundStyle(row.waiting == nil ? .secondary : .primary)
                        .fontWeight(row.waiting == nil ? .regular : .semibold)
                    Spacer(minLength: 8)
                    if let waiting = row.waiting {
                        Circle()
                            .fill(waiting == .snap ? Color.accentColor : Color.primary.opacity(0.7))
                            .frame(width: 9, height: 9)
                            .accessibilityLabel(waiting == .snap ? "Unopened" : "Unread")
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    /// Today: the time. This week: the day. Before that: the date.
    static func when(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The first letter of a name, until profile pictures come (plan-ios.md): round
/// for people, a rounded square for groups (as on the web, plan X17).
struct Initial: View {
    let name: String
    let group: Bool

    var body: some View {
        let shape = group ? AnyShape(RoundedRectangle(cornerRadius: 13, style: .continuous)) : AnyShape(Circle())
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
            .background(Color.accentColor.opacity(0.18), in: shape)
            .accessibilityHidden(true)
    }
}
