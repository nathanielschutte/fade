import SwiftUI

/// The chat list: friends and groups together, newest first, favorites on
/// top, each row with its newest message (decrypted here). Pull to refresh;
/// tapping a row opens the chat, and coming back refreshes the list. Swipe a
/// row (or hold it) to favorite, mute, hide, or leave; search finds chats by
/// name or newest message. While
/// the app is on screen the live connection (Live.swift) keeps the list and
/// the open chat current.
struct ChatListScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let account: Account
    @State private var list = ChatList()
    @State private var live: Live
    /// Profile and group pictures, for this session only.
    @State private var pictures: Pictures
    /// Every chat opened this session, kept: a text that hasn't gone yet keeps
    /// trying after you leave its chat, and coming back is instant. (Only in
    /// memory, and gone with the session.)
    @State private var opened = OpenedChats()
    @State private var settingUpRecovery = false
    @State private var search = ""
    @State private var showingHidden = false
    @State private var muting: ChatRow?
    @State private var leaving: ChatRow?
    /// A short note at the bottom, with Undo where it can be undone (app.js, `showToast`).
    @State private var toast: Toast?

    init(account: Account) {
        self.account = account
        _live = State(initialValue: Live(account: account))
        _pictures = State(initialValue: Pictures(account: account))
    }

    var body: some View {
        NavigationStack {
            List {
                if !account.user.hasRecoveryKey {
                    // As the web app's nudge: until there's one, a forgotten password costs every message.
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Save a recovery key, so a forgotten password can't cost you your messages.")
                            Button("Set up") { settingUpRecovery = true }.buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let problem = list.problem {
                    Text(problem).foregroundStyle(.red)
                }
                if !list.loaded {
                    if list.problem == nil {
                        Label("Loading…", systemImage: "ellipsis").foregroundStyle(.secondary)
                    }
                } else if !search.isEmpty {
                    let found = list.search(search)
                    if found.isEmpty { ContentUnavailableView.search(text: search) } else { rows(found) }
                } else if list.rows.filter({ !$0.hidden }).isEmpty && list.hiddenRows.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Friends you add show up here."))
                } else {
                    if list.favorites.isEmpty {
                        rows(list.others)
                    } else {
                        Section("Favorites") { rows(list.favorites) }
                        Section("Chats") { rows(list.others) }
                    }
                    if !list.hiddenRows.isEmpty {
                        Section {
                            Button(showingHidden ? "Hide hidden chats" : "Hidden chats (\(list.hiddenRows.count))") {
                                withAnimation { showingHidden.toggle() }
                            }
                            .foregroundStyle(.secondary)
                            if showingHidden { rows(list.hiddenRows) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Search")
            .safeAreaInset(edge: .bottom) {  // (above the search field, which sits at the bottom on newer iOS)
                if let toast {
                    ToastView(toast: toast) { self.toast = nil }
                        .padding(.horizontal, 16).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: toast?.id)
            .confirmationDialog(muting.map { "Mute \($0.name)" } ?? "", isPresented: .init(get: { muting != nil }, set: { if !$0 { muting = nil } }),
                                titleVisibility: .visible, presenting: muting) { row in
                Button("For 8 hours") { mute(row, hours: 8) }
                Button("For a week") { mute(row, hours: 168) }
                Button("Until I turn it back on") { mute(row, hours: nil) }
            } message: { _ in
                Text("No notifications and no unread dot from this chat. It's still there to open whenever you like.")
            }
            .confirmationDialog(leaving.map { "Leave \($0.name)?" } ?? "", isPresented: .init(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                                titleVisibility: .visible, presenting: leaving) { row in
                Button("Leave", role: .destructive) { act(row) { try await list.leave(row, account: account) } }
            } message: { _ in
                Text("You won't get its new messages. Someone in it can add you back.")
            }
            .refreshable { await load() }
            .task {
                live.onEvent = handle
                live.start()
                await load()
            }
            .safeAreaInset(edge: .top) { ReconnectingNote(live: live) }
            .sheet(isPresented: $settingUpRecovery) {
                PasswordSheet(purpose: .recovery, hasRecoveryKey: false) { _ in }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: ChatRow.Kind.self) { kind in
                if let conversation = conversation(kind) {
                    ChatScreen(conversation: conversation)
                        .environment(live)
                        .onDisappear { Task { await load() } }  // reads and new messages since
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { FriendsScreen(model: FriendsModel(account: account)) } label: {
                        Image(systemName: "person.2")
                            .overlay(alignment: .topTrailing) {
                                if list.incoming > 0 {
                                    Text("\(list.incoming)").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1).background(.red, in: Capsule())
                                        .offset(x: 10, y: -8)
                                }
                            }
                            .accessibilityLabel(list.incoming > 0 ? "Friends, \(list.incoming) new requests" : "Friends")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsScreen(account: account) } label: {
                        Image(systemName: "person.crop.circle").accessibilityLabel("Settings")
                    }
                }
            }
        }
        .environment(pictures)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { live.start() } else if phase == .background { live.stop() }
        }
        .onDisappear { live.stop() }  // signed out
    }

    private func rows(_ rows: [ChatRow]) -> some View {
        ForEach(rows) { row in
            NavigationLink(value: row.kind) { ChatRowView(row: row) }
                .swipeActions(edge: .leading) {
                    Button(row.favorite ? "Unfavorite" : "Favorite", systemImage: row.favorite ? "star.slash" : "star") {
                        act(row) { try await list.setFavorite(row, !row.favorite, account: account) }
                    }
                    .tint(.yellow)
                }
                .swipeActions(edge: .trailing) { rowActions(row, swiping: true) }
                .contextMenu {
                    Button(row.favorite ? "Unfavorite" : "Favorite", systemImage: row.favorite ? "star.slash" : "star") {
                        act(row) { try await list.setFavorite(row, !row.favorite, account: account) }
                    }
                    rowActions(row, swiping: false)
                }
        }
    }

    /// Hide or leave, and mute: the same whether swiped or held.
    @ViewBuilder private func rowActions(_ row: ChatRow, swiping: Bool) -> some View {
        if row.isGroup {
            Button("Leave", systemImage: "rectangle.portrait.and.arrow.right") { leaving = row }.tint(.red)
        } else if row.hidden {
            Button("Unhide", systemImage: "tray.and.arrow.up") {
                act(row) { try await list.setHidden(row, false, account: account) }
            }
            .tint(.blue)
        } else {
            Button("Hide", systemImage: "archivebox") {
                act(row) {
                    try await list.setHidden(row, true, account: account)
                    toast = Toast(text: "Hid your chat with \(row.name).") { act(row) { try await list.setHidden(row, false, account: account) } }
                }
            }
            .tint(.gray)
        }
        if row.muted {
            Button("Unmute", systemImage: "bell") { act(row) { try await list.setMuted(row, false, account: account) } }.tint(.indigo)
        } else {
            Button("Mute", systemImage: "bell.slash") { muting = row }.tint(.indigo)
        }
    }

    private func mute(_ row: ChatRow, hours: Int?) {
        act(row) {
            try await list.setMuted(row, true, hours: hours, account: account)
            toast = Toast(text: "Muted \(row.name).") { act(row) { try await list.setMuted(row, false, account: account) } }
        }
    }

    /// Runs a row's action; what goes wrong is said in the server's words.
    private func act(_ row: ChatRow, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch {
                Reporter.shared.report(.warn, "chat list action failed", Reporter.fields(error))
                session.noticed(error)
                toast = Toast(text: error.localizedDescription, undo: nil)
            }
        }
    }

    private func conversation(_ kind: ChatRow.Kind) -> Conversation? {
        guard let reader = list.reader else { return nil }
        let chat: Conversation.Chat
        switch kind {
        case .friend(let id):
            guard let friend = reader.friends[id] else { return nil }
            chat = .friend(friend)
        case .group(let id):
            guard let group = list.groups[id] else { return nil }
            chat = .group(group)
        }
        if let kept = opened.chats[kind] {
            kept.update(chat, reader: reader)
            return kept
        }
        let new = Conversation(chat, account: account, reader: reader, pinBook: list.pinBook)
        opened.chats[kind] = new
        return new
    }

    /// What the live connection says: the open chat takes its own messages,
    /// and the list refetches (the API is the truth).
    private func handle(_ event: LiveEvent) {
        let chat = live.openChat
        switch event {
        case .authFailed:
            session.noticed(ServerError.sessionEnded)
        case .ready:
            // Anything could have happened while disconnected.
            list.reloadSoon(account)
            if let chat { Task { try? await chat.catchUp() } }
            // Texts that couldn't go for the connection's sake, in every chat, go now.
            for kept in opened.chats.values { Task { await kept.flush() } }
        case .message(let m):
            if chat?.arrived(m) == true, let chat { Task { await chat.markRead() } }
            list.reloadSoon(account)
        case .groupMessage(let m):
            if chat?.arrived(m) == true, let chat { Task { await chat.markRead() } }
            list.reloadSoon(account)
        case .typing(let from, let group):
            chat?.typing(from: from, group: group)
        case .presence(let user, let active, let lastSeenAt):
            chat?.presence(user: user, active: active, lastSeenAt: lastSeenAt)
        case .read(let by, let at):
            chat?.read(by: by, at: at)
            list.reloadSoon(account)
        case .listChanged:
            list.reloadSoon(account)
        case .pong, .other:
            break
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
            Avatar(kind: row.kind, avatarId: row.avatarId, name: row.name)
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
    var size: CGFloat = 44

    var body: some View {
        let shape = group ? AnyShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)) : AnyShape(Circle())
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.18), in: shape)
            .accessibilityHidden(true)
    }
}

/// "Reconnecting…" while the live connection's been down more than a moment.
struct ReconnectingNote: View {
    let live: Live

    var body: some View {
        if live.reconnecting {
            Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 6).background(.bar)
        }
    }
}

/// The chats opened this session (ChatListScreen). A plain holder, not
/// observed: opening a chat shouldn't redraw the list.
final class OpenedChats {
    var chats: [ChatRow.Kind: Conversation] = [:]
}

/// A note at the bottom of the list for a few seconds, with Undo when it can be undone.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let undo: (() -> Void)?

    init(text: String, undo: (() -> Void)?) {
        self.text = text
        self.undo = undo
    }

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct ToastView: View {
    let toast: Toast
    let done: () -> Void

    var body: some View {
        HStack {
            Text(toast.text).font(.callout)
            Spacer()
            if let undo = toast.undo {
                Button("Undo") { undo(); done() }.bold()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 2)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { done() }
        }
    }
}
