import SwiftUI

/// An open chat: its history, newest at the bottom, older pages loading as you
/// scroll up. Opening it marks it read. Sending comes next (plan-ios.md).
struct ChatScreen: View {
    @Environment(Session.self) private var session
    @State var conversation: Conversation
    /// The message at the top of the screen, kept there while older ones load above it.
    @State private var position: Int64?

    var body: some View {
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
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $position, anchor: .top)
        .overlay {
            if !conversation.loaded {
                if let problem = conversation.problem {
                    ContentUnavailableView("Couldn't load this chat", systemImage: "exclamationmark.bubble", description: Text(problem))
                } else {
                    ProgressView("Loading…")
                }
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
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
