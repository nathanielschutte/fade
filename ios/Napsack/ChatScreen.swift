import SwiftUI

/// An open chat: its history, newest at the bottom, older pages loading as you
/// scroll up. Opening it marks it read. A friend's changed key shows a warning
/// at the top until it's accepted. Texts are written at the bottom; a long
/// press on a message replies to it.
struct ChatScreen: View {
    @Environment(Session.self) private var session
    @State var conversation: Conversation
    /// The message at the top of the screen, kept there while older ones load above it.
    @State private var position: Int64?
    @State private var showingSafetyCode = false
    @State private var draft = ""
    @State private var replyingTo: Bubble?
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
                    if index == 0 || !Calendar.current.isDate(bubble.time, inSameDayAs: conversation.bubbles[index - 1].time) {
                        Text(bubble.time.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 10)
                    }
                    BubbleView(bubble: bubble, quote: bubble.replyTo.map(quote), showTime: endsARun(index))
                        .id(bubble.id)
                        .contextMenu {
                            if conversation.canSend, bubble.repliable {
                                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                                    replyingTo = bubble
                                    composing = true
                                }
                            }
                        }
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
        .overlay {
            if !conversation.loaded {
                if let problem = conversation.problem {
                    ContentUnavailableView("Couldn't load this chat", systemImage: "exclamationmark.bubble", description: Text(problem))
                } else {
                    ProgressView("Loading…")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if conversation.keyChanged, let friend = conversation.friend {
                KeyWarning(friend: friend, compare: { showingSafetyCode = true }, accept: { Task { await accept() } })
                    .padding(.horizontal, 12).padding(.top, 4).background(.bar)
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                    Task { await accept() }
                }
                .presentationDetents([.medium, .large])
            }
        }
        }
        .task {
            do {
                try await conversation.loadNewest()
                await conversation.markRead()
            } catch {
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
                if let replyingTo {
                    HStack {
                        Text("Replying to \(replyingTo.mine ? "yourself" : replyingTo.sender ?? conversation.title): \(replyingTo.gist)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Cancel reply", systemImage: "xmark") { self.replyingTo = nil }
                            .labelStyle(.iconOnly).font(.caption)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message", text: $draft, axis: .vertical)
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

    private func send(_ proxy: ScrollViewProxy) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, conversation.canSend else { return }
        draft = ""
        let reply = replyingTo?.id
        replyingTo = nil
        let id = conversation.queue(text, replyTo: reply)
        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
        Task {
            await conversation.retry(id)
            if conversation.outbox.isEmpty, let last = conversation.bubbles.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
        }
    }

    private func accept() async {
        do {
            try await conversation.acceptNewKey()
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
                Text(text).textSelection(.enabled)
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
