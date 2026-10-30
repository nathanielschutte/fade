import NapsackCrypto
import SwiftUI
import UIKit

/// An open chat: its history, newest at the bottom, older pages loading as you
/// scroll up. Opening it marks it read. A friend's changed key shows a warning
/// at the top until it's accepted. Texts are written at the bottom. A long
/// press on a message reacts, replies, copies, or (your own text, for 15
/// minutes) edits it. New messages arrive live (Live.swift).
struct ChatScreen: View {
    @Environment(Session.self) private var session
    @Environment(Live.self) private var live
    @Environment(\.dismiss) private var dismiss
    /// Unfriended from their profile: back to the list once the profile's gone.
    @State private var unfriended = false
    @State var conversation: Conversation
    /// The message at the top of the screen, kept there while older ones load above it.
    @State private var position: Int64?
    @State private var showingSafetyCode = false
    @State private var draft = ""
    @State private var replyingTo: Bubble?
    @State private var editing: Bubble?
    @State private var failure: String?
    /// The message being held: its reactions and actions show over the chat.
    @State private var held: Bubble?
    @FocusState private var composing: Bool

    var body: some View {
        ScrollViewReader { proxy in
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
                ForEach(Array(conversation.bubbles.enumerated()), id: \.element.id) { index, bubble in
                    message(index, bubble)
                }
                ForEach(conversation.outbox) { item in
                    OutgoingView(item: item, quote: item.replyTo.map(quote),
                                 retry: { Task { await conversation.retry(item.id) } },
                                 remove: {
                                     if let text = conversation.discard(item.id), draft.isEmpty { draft = text }  // nothing lost
                                 })
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $position, anchor: .top)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { composer(proxy) }
        .onChange(of: conversation.bubbles.last?.id) { before, after in
            // A newer message came (older pages change the first, not the last).
            if before != nil, let after { withAnimation { proxy.scrollTo(after, anchor: .bottom) } }
        }
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
        .sensoryFeedback(.impact(weight: .medium), trigger: held?.id) { _, now in now != nil }
        .alert("Something went wrong", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A friend's name (and picture) opens their profile, as on the web.
            if let friend = conversation.friend, friend.system != true, let account = session.account {
                ToolbarItem(placement: .principal) {
                    NavigationLink {
                        FriendProfileScreen(friend: friend, account: account, safetyCode: conversation.safetyCode ?? "",
                                            unfriended: { unfriended = true }, model: ProfileModel(account: account))
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
        }
        .sheet(isPresented: $showingSafetyCode) {
            if let friend = conversation.friend, let code = conversation.safetyCode {
                SafetyCodeScreen(username: friend.username, code: code, keyChanged: conversation.keyChanged) {
                    Task { await accept(verified: true) }
                }
                .presentationDetents([.medium, .large])
            }
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
                await conversation.markRead()
            } catch {
                Reporter.shared.report(.warn, "loading a chat failed", Reporter.fields(error))
                conversation.noted(error)
                session.noticed(error)
            }
        }
    }

    @ViewBuilder private func composer(_ proxy: ScrollViewProxy) -> some View {
        if let note = conversation.blockedNote {
            Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(12).background(.bar)
        } else if conversation.loaded {
            VStack(spacing: 6) {
                if let typing = conversation.typingLine {
                    Text(typing).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
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
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .onChange(of: draft) { _, text in if !text.isEmpty { conversation.noteTyping(live) } }
                        .lineLimit(1...5)
                        .focused($composing)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .disabled(!conversation.canSend)
                        .accessibilityIdentifier("composer")
                    Button { send(proxy) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(!conversation.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// What a long press offers (app.js, the message actions).
    /// One message: its day header when the day changes, the bubble, and "Seen" under my newest text once read.
    @ViewBuilder private func message(_ index: Int, _ bubble: Bubble) -> some View {
        if index == 0 || !Calendar.current.isDate(bubble.time, inSameDayAs: conversation.bubbles[index - 1].time) {
            Text(bubble.time.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 10)
        }
        BubbleView(bubble: bubble, quote: bubble.replyTo.map(quote), showTime: endsARun(index))
            .id(bubble.id)
            .onLongPressGesture(minimumDuration: 0.35) { if holdable(bubble) { held = bubble } }
            .accessibilityAction(named: "Message actions") { if holdable(bubble) { held = bubble } }
        if bubble.id == conversation.seenId {
            Text("Seen").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 4)
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
        if conversation.canSend, bubble.canEdit, case .text(let text, _) = bubble.content {
            actions.append(.init(title: "Edit", icon: "pencil") {
                replyingTo = nil
                editing = bubble
                draft = text
                composing = true
            })
        }
        return actions
    }

    /// Whether holding this message offers anything at all.
    private func holdable(_ bubble: Bubble) -> Bool {
        (conversation.canSend && bubble.repliable) || !actions(bubble).isEmpty
    }

    private func react(_ bubble: Bubble, _ emoji: String) {
        Task {
            do { try await conversation.react(bubble, emoji) } catch { trouble(error) }
        }
    }

    private func trouble(_ error: any Error) {
        Reporter.shared.report(.warn, "message action failed", Reporter.fields(error))
        session.noticed(error)
        failure = error.localizedDescription
    }

    private func send(_ proxy: ScrollViewProxy) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, conversation.canSend else { return }
        draft = ""
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
        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
        Task {
            await conversation.retry(id)
            if conversation.outbox.isEmpty, let last = conversation.bubbles.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
        }
    }

    private func accept(verified: Bool) async {
        do {
            try await conversation.acceptNewKey(verified: verified)
        } catch {
            session.noticed(error)
        }
    }

    private func older() async {
        let top = conversation.bubbles.first?.id
        do {
            try await conversation.loadOlder()
            position = top  // stay where you were, with the older messages above
        } catch {
            session.noticed(error)
        }
    }

    /// The time shows under the last of a run: the next message is someone
    /// else's, or more than five minutes later.
    private func endsARun(_ index: Int) -> Bool {
        let bubbles = conversation.bubbles
        guard index + 1 < bubbles.count else { return true }
        let this = bubbles[index], next = bubbles[index + 1]
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
            }
        }
    }
}

struct BubbleView: View {
    let bubble: Bubble
    let quote: String?
    var showTime = true

    var body: some View {
        switch bubble.content {
        case .event(let words):
            Text(words).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        default:
            HStack {
                if bubble.mine { Spacer(minLength: 48) }
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
                            if !bubble.reactions.isEmpty { Text(bubble.reactions.joined()) }
                            if showTime { Text(bubble.time.formatted(date: .omitted, time: .shortened)) }
                        }
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                }
                if !bubble.mine { Spacer(minLength: 48) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch bubble.content {
        case .text(let text, let edited):
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if edited { Text("Edited").font(.caption2).foregroundStyle(.secondary) }
            }
        case .media(let words):
            Label(words, systemImage: words.contains("ideo") ? "video" : "photo").foregroundStyle(.secondary)
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
    let reactions: [String]
    let actions: [Action]
    let react: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityAddTraits(.isButton).accessibilityLabel("Close")
            VStack(alignment: bubble.mine ? .trailing : .leading, spacing: 10) {
                if !reactions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(reactions, id: \.self) { emoji in
                                let mine = bubble.myReaction == emoji
                                Button {
                                    react(emoji)
                                    dismiss()
                                } label: {
                                    // About the size of the message's words, a touch bigger.
                                    Text(emoji).font(.system(size: 26))
                                        .frame(width: 44, height: 44)
                                        .background(mine ? Color.accentColor.opacity(0.35) : .clear, in: Circle())
                                }
                                .accessibilityLabel(mine ? "Take back \(emoji)" : "React \(emoji)")
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 2)
                    .frame(maxWidth: min(CGFloat(reactions.count) * 48 + 16, 340))  // hugs them; scrolls past that
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
                    .frame(width: 230)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 2)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: bubble.mine ? .trailing : .leading)
        }
    }
}
