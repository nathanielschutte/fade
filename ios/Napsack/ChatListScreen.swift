import SwiftUI

/// Home: a tab bar with Chats, the Camera, and Profile, as the web app on a
/// phone (Nate, 2026-10-30). Chats is the chat list: friends and groups
/// together, newest first, favorites on top, each row with its newest
/// message (decrypted here). Pull to refresh. Tapping a row opens the chat,
/// or, when its newest message is a pic or video waiting from them, shows
/// the chat's waiting pics right there and comes back to the list (Nate,
/// 2026-11-02). Swipe a row (or hold it) to favorite, mute, hide, or leave;
/// search finds chats by name or newest message at once, and messages kept
/// on the phone a moment later (Search.swift). While the app is on screen the
/// live connection (Live.swift) keeps the list and the open chat current.
struct ChatListScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let account: Account
    @State private var list = ChatList()
    @State private var live: Live
    /// Profile and group pictures, for this session only.
    @State private var pictures: Pictures
    /// The chats opened most recently, kept: a text that hasn't gone yet keeps
    /// trying after you leave its chat, and coming back is instant. (Only in
    /// memory, and gone with the session.)
    @State private var opened = OpenedChats()
    @State private var settingUpRecovery = false
    /// The announcement you closed, remembered on this phone (and forgotten at sign-out, Session).
    @AppStorage(ChatList.dismissedAnnouncementKey) private var dismissedAnnouncement: Int = 0
    enum HomeTab: Hashable { case chats, camera, profile }
    @State private var tab = HomeTab.chats
    @State private var path: [ChatRow.Kind] = []
    @State private var showingFriends = false
    /// Notifications on this phone: a tapped one opens its chat here (Notifications.swift).
    @State private var notifications = Notifications.shared
    /// A friend's link opened or scanned (Links.swift), and the one being offered.
    @State private var links = FriendLinks.shared
    @State private var offer: FriendLinks.Invite?
    @State private var makingGroup = false
    /// The server's limits for pics and videos (its /api/config).
    @State private var limits: ServerConfig?
    @State private var search = ""
    @State private var searching = false
    /// Messages found by search (Search.swift).
    @State private var finder = MessageFinder()
    /// A search result opened its chat: there, at that message.
    @State private var found: MessageHit.ID?
    /// A chat's waiting pics, shown straight from the list.
    @State private var viewing: PicsFromList?
    /// Nothing was waiting after all (opened on another device): the chat, once the viewer's gone.
    @State private var openAfterViewing: ChatRow.Kind?
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
        TabView(selection: $tab) {
            chats
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(HomeTab.chats)
                .badge(unreadChats)
            // Only while it's the tab shown: the camera is let go of otherwise.
            Group {
                if tab == .camera {
                    // Send picks the chats on the next screen; back returns to the pic.
                    CameraScreen(maxSeconds: limits?.videoMaxSeconds ?? 10, maxBytes: limits?.videoMaxBytes ?? 4 << 20,
                                 send: .pick(sendable, { kind, ready in
                                     guard let chat = conversation(kind) else { throw SendError.cantOpen }
                                     try await ready.send(to: chat, limits: limits)  // compressed once, sealed for each chat
                                 }, done: { words in
                                     toast = Toast(text: words, undo: nil)
                                     tab = .chats  // where it went, as on the web
                                 }),
                                 close: { tab = .chats })
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
            .tabItem { Label("Camera", systemImage: "camera") }
            .tag(HomeTab.camera)
            NavigationStack { SettingsScreen(account: account) }
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(HomeTab.profile)
        }
        .environment(pictures)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { live.start(); notifications.clearDelivered() } else if phase == .background { live.stop() }
        }
        .task { await notifications.start(for: account) }
        .onChange(of: notifications.opened, initial: true) { _, destination in
            if destination != nil { Task { await openNotification() } }
        }
        .onChange(of: unreadChats, initial: true) { _, count in
            if list.loaded { notifications.setBadge(count) }
        }
        .onChange(of: links.pending, initial: true) { _, invite in
            // Once the server has said whose it is (or that it doesn't work).
            guard let invite, invite.inviter != nil || invite.problem != nil else { return }
            links.pending = nil
            Task { await offerLink(invite) }
        }
        .alert("Add a friend?", isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }), presenting: offer) { invite in
            Button("Add") { Task { await acceptLink(invite) } }
            Button("Not now", role: .cancel) {}
        } message: { invite in
            Text("This is \(invite.inviter?.username ?? "someone")'s napsack link. Add them as a friend?")
        }
        .onDisappear {  // signed out
            live.stop()
            finder.forget()
        }
    }

    /// Chats with something unread or unopened, for the tab's badge (muted ones don't count).
    private var unreadChats: Int { list.waitingCount }

    /// The stack's path, with one change: tapping a row whose newest message
    /// is a pic or video waiting from them (`ChatRow.opensPics`, decided by
    /// the row's data) shows the chat's waiting pics over the list instead of
    /// opening the chat, so you're still on the list when they're done.
    private var rowTaps: Binding<[ChatRow.Kind]> {
        Binding(get: { path }, set: { next in
            if path.isEmpty, next.count == 1, let kind = next.first {
                found = nil  // a row opens its chat at the newest
                if let row = list.rows.first(where: { $0.kind == kind }), row.opensPics, let chat = conversation(kind) {
                    viewing = PicsFromList(kind: kind, conversation: chat, unread: kind.groupId.flatMap { list.groups[$0]?.unread } ?? 0)
                    return
                }
            }
            path = next
        })
    }

    private var chats: some View {
        NavigationStack(path: rowTaps) {
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
                announcementBanner
                if let problem = list.problem {
                    Text(problem).foregroundStyle(.red)
                }
                if !list.loaded {
                    if list.problem == nil {
                        Label("Loading…", systemImage: "ellipsis").foregroundStyle(.secondary)
                    }
                } else if !search.isEmpty {
                    SearchResults(text: search, chats: list.search(search), finder: finder, rows: { rows($0) }, open: openHit)
                } else if list.rows.isEmpty {
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
            .searchable(text: $search, isPresented: $searching, prompt: "Search")
            .onChange(of: searching) { _, now in if now { prepareSearch() } }
            .onChange(of: list.loaded) { _, loaded in if loaded && searching { prepareSearch() } }  // searched before the list was in
            .onChange(of: search) { _, text in finder.find(text) }
            // A key accepted in a chat: the list takes it at once (no event comes from the server for it).
            .onChange(of: list.pinBook?.pins) { list.pinsChanged() }
            .onChange(of: list.pinBook?.changed) { list.pinsChanged() }
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
            .task { limits = try? await Server(AppInfo.server).config() }
            .task {
                live.onEvent = handle
                live.start()
                await load()
            }
            .safeAreaInset(edge: .top) { ReconnectingNote(live: live) }
            .sheet(isPresented: $makingGroup) {
                let friends = (list.reader?.friends.values.map { $0 } ?? [])
                    .filter { $0.system != true && $0.deactivated != true }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                NewGroupScreen(account: account, friends: friends) { id in
                    Task {
                        await load()
                        path = [.group(id)]  // straight into it, as on the web
                    }
                }
            }
            .sheet(isPresented: $settingUpRecovery) {
                PasswordSheet(purpose: .recovery, hasRecoveryKey: false) { _ in }
            }
            .navigationTitle("Chats")
            .navigationDestination(isPresented: $showingFriends) {
                FriendsScreen(model: FriendsModel(account: account, friendNames: (list.reader?.friends ?? [:]).mapValues(\.name)))
            }
            .navigationDestination(for: ChatRow.Kind.self) { kind in
                if let conversation = conversation(kind) {
                    // No reload on the way back: what came while it was open came live, and
                    // reading it brings the server's `read` (or `groups_changed`), which reloads that list.
                    ChatScreen(conversation: conversation)
                        .environment(live)
                        .environment(\.foundMessage, found?.kind == kind ? found?.message : nil)
                }
            }
            .fullScreenCover(item: $viewing, onDismiss: {
                if let kind = openAfterViewing {
                    openAfterViewing = nil
                    path = [kind]
                }
            }) { item in
                PicViewer(waitingIn: item.conversation, nothingWaiting: { openAfterViewing = item.kind }) { shown in shownFromList(item, shown) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingFriends = true } label: {
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
                    // A group of people, not "new message" (Nate, 2026-10-30; custom artwork later).
                    Button { makingGroup = true } label: {
                        Image(systemName: "person.3").accessibilityLabel("New group")
                    }
                    .disabled(list.reader == nil)
                }
            }
        }
    }

    /// The Admins' announcement, until you close it (app.js, `showAnnouncement`).
    @ViewBuilder private var announcementBanner: some View {
        if let a = list.announcement, Int(a.id) != dismissedAnnouncement {
            Section {
                HStack(alignment: .top) {
                    Image(systemName: "megaphone").foregroundStyle(Color.accentColor)
                    Text(a.body)
                    Spacer()
                    Button("Close", systemImage: "xmark") { dismissedAnnouncement = Int(a.id) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
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

    /// Chats a pic can go to: not a changed key, a turned-off account, or Team Napsack.
    private var sendable: [ChatRow] {
        list.rows.filter { row in
            guard case .friend(let id) = row.kind else { return true }
            guard let friend = list.reader?.friends[id] else { return false }
            return friend.system != true && friend.deactivated != true && list.reader?.changed.contains(id) != true
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
        if let kept = opened.chat(kind) {
            kept.update(chat, reader: reader)
            return kept
        }
        let new = Conversation(chat, account: account, reader: reader, pinBook: list.pinBook, cache: list.cache(for: account))
        opened.keep(new, as: kind, busy: Set(path).union(viewing.map { [$0.kind] } ?? []), open: live.openChat)
        return new
    }

    /// What the live connection says: the open chat takes its own messages,
    /// and the list what's its (ChatList.heard: a message changes its own row,
    /// and only what the server alone knows reloads).
    private func handle(_ event: LiveEvent) {
        let chat = live.openChat
        switch event {
        case .authFailed:
            session.noticed(ServerError.sessionEnded)
        case .ready:
            if let chat { Task { try? await chat.catchUp() } }
            // Texts that couldn't go for the connection's sake, in every chat, go now.
            for kept in opened.waitingToSend { Task { await kept.flush() } }
        case .message(let m):
            if chat?.arrived(m) == true, let chat { Task { await chat.markRead() } }
        case .groupMessage(let m):
            if chat?.arrived(m) == true, let chat { Task { await chat.markRead() } }
        case .typing(let from, let group):
            chat?.typing(from: from, group: group)
        case .presence(let user, let active, let lastSeenAt):
            chat?.presence(user: user, active: active, lastSeenAt: lastSeenAt)
        case .read(let by, let at):
            chat?.read(by: by, at: at)
        case .groupRead(let group, let user, let last):
            chat?.groupRead(group: group, user: user, last: last)  // "Seen by", in the chat only
        case .announcement, .friendsChanged, .groupsChanged, .pong, .other:
            break
        }
        list.heard(event, account: account)
    }

    /// Search opened: the chats to look through, newest first, with what's open of them already.
    private func prepareSearch() {
        guard let reader = list.reader else { return }
        let sources = list.rows.compactMap { row -> SearchSource? in
            let chat: Conversation.Chat
            switch row.kind {
            case .friend(let id):
                guard let friend = reader.friends[id] else { return nil }
                chat = .friend(friend)
            case .group(let id):
                guard let group = list.groups[id] else { return nil }
                chat = .group(group)
            }
            return SearchSource(kind: row.kind, name: row.name, avatarId: row.avatarId, chat: chat,
                                opened: opened.peek(row.kind).map(SearchSource.opened) ?? [])
        }
        finder.prepare(sources, reader: reader, cache: list.cache(for: account))
    }

    /// A message search found: its chat, at that message if it's loaded.
    private func openHit(_ hit: MessageHit) {
        guard conversation(hit.kind) != nil else { return }
        found = hit.id
        showingFriends = false
        path = [hit.kind]
    }

    /// The pics shown from the list are opened (each as it was shown; the
    /// server's `message_updated` changes the row, and reloads friends for
    /// the unread count). A direct chat with a text still unread from before
    /// them keeps its dot (`Reader.status`), and the text stays unread for when
    /// you open the chat. A group whose only unread
    /// messages were those pics is read now, as opening its chat would have
    /// done (its `groups_changed` reloads the row); otherwise its texts stay
    /// unread for when you open it.
    private func shownFromList(_ item: PicsFromList, _ shown: Set<Int64>) {
        guard case .group = item.kind, Reader.readAfterShowing(shown, unread: item.unread, in: item.conversation.bubbles) else { return }
        Task { await item.conversation.markRead() }
    }

    /// A notification was tapped: its chat (or Friends), on the Chats tab.
    /// At a cold launch the list may not be in yet, and a chat that just began
    /// (a friend accepted) may not be in it: load first, then open.
    private func openNotification() async {
        guard let destination = notifications.opened else { return }
        notifications.opened = nil
        tab = .chats
        switch destination {
        case .friends:
            path = []
            showingFriends = true
        case .chat(let kind):
            if conversation(kind) == nil { await load() }
            if conversation(kind) != nil {
                showingFriends = false
                path = [kind]
            }
        }
    }

    /// As the web's `offerInvite`: your own link says so, a friend's opens
    /// their chat, anyone else's asks first.
    private func offerLink(_ invite: FriendLinks.Invite) async {
        tab = .chats
        guard let inviter = invite.inviter else {
            toast = Toast(text: invite.problem ?? "That link doesn't work.", undo: nil)
            return
        }
        if inviter.id == account.user.id {
            toast = Toast(text: "That's your own link. Send it to a friend.", undo: nil)
            return
        }
        if !list.loaded { await load() }
        if conversation(.friend(inviter.id)) != nil {
            showingFriends = false
            path = [.friend(inviter.id)]
        } else {
            offer = invite
        }
    }

    private func acceptLink(_ invite: FriendLinks.Invite) async {
        do {
            let friend = try await FriendLinks.accept(invite.token, account: account)
            await load()
            showingFriends = false
            if conversation(.friend(friend.id)) != nil { path = [.friend(friend.id)] }
            toast = Toast(text: "You and \(friend.username) are now friends.", undo: nil)
        } catch {
            toast = Toast(text: error.localizedDescription, undo: nil)
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
                    Text(row.name + row.marks).font(.headline).lineLimit(1)
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

/// The chats opened this session (ChatListScreen), the few most recent, with
/// all they've loaded: coming back to one is instant. One with a text still
/// waiting to go is never let go (it keeps trying after you leave it), nor
/// one on screen. A plain holder, not observed: opening a chat shouldn't
/// redraw the list.
@MainActor final class OpenedChats {
    /// How many are kept besides those (each holds its pages of messages).
    static let kept = 6
    private var chats: [ChatRow.Kind: Conversation] = [:]
    /// Least recently opened first.
    private var order: [ChatRow.Kind] = []

    /// A kept chat, now the most recent.
    func chat(_ kind: ChatRow.Kind) -> Conversation? {
        guard let chat = chats[kind] else { return nil }
        order.removeAll { $0 == kind }
        order.append(kind)
        return chat
    }

    /// A kept chat, left where it is in the order (search reading what's loaded).
    func peek(_ kind: ChatRow.Kind) -> Conversation? { chats[kind] }

    /// A chat just opened. Past the limit, the longest unopened goes, unless
    /// it has texts waiting, is `busy` (shown, or in the stack), or is `open`.
    func keep(_ chat: Conversation, as kind: ChatRow.Kind, busy: Set<ChatRow.Kind> = [], open: Conversation? = nil) {
        chats[kind] = chat
        order.removeAll { $0 == kind }
        order.append(kind)
        while chats.count > Self.kept, let old = order.first(where: { k in
            guard let c = chats[k] else { return true }
            return k != kind && c.outbox.isEmpty && !busy.contains(k) && c !== open
        }) {
            chats[old] = nil
            order.removeAll { $0 == old }
        }
    }

    /// Kept chats with texts still to send (on a reconnect, they go).
    var waitingToSend: [Conversation] { chats.values.filter { !$0.outbox.isEmpty } }

    var count: Int { chats.count }
}

/// A chat's waiting pics shown from the list (ChatListScreen).
struct PicsFromList: Identifiable {
    let kind: ChatRow.Kind
    let conversation: Conversation
    /// The group's unread count when it opened (whether it's read after; groups only).
    let unread: Int
    var id: ChatRow.Kind { kind }
}

extension ChatRow.Kind {
    var groupId: Int64? {
        if case .group(let id) = self { return id }
        return nil
    }
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
