import AVKit
import NapsackCrypto
import PhotosUI
import SwiftUI
import UIKit

/// An open chat: its history, newest at the bottom, older pages loading as you
/// scroll up. Opening it marks it read. A friend's changed key shows a warning
/// at the top until it's accepted. Texts are written at the bottom. Holding a
/// message (it gives a little under the finger, then its menu comes with a
/// tap of haptics, before you let go) reacts, replies, copies, or (your own
/// text, for 15 minutes) edits it. New messages arrive live (Live.swift).
///
/// Scrolling has few rules, so it does what a finger expects (Nate,
/// 2026-11-03): the chat opens on the newest; while the newest is in sight,
/// whatever grows below it (a message, the typing line, the composer, the
/// keyboard) keeps it in sight; once you've scrolled up, nothing moves what
/// you're reading, and a quiet note says when something new came below.
/// Sending takes you to the newest. The rest is the scroll view's own.
struct ChatScreen: View {
    @Environment(Session.self) private var session
    @Environment(Live.self) private var live
    @Environment(\.dismiss) private var dismiss
    /// Unfriended from their profile, or left the group: back to the list once that screen's gone.
    @State private var unfriended = false
    @State var conversation: Conversation
    /// Where the chat is scrolled: the scroll view keeps it. The app moves it
    /// only to go to the newest (sending, or the note about new messages).
    @State private var position = ScrollPosition(idType: Int64.self)
    /// The newest is in sight, or nearly (ChatScreen.nearBottom).
    @State private var atBottom = true
    /// Whether a finger or a fling is moving the chat (`onScrollPhaseChange`).
    @State private var scrolling = false
    /// Said once per chat opened: it was left past its end (ChatScreen's own report).
    @State private var reportedPastEnd = false
    /// Gone to the newest by its id: it's drawn, and the next move puts the end in its place.
    @State private var placingEnd = false
    /// Something new came below while you were reading further up.
    @State private var newBelow = false
    @State private var showingSafetyCode = false
    @State private var draft = ""
    @State private var replyingTo: Bubble?
    @State private var editing: Bubble?
    @State private var failure: String?
    /// The message being held: its reactions and actions show over the chat.
    @State private var held: Bubble?
    /// Counts what you've sent and reacted, for a light tap of haptics each time.
    @State private var tapped = 0
    /// A pic or video being opened (once).
    @State private var viewing: PicToOpen?
    /// An edited text whose versions are showing.
    @State private var versionsOf: Bubble?
    /// A message whose reactions are showing: who reacted with what (F21).
    @State private var reactionsOf: ReactionsOpening?
    /// A photo from the library: it opens in the camera, ready for its caption.
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var picks = PhotoPicks()
    /// The camera, while it's open: live, or on a picked photo.
    @State private var camera: CameraOpening?
    /// The server's limits for pics and videos (its /api/config).
    @State private var limits: ServerConfig?
    /// A message or the friend being reported, and someone being asked about blocking (Moderation.swift).
    @State private var reporting: ReportTarget?
    @State private var blocking: Reportable?
    /// Opens a chat from a link in a text (the chat list's).
    @Environment(\.openChatLink) private var openChatLink
    @FocusState private var composing: Bool
    @Environment(\.dynamicTypeSize) private var textSize
    /// The composer's buttons: a finger's worth (44 points) at the usual text
    /// size, growing with the text up to half as big again (any more and they
    /// crowd out the field).
    @ScaledMetric(relativeTo: .body) private var tapSize = 44.0
    @ScaledMetric(relativeTo: .body) private var iconSize = 22.0
    @ScaledMetric(relativeTo: .body) private var sendSize = 32.0

    /// The content's height, how far its end is below what's shown, and the
    /// window it's shown in (the visible height, and the inset under the composer and keyboard).
    struct BottomGap: Equatable {
        let height: CGFloat
        let gap: CGFloat
        let visible: CGFloat
        let inset: CGFloat
    }

    /// How close to the bottom still counts as at it: a finger's slack, less than a line of text.
    static let nearBottom: CGFloat = 24
    /// How far from the oldest message shown the next page starts loading, so it's there before you are.
    static let loadAhead = 10

    /// Left past its end with nothing moving it (a blank screen above the composer; Nate
    /// saw it on his phone as the keyboard came up): back to the end, as a touch would do.
    private func returnedFromPastEnd(_ now: BottomGap, before: BottomGap) -> Bool {
        guard now.gap < -Self.nearBottom, now.height > now.visible else { return false }
        if !reportedPastEnd {
            reportedPastEnd = true
            Reporter.shared.report(.warn, "chat left past its end", [
                "gap": "\(Int(now.gap))", "height": "\(Int(now.height))", "visible": "\(Int(now.visible))",
                "inset": "\(Int(now.inset))", "before_gap": "\(Int(before.gap))", "before_inset": "\(Int(before.inset))",
            ])
        }
        position.scrollTo(edge: .bottom)
        return true
    }

    /// Whether the list needs `drawEnd` when the keyboard or composer moves (D18): iOS 26 and older.
    static var redrawsAtEnd: Bool {
        if #available(iOS 27, *) { false } else { true }
    }

    /// To the newest message by its id, when it's the last row (no text still going or typing
    /// line below it): a scroll to a row has the list lay the row out. Then `placingEnd`.
    private func drawEnd() -> Bool {
        guard conversation.outbox.isEmpty, conversation.typingLine == nil,
              let newest = conversation.bubbles.last?.id else { return false }
        position.scrollTo(id: newest, anchor: .bottom)
        placingEnd = true
        return true
    }

    var body: some View {
        presentations(main)
    }

    private var main: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if case .group = conversation.chat {
                    // Every client says so in each group (CLAUDE.md, Security).
                    Text("Messages and pics in this group are end-to-end encrypted. The group's name and picture aren't: the napsack server can see those.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                }
                if conversation.loaded {
                    if conversation.reachedStart {
                        Text(conversation.beginning).font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        // Coming into view: the page before.
                        ProgressView().padding(.vertical, 8).onAppear { Task { await older() } }
                    }
                }
                let seenId = conversation.seenId
                ForEach(conversation.bubbles) { bubble in
                    message(bubble, seenId: seenId)
                }
                ForEach(conversation.outbox) { item in
                    OutgoingView(item: item, quote: item.replyTo.map(quote),
                                 retry: { Task { await conversation.retry(item.id) } },
                                 remove: {
                                     if let text = conversation.discard(item.id), draft.isEmpty { draft = text }  // nothing lost
                                 })
                }
                if let typing = conversation.typingLine {
                    // Under the newest, where their message will be.
                    Text(typing).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.top, 2)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("messages")
        // The newest at the bottom when it opens; while the bottom's in sight,
        // anything that changes size keeps it there. Away from the bottom the
        // scroll view keeps what's on screen where it is.
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        .modifier(ShowFound(conversation: conversation, position: $position))  // a search result's message (Search.swift)
        .onScrollGeometryChange(for: BottomGap.self) { geometry in
            // The visible rect reaches under the composer (the bottom inset), so the end counts from there.
            BottomGap(height: geometry.contentSize.height,
                      gap: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY,
                      visible: geometry.visibleRect.height, inset: geometry.contentInsets.bottom)
        } action: { before, now in
            // At the bottom, what changes size under you (a message, the typing line, the keyboard,
            // the composer growing) keeps the newest in sight. iOS 27's anchor does that itself;
            // iOS 26 and older leave it below the screen (ChatScrollTests). Not your own scrolling,
            // nor a jump to a search result: those move the chat without changing its size.
            // Older pages grow above and leave the gap as it was. The end is a place, not a
            // distance, so going there can't add to a move the scroll view makes itself.
            if placingEnd {
                // The row is laid out now; a scroll to a row ignores the inset under the composer
                // and keyboard, so the end goes where it belongs, above them.
                placingEnd = false
                if !scrolling, abs(now.gap) > Self.nearBottom {
                    position.scrollTo(edge: .bottom)
                    return
                }
            }
            let reframed = now.visible != before.visible || now.inset != before.inset
            let resized = now.height > before.height || reframed
            if !scrolling, resized, before.gap <= Self.nearBottom, now.gap > Self.nearBottom {
                position.scrollTo(edge: .bottom)
                return
            }
            // Before iOS 27 the list can stay at its end by the numbers as the keyboard comes up
            // yet draw none of its rows, a blank screen until a touch (D18; testReopenedThenKeyboard
            // caught it, the numbers showing no gap). Going to the newest by its id has the list
            // lay that row out.
            if !scrolling, reframed, before.gap <= Self.nearBottom, Self.redrawsAtEnd, drawEnd() { return }
            if !scrolling, returnedFromPastEnd(now, before: before) { return }
            atBottom = now.gap <= Self.nearBottom
            if atBottom { newBelow = false }
        }
        .onScrollPhaseChange { _, phase in scrolling = phase.isScrolling }
        .onChange(of: conversation.bubbles.last?.id) { before, after in
            // Newer than what was there (older pages change the first, not the last), and you're reading further up.
            if let before, let after, after > before, !atBottom { newBelow = true }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollDisabled(held != nil)
        .overlay(alignment: .bottom) {
            if newBelow {
                Button { goToNewest() } label: {
                    Label("New messages", systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .accessibilityIdentifier("new-messages")
                .accessibilityHint("Goes to the newest message")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: newBelow)
        .safeAreaInset(edge: .bottom) { composer }
        .animation(.easeOut(duration: 0.15), value: conversation.typingLine)
        .overlay {
            if !conversation.loaded {
                if let problem = conversation.problem {
                    ContentUnavailableView("Couldn't load this chat", systemImage: "exclamationmark.bubble", description: Text(problem))
                } else {
                    ProgressView("Loading…")
                }
            }
        }
        .safeAreaInset(edge: .top) { ReconnectingNote(live: live) }
        .safeAreaInset(edge: .top) {
            if conversation.keyChanged, let friend = conversation.friend {
                KeyWarning(friend: friend, compare: { showingSafetyCode = true }, accept: { Task { await accept(verified: false) } })
                    .padding(.horizontal, 12).padding(.top, 4).background(.bar)
            }
        }
        .overlay {
            if let held {
                MessageActions(bubble: held, quote: held.replyTo.map(quote),
                               reactions: conversation.canSend && held.repliable ? E2E.reactions : [],
                               actions: actions(held),
                               react: { react(held, $0) },
                               dismiss: { self.held = nil })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: held?.id)
        // The menu's come: let go (it comes while the finger's still down).
        .sensoryFeedback(.impact(weight: .medium), trigger: held?.id) { _, now in now != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
        // A new message from them in the open chat: a light tap (only newer ones, not a page loading).
        .sensoryFeedback(.impact(weight: .light), trigger: conversation.bubbles.last?.id) { before, after in
            before != nil && after != nil && conversation.bubbles.last?.mine == false
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A friend's name (and picture) opens their profile, as on the web.
            if case .group(let group) = conversation.chat, let account = session.account {
                ToolbarItem(placement: .principal) {
                    NavigationLink {
                        GroupInfoScreen(model: GroupModel(id: group.id, account: account), account: account, avatarId: group.avatarId,
                                        friends: conversation.friendsById, left: { unfriended = true })
                    } label: {
                        HStack(spacing: 8) {
                            Avatar(kind: .group(group.id), avatarId: group.avatarId, name: group.name, size: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(conversation.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                                Text("\(group.memberCount) people").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel("\(conversation.title): group info")
                }
            }
            if let friend = conversation.friend, friend.system != true, let account = session.account {
                ToolbarItem(placement: .principal) {
                    NavigationLink {
                        FriendProfileScreen(friend: friend, account: account, safetyCode: conversation.safetyCode ?? "",
                                            unfriended: { unfriended = true }, model: ProfileModel(account: account), friends: conversation.friendsById)
                    } label: {
                        HStack(spacing: 8) {
                            Avatar(kind: .friend(friend.id), avatarId: friend.avatarId, name: friend.name, size: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(conversation.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    if let active = conversation.activeText(now: context.date) {
                                        Text(active).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityLabel("\(conversation.title): view profile")
                }
            }
            if conversation.friend != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSafetyCode = true } label: {
                        Image(systemName: conversation.keyChanged ? "lock.trianglebadge.exclamationmark" : "lock")
                    }
                    .accessibilityLabel("Encryption and safety code")
                }
            }
            if let friend = conversation.friend, friend.system != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        let person = Reportable(id: friend.id, name: friend.name)
                        Button("Report \(friend.name)", systemImage: "exclamationmark.bubble") {
                            reporting = ReportTarget(what: .person, person: person)
                        }
                        Button("Block \(friend.name)", systemImage: "hand.raised", role: .destructive) { blocking = person }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(isPresented: $showingSafetyCode) {
            if let friend = conversation.friend, let code = conversation.safetyCode {
                SafetyCodeScreen(username: friend.username, code: code, keyChanged: conversation.keyChanged) {
                    Task { await accept(verified: true) }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            if unfriended { return dismiss() }
            live.openChat = conversation
        }
        .onDisappear { if live.openChat === conversation { live.openChat = nil } }
        .task {
            do {
                // Opened before this session: just what's new since.
                if conversation.loaded { try await conversation.catchUp() } else { try await conversation.loadNewest() }
                await conversation.loadGroupReads()
                await conversation.markRead()
            } catch {
                Reporter.shared.report(.warn, "loading a chat failed", Reporter.fields(error))
                conversation.noted(error)
                session.noticed(error)
            }
        }
    }

    /// To the newest message, as a scroll (sending, or the note about new messages).
    private func goToNewest() {
        newBelow = false
        withAnimation(.easeOut(duration: 0.3)) { position.scrollTo(edge: .bottom) }
    }

    @ViewBuilder private var composer: some View {
        if let note = conversation.blockedNote {
            Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(12).background(.bar)
        } else if conversation.loaded {
            VStack(spacing: 0) {
                if editing != nil || replyingTo != nil {
                    HStack {
                        Group {
                            if editing != nil {
                                Text("Editing your message")
                            } else if let replyingTo {
                                Text("Replying to \(replyingTo.mine ? "yourself" : replyingTo.sender ?? conversation.title): \(replyingTo.gist)")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button(editing != nil ? "Cancel editing" : "Cancel reply", systemImage: "xmark") {
                            if editing != nil { draft = "" }
                            editing = nil
                            replyingTo = nil
                        }
                        .labelStyle(.iconOnly).font(.caption)
                        .frame(minWidth: 44, minHeight: 44)  // a finger's worth around the small x
                        .contentShape(Rectangle())
                    }
                    .padding(.leading, 6)
                }
                if textSize.isAccessibilitySize {
                    // The largest text: the field gets the whole width, and its buttons a row under it.
                    VStack(spacing: 2) {
                        field.padding(.horizontal, 6).padding(.top, 3)
                        HStack(spacing: 0) {
                            mediaButtons
                            Spacer(minLength: 0)
                            sendButton
                        }
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 0) {
                        mediaButtons
                        field.padding(.horizontal, 4)
                        sendButton
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)  // less than around the words: the buttons' tap areas reach past their icons
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer-bar")
        }
    }

    /// The camera, and a photo from the library, beside the composer (not while editing).
    @ViewBuilder private var mediaButtons: some View {
        if editing == nil {
            let icon = min(iconSize, 33), tap = min(tapSize, 66)
            Button { camera = CameraOpening() } label: { Self.composerButton("camera", size: icon, tap: tap) }
                .disabled(!conversation.canSend)
                .accessibilityLabel("Camera")
            PhotosPicker(selection: $pickedPhoto, matching: .images) { Self.composerButton("photo.on.rectangle", size: icon, tap: tap) }
                .disabled(!conversation.canSend)
                .accessibilityLabel("Send a photo")
        }
    }

    private var field: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .onChange(of: draft) { _, text in if !text.isEmpty { conversation.noteTyping(live) } }
            .lineLimit(1...5)
            .focused($composing)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: min(tapSize, 66))  // as tall as the buttons beside it, its words in the middle
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(!conversation.canSend)
            .accessibilityIdentifier("composer")
    }

    private var sendButton: some View {
        Button { send() } label: { Self.composerButton("arrow.up.circle.fill", size: min(sendSize, 48), tap: min(tapSize, 66)) }
            .disabled(!conversation.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
    }

    /// An icon in its tap area (`tap` × `tap`, at least 44 points).
    nonisolated private static func composerButton(_ icon: String, size: CGFloat, tap: CGFloat) -> some View {
        Image(systemName: icon).font(.system(size: size))
            .frame(width: tap, height: tap)
            .contentShape(Rectangle())
    }

    /// One message: its day header when the day changes, the bubble, and "Seen" under my newest text once read.
    @ViewBuilder private func message(_ bubble: Bubble, seenId: Int64?) -> some View {
        let bubbles = conversation.bubbles
        let index = bubbles.slot(of: bubble.id).index
        let next = index + 1 < bubbles.count ? bubbles[index + 1] : nil
        if index == 0 || !Calendar.current.isDate(bubble.time, inSameDayAs: bubbles[index - 1].time) {
            Text(bubble.time.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 10)
        }
        BubbleView(bubble: bubble, quote: bubble.replyTo.map(quote), showTime: endsARun(bubble, next),
                   whoReacted: { reactionsOf = ReactionsOpening(message: bubble.id, emoji: $0) })
            .modifier(HoldForMenu(enabled: holdable(bubble)) { held = bubble })
            .onTapGesture { if let pic = bubble.opening { viewing = pic } }
            .modifier(SwipeToReply(enabled: conversation.canSend && bubble.repliable && held == nil) {
                editing = nil
                replyingTo = bubble
                composing = true
            })
            .accessibilityAction(named: "Message actions") { if holdable(bubble) { held = bubble } }
            .onAppear {
                // Near the oldest shown: the page before starts coming now.
                if index == Self.loadAhead && !conversation.reachedStart { Task { await older() } }
            }
        if bubble.id == seenId {
            Text("Seen").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 4)
        }
        if next == nil, let seenBy = conversation.seenBy {
            Text(seenBy).font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: bubble.mine ? .trailing : .leading).padding(.horizontal, 4)
        }
    }

    /// What holding a message offers (app.js, the message actions): one row
    /// of reactions above it, and Reply, Copy, Edit below.
    private func actions(_ bubble: Bubble) -> [MessageActions.Action] {
        var actions: [MessageActions.Action] = []
        if conversation.canSend, bubble.repliable {
            actions.append(.init(title: "Reply", icon: "arrowshape.turn.up.left") {
                editing = nil
                replyingTo = bubble
                composing = true
            })
        }
        if case .text(let text, _) = bubble.content {
            actions.append(.init(title: "Copy", icon: "doc.on.doc") { UIPasteboard.general.string = text })
        }
        if case .text(_, true) = bubble.content {
            actions.append(.init(title: "Edits", icon: "clock.arrow.circlepath") { versionsOf = bubble })
        }
        if conversation.canSend, bubble.canEdit, case .text(let text, _) = bubble.content {
            actions.append(.init(title: "Edit", icon: "pencil") {
                replyingTo = nil
                editing = bubble
                draft = text
                composing = true
            })
        }
        // Someone else's text, pic, or video (never Team Napsack's): ids only go (Moderation.swift).
        if let target = ReportTarget.message(bubble, in: conversation.chat, friends: conversation.friendsById) {
            actions.append(.init(title: "Report", icon: "exclamationmark.bubble") { reporting = target })
        }
        return actions
    }

    /// Blocks them; a direct chat with them closes (the friendship's over), a group stays.
    private func block(_ person: Reportable) async {
        guard let account = session.account else { return }
        do {
            try await Moderation.block(person.id, account: account)
            Reporter.shared.report(.info, "blocked", ["user_id": String(person.id)])
            if conversation.friend?.id == person.id {
                unfriended = true
                dismiss()
            }
        } catch {
            Reporter.shared.report(.warn, "block failed", Reporter.fields(error, ["user_id": String(person.id)]))
            session.noticed(error)
            failure = error.localizedDescription
        }
    }

    /// A link in a text to one of the app's own chats: that chat, at its message.
    private var openLinks: OpenURLAction {
        let site = ownSite
        return OpenURLAction { url in
            // Only the app's own links are links at all (ChatLink.linked); anything else goes nowhere.
            guard let link = ChatLink(url, site: site), let openChatLink else { return .discarded }
            Task {
                if let problem = await openChatLink(link) { failure = problem }
            }
            return .handled
        }
    }

    /// The app's own site, for links in texts: the server's `site_url`, or its own address where there's none (development).
    private var ownSite: String? {
        guard let limits, let account = session.account else { return nil }
        return limits.siteUrl ?? account.server
    }

    /// Whether holding this message offers anything at all.
    private func holdable(_ bubble: Bubble) -> Bool {
        (conversation.canSend && bubble.repliable) || !actions(bubble).isEmpty
    }

    private func react(_ bubble: Bubble, _ emoji: String) {
        tapped += 1
        Task {
            do { try await conversation.react(bubble, emoji) } catch { trouble(error) }
        }
    }

    private func trouble(_ error: any Error) {
        Reporter.shared.report(.warn, "message action failed", Reporter.fields(error))
        session.noticed(error)
        failure = error.localizedDescription
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, conversation.canSend else { return }
        draft = ""
        tapped += 1
        if let editing {
            self.editing = nil
            guard case .text(let before, _) = editing.content, before != text else { return }  // nothing changed
            Task {
                do {
                    try await conversation.edit(editing, to: text)
                } catch {
                    // Nothing lost: it's back in the box to try again.
                    if draft.isEmpty { draft = text; self.editing = editing }
                    trouble(error)
                }
            }
            return
        }
        let reply = replyingTo?.id
        replyingTo = nil
        let id = conversation.queue(text, replyTo: reply)
        goToNewest()  // what you sent, at the bottom (and it stays there as the server's copy replaces it)
        Task { await conversation.retry(id) }
    }

    /// The sheets and covers a chat shows (picked photos, the camera, the viewer, edits, problems).
    private func presentations(_ content: some View) -> some View {
        content
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            let pick = picks.began()
            Task {
                defer { pickedPhoto = nil }
                let photo = await Captured.picked(item)
                guard picks.stillWanted(pick, busy: camera != nil) else { return }  // the camera opened meanwhile, or a newer pick
                guard let photo else {
                    failure = "Couldn't open that photo."
                    return
                }
                camera = CameraOpening(start: photo)
            }
        }
        .sheet(item: $versionsOf) { bubble in
            EditsSheet(bubble: bubble, conversation: conversation).presentationDetents([.medium, .large])
        }
        .sheet(item: $reactionsOf) { opening in
            if let account = session.account {
                // Reacting from it as from holding the message: where this chat can, to what takes reactions.
                let reacts = conversation.canSend && conversation.bubble(opening.message)?.repliable == true
                WhoReactedSheet(conversation: conversation, message: opening.message, account: account, showing: opening.emoji,
                                react: reacts ? { react($0, $1) } : nil)
                    .presentationDetents([.medium, .large])
            }
        }
        .fullScreenCover(item: $camera) { opening in
            // Captured, it stays on the camera until it's sent here (Nate, 2026-10-30).
            CameraScreen(maxSeconds: limits?.videoMaxSeconds ?? 10, maxBytes: limits?.videoMaxBytes ?? 4 << 20,
                         send: .chat(conversation.title) { ready in
                             try await ready.send(to: conversation, limits: limits)
                             tapped += 1
                             camera = nil
                         },
                         start: opening.start)
        }
        .task { limits = try? await Server(AppInfo.server).config() }
        .fullScreenCover(item: Binding(get: { viewing.map(IdentifiedPic.init) }, set: { viewing = $0?.pic })) { item in
            // This one, then the others still waiting after it.
            let waiting = conversation.bubbles.compactMap(\.opening)
            let from = waiting.firstIndex(of: item.pic) ?? 0
            PicViewer(pics: Array(waiting[from...]), conversation: conversation)
        }
        .sheet(item: $reporting, onDismiss: { if unfriended { dismiss() } }) { target in
            if let account = session.account {
                ReportSheet(target: target, account: account) { who in
                    // Blocked from the sheet: a direct chat with them closes once it's gone.
                    if conversation.friend?.id == who.id { unfriended = true }
                }
            }
        }
        .blockQuestion($blocking) { who in Task { await block(who) } }
        .environment(\.ownSite, ownSite)
        .environment(\.openURL, openLinks)
        .alert("Something went wrong", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func accept(verified: Bool) async {
        do {
            try await conversation.acceptNewKey(verified: verified)
        } catch {
            session.noticed(error)
        }
    }

    /// The page before the oldest shown, joining above what you're reading.
    private func older() async {
        do {
            try await conversation.loadOlder()
        } catch {
            session.noticed(error)
        }
    }

    /// The time shows under the last of a run: the next message is someone
    /// else's, or more than five minutes later.
    private func endsARun(_ this: Bubble, _ next: Bubble?) -> Bool {
        guard let next else { return true }
        return next.mine != this.mine || next.sender != this.sender || next.time.timeIntervalSince(this.time) > 5 * 60
    }

    /// What a reply quotes: the message it answers, if it's loaded.
    private func quote(_ id: Int64) -> String {
        guard let original = conversation.bubble(id) else { return "A message from earlier" }
        let who = original.mine ? "You" : original.sender ?? conversation.title
        return "\(who): \(original.gist)"
    }
}

/// A text on its way, under the chat: "Sending…", or why it wasn't sent and what to do.
struct OutgoingView: View {
    let item: Outgoing
    let quote: String?
    let retry: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            BubbleView(bubble: Bubble(id: 0, mine: true, sender: nil, content: .text(item.text, edited: false), replyTo: item.replyTo,
                                      time: .now, reactions: []),
                       quote: quote, showTime: false)
                .opacity(0.6)
            switch item.status {
            case .sending:
                Text("Sending…").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4)
            case .failed(let why):
                HStack(spacing: 4) {
                    Text(why)
                    Button("Try again", action: retry)
                    Text("·")
                    Button("Remove", action: remove)
                }
                .font(.caption2).foregroundStyle(.red).padding(.horizontal, 4)
            case .held:
                // In order: it goes once the one above is sent, or removed.
                HStack(spacing: 4) {
                    Text("Waiting for the text above.")
                    Button("Remove", action: remove)
                }
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

struct BubbleView: View {
    /// Links in texts to it are tappable (ChatLink); nothing else in a text is.
    @Environment(\.ownSite) private var ownSite
    let bubble: Bubble
    let quote: String?
    var showTime = true
    /// Tapping a reaction under the message shows who reacted (F21), from that emoji.
    var whoReacted: ((String) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var textSize
    /// The widest a message's row gets, at the usual text size: about 60
    /// letters a line, however wide the screen (the Duo's open one is 669
    /// points). It grows with the text, so a line holds about as many words.
    @ScaledMetric(relativeTo: .body) private var readable = 480.0

    var body: some View {
        switch bubble.content {
        case .event(let words):
            Text(words).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        default:
            // The gap on the other side shows whose it is; with the largest text it gives the words more room.
            let gap: CGFloat = textSize.isAccessibilitySize ? 24 : 48
            HStack {
                if bubble.mine { Spacer(minLength: gap) }
                VStack(alignment: bubble.mine ? .trailing : .leading, spacing: 2) {
                    if let sender = bubble.sender {
                        Text(sender).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if let quote {
                            Text(quote).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                                .padding(.leading, 8)
                                .overlay(alignment: .leading) { Capsule().fill(.secondary).frame(width: 2) }
                        }
                        content
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(bubble.mine ? Color.accentColor.opacity(0.3) : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if showTime || !bubble.reactions.isEmpty {
                        HStack(spacing: 4) {
                            if !bubble.reactions.isEmpty {
                                // In the order they were first given, as on the web (ReactionSummary).
                                ForEach(ReactionSummary(bubble.reactions).entries) { entry in
                                    let emoji = entry.emoji, count = entry.people.count
                                    Button { whoReacted?(emoji) } label: {
                                        Text(count > 1 ? "\(emoji)\(count)" : emoji)
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(bubble.myReaction == emoji ? Color.accentColor.opacity(0.25) : .clear, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(whoReacted == nil)
                                    .accessibilityLabel("\(emoji) \(count)\(bubble.myReaction == emoji ? ", including you" : "")")
                                    .accessibilityHint("Shows who reacted")
                                }
                            }
                            if showTime { Text(bubble.time.formatted(date: .omitted, time: .shortened)) }
                        }
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                }
                if !bubble.mine { Spacer(minLength: gap) }
            }
            .frame(maxWidth: readable, alignment: bubble.mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: bubble.mine ? .trailing : .leading)
        }
    }

    @ViewBuilder private var content: some View {
        switch bubble.content {
        case .text(let text, let edited):
            VStack(alignment: .leading, spacing: 2) {
                Text(ChatLink.linked(text, site: ownSite))
                if edited { Text("Edited").font(.caption2).foregroundStyle(.secondary) }
            }
        case .media(let words):
            if let pic = bubble.opening {
                Label(pic.isVideo ? "Tap to view video" : "Tap to view pic", systemImage: pic.isVideo ? "video.fill" : "photo.fill")
                    .foregroundStyle(Color.accentColor).fontWeight(.semibold)
            } else {
                Label(words, systemImage: words.contains("ideo") ? "video" : "photo").foregroundStyle(.secondary)
            }
        case .unreadable(let words):
            Label(words, systemImage: "lock.trianglebadge.exclamationmark").font(.callout).foregroundStyle(.secondary)
        case .event:
            EmptyView()
        }
    }
}

/// A held message, lifted over the dimmed chat: one row of reactions above it
/// (scrolling sideways when they don't all fit), its actions below. Tapping
/// anywhere else puts it down.
struct MessageActions: View {
    struct Action: Identifiable {
        let title: String
        let icon: String
        let run: () -> Void
        var id: String { title }
    }

    let bubble: Bubble
    let quote: String?
    /// The quick row (E2E.reactions); + after them picks any other emoji (X49).
    let reactions: [String]
    let actions: [Action]
    let react: (String) -> Void
    let dismiss: () -> Void
    /// The emoji keyboard is up, for any emoji.
    @State private var pickingAny = false
    /// The reactions: about the size of the message's words, a touch bigger,
    /// each in a finger's worth (44 points). Both grow with the text, up to
    /// half as big again, and the row scrolls sideways past what fits.
    @ScaledMetric(relativeTo: .body) private var emojiSize = 26.0
    @ScaledMetric(relativeTo: .body) private var circle = 44.0
    @ScaledMetric(relativeTo: .body) private var plusSize = 20.0
    /// The actions' width at the usual text size; with larger text, up to the whole width.
    @ScaledMetric(relativeTo: .body) private var menuWidth = 230.0

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityAddTraits(.isButton).accessibilityLabel("Close")
            // In the middle of the screen; taller than the screen (a long message, the largest
            // text, a small phone), it scrolls instead of cutting the message short.
            GeometryReader { space in
                ScrollView {
                    held
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: space.size.height, alignment: bubble.mine ? .trailing : .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismiss)  // around it, as on the dimmed chat
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var held: some View {
        VStack(alignment: bubble.mine ? .trailing : .leading, spacing: 10) {
            if !reactions.isEmpty {
                // Your own first if it's another emoji (so it can be taken back here too), then the quick row.
                let row = (bubble.myReaction.map { reactions.contains($0) ? [] : [$0] } ?? []) + reactions
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(row, id: \.self) { emoji in
                                let mine = bubble.myReaction == emoji
                                Button {
                                    react(emoji)
                                    dismiss()
                                } label: {
                                    Text(emoji).font(.system(size: min(emojiSize, 39)))
                                        .frame(width: min(circle, 66), height: min(circle, 66))
                                        .background(mine ? Color.accentColor.opacity(0.35) : .clear, in: Circle())
                                }
                                .accessibilityLabel(mine ? "Take back \(emoji)" : "React \(emoji)")
                            }
                        }
                        .padding(.leading, 8).padding(.vertical, 4)
                    }
                    .frame(maxWidth: CGFloat(row.count) * (min(circle, 66) + 4) + 8)  // hugs them; scrolls past that
                    // Always in sight, past the row: any other emoji.
                    Button { pickingAny = true } label: {
                        Image(systemName: "plus").font(.system(size: min(plusSize, 30), weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .frame(width: min(circle, 66), height: min(circle, 66))
                            .background(pickingAny ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel("React with another emoji")
                    .padding(.horizontal, 6)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    // The system's emoji keyboard, unseen: the first emoji typed is the reaction.
                    EmojiField(active: $pickingAny) { emoji in
                        react(emoji)
                        dismiss()
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityIdentifier("any-emoji")
                }
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 10, y: 2)
                .frame(maxWidth: 420)
            }
            BubbleView(bubble: bubble, quote: quote, showTime: false)
                .allowsHitTesting(false)
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            if !actions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(actions) { action in
                        Button {
                            dismiss()
                            action.run()
                        } label: {
                            HStack {
                                Text(action.title)
                                Spacer()
                                Image(systemName: action.icon)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if action.id != actions.last?.id { Divider() }
                    }
                }
                .frame(maxWidth: menuWidth)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 2)
            }
        }
    }
}

/// Any emoji as a reaction (X49), from the system's own emoji keyboard: an
/// unseen text field that asks for it (the phone's every emoji, skin tones,
/// search, and recents, all the system's; nothing to keep up to date here).
/// The first emoji typed is the reaction; anything else typed is ignored. A
/// phone without the emoji keyboard gets its usual one, whose globe key
/// reaches emoji.
struct EmojiField: UIViewRepresentable {
    @Binding var active: Bool
    let picked: (String) -> Void

    final class Field: UITextField {
        /// Not the keyboard last used in this field: the emoji one, each time.
        override var textInputContextIdentifier: String? { "" }
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiField
        init(_ parent: EmojiField) { self.parent = parent }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString typed: String) -> Bool {
            if let emoji = EmojiField.reaction(in: typed) {
                let picked = parent.picked
                DispatchQueue.main.async { picked(emoji) }  // after the keyboard's done with this keystroke
            }
            return false  // nothing stays in the field
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.active { parent.active = false }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.tintColor = .clear
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        // Not while SwiftUI is updating views: the keyboard coming changes the layout.
        if active && !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !active && field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ field: Field, coordinator: Coordinator) {
        field.resignFirstResponder()
    }

    /// The first emoji in what was typed, if it's one reaction (E2E.isReaction).
    static func reaction(in typed: String) -> String? {
        typed.lazy.map(String.init).first(where: E2E.isReaction)
    }
}

/// Swipe a message right to reply, as people expect on a phone: it follows the
/// finger a little, and past the threshold a tap of haptics and the reply bar.
/// Vertical drags are left to the scroll view.
/// Holding a message brings its menu while the finger is still down, with a
/// haptic then (ChatScreen), and the bubble gives a little under the finger
/// until it comes. Only a message that has a menu gives. The pressed state is
/// the row's own, so a touch redraws one bubble, not the chat.
struct HoldForMenu: ViewModifier {
    let enabled: Bool
    let open: () -> Void
    @State private var pressing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressing ? 0.95 : 1)
            .animation(.easeOut(duration: 0.2), value: pressing)
            // Before the tap (ChatScreen), so it isn't waiting on the tap: the
            // menu comes at the moment, while the finger is down, not when it lifts.
            .onLongPressGesture(minimumDuration: 0.35) {
                pressing = false
                if enabled { open() }
            } onPressingChanged: { down in
                pressing = down && enabled
            }
    }
}

struct SwipeToReply: ViewModifier {
    let enabled: Bool
    let reply: () -> Void
    @State private var offset: CGFloat = 0
    @State private var fired = false
    static let threshold: CGFloat = 60

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .overlay(alignment: .leading) {
                if offset > 8 {
                    Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(.secondary)
                        .opacity(Double(min(1, offset / Self.threshold))).offset(x: offset - 30)
                }
            }
            .simultaneousGesture(enabled ? DragGesture(minimumDistance: 15)
                .onChanged { value in
                    // Only a mostly-sideways drag to the right; scrolling stays scrolling.
                    guard value.translation.width > 0, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    offset = min(value.translation.width, Self.threshold * 1.3)
                    if offset >= Self.threshold && !fired { fired = true }
                }
                .onEnded { _ in
                    if fired { reply() }
                    fired = false
                    withAnimation(.spring(duration: 0.25)) { offset = 0 }
                } : nil)
            .sensoryFeedback(.impact(weight: .light), trigger: fired) { _, now in now }
    }
}

/// A pic to open, for `fullScreenCover(item:)`.
struct IdentifiedPic: Identifiable {
    let pic: PicToOpen
    var id: String {
        switch pic {
        case .direct(let m): "d\(m.id)"
        case .group(let m): "g\(m.id)"
        }
    }
}

/// Every version of an edited text, oldest first, each opened on the phone (app.js, `showEdits`).
struct EditsSheet: View {
    let bubble: Bubble
    let conversation: Conversation
    @State private var versions: [Conversation.Version] = []
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if versions.isEmpty && problem == nil { ProgressView() }
                ForEach(versions) { v in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(v.label) · \(v.at.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        Text(v.text ?? "Couldn't decrypt this version.").foregroundStyle(v.text == nil ? .secondary : .primary)
                    }
                }
                if let problem { Text("Couldn't load the edits. \(problem)").foregroundStyle(.red) }
            }
            .navigationTitle("Edits")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                do { versions = try await conversation.versions(of: bubble) } catch { problem = error.localizedDescription }
            }
        }
    }
}
