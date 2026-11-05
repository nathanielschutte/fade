import SwiftUI

// See who reacted (F21): a tap on a reaction under a message shows who
// reacted with that emoji, and All, every emoji with who gave it, each person
// with their picture and the name the app calls them (X45, X47), opening
// their profile on a tap (X46). Direct reactions are opened on the phone
// (only the two of you can read them); a group's come from the server as
// they are. The sheet reads the message from the chat, so a reaction that
// arrives while it's open shows in it. As the web app's (app.js, "who reacted").

/// Who reacted to a message with what: each emoji in the order it was first
/// given, with who gave it, me first, then in the order they reacted
/// (app.js, `reactionSummary`).
struct ReactionSummary: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        let emoji: String
        let people: [Int64]
        var id: String { emoji }
    }

    let entries: [Entry]

    init(_ reactions: [Bubble.Reaction], me: Int64? = nil) {
        var order: [String] = [], by: [String: [Int64]] = [:]
        for r in reactions {
            if by[r.emoji] == nil { order.append(r.emoji) }
            by[r.emoji, default: []].append(r.user)
        }
        entries = order.map { emoji in
            let people = by[emoji] ?? []
            guard let me, people.contains(me) else { return Entry(emoji: emoji, people: people) }
            return Entry(emoji: emoji, people: [me] + people.filter { $0 != me })
        }
    }

    var isEmpty: Bool { entries.isEmpty }
    /// How many reacted, whatever with (one each).
    var total: Int { entries.reduce(0) { $0 + $1.people.count } }

    /// The emoji to show: the one asked for while anyone still has it, else All (nil).
    func showing(_ emoji: String?) -> String? {
        entries.contains { $0.emoji == emoji } ? emoji : nil
    }

    /// Who's listed: those who gave `emoji`, or (nil) everyone, each with theirs.
    func rows(_ emoji: String?) -> [Bubble.Reaction] {
        entries.filter { emoji == nil || $0.emoji == emoji }
            .flatMap { entry in entry.people.map { Bubble.Reaction(user: $0, emoji: entry.emoji) } }
    }

    /// The button under the list: react with the emoji shown, or take mine
    /// back (the one shown, or on All). Nil: nothing to offer.
    static func offer(showing: String?, mine: String?) -> (emoji: String, words: String)? {
        guard let emoji = showing ?? mine else { return nil }
        if mine == emoji { return (emoji, "Take back your \(emoji)") }
        return (emoji, mine == nil ? "React \(emoji)" : "React \(emoji) instead")
    }
}

/// Which message's reactions are showing, and which emoji first.
struct ReactionsOpening: Identifiable, Equatable {
    let message: Int64
    let emoji: String
    var id: Int64 { message }
}

/// The sheet a reaction opens: All and each emoji along the top, who reacted
/// below, then a button to react with the emoji shown or take yours back.
struct WhoReactedSheet: View {
    let conversation: Conversation
    let message: Int64
    let account: Account
    /// Reacting from here: nil where this chat can't (read-only, or a message that takes none).
    var react: ((Bubble, String) -> Void)?
    /// The emoji shown; nil is All.
    @State var showing: String?
    @Environment(\.dismiss) private var dismiss

    init(conversation: Conversation, message: Int64, account: Account, showing: String?, react: ((Bubble, String) -> Void)? = nil) {
        self.conversation = conversation
        self.message = message
        self.account = account
        self.react = react
        _showing = State(initialValue: showing)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Reactions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }

    @ViewBuilder private var content: some View {
        let bubble = conversation.bubble(message)
        let summary = ReactionSummary(bubble?.reactions ?? [], me: account.user.id)
        if let bubble, !summary.isEmpty {
            let shown = summary.showing(showing)
            List {
                Section {
                    // On All, each one's emoji sits on their picture's corner, whatever the name's length or the text size.
                    ForEach(summary.rows(shown), id: \.user) { row in
                        let badge = shown == nil ? row.emoji : nil
                        Group {
                            if let person = conversation.person(row.user) {
                                PersonLink(person: person, account: account, friends: conversation.friendsById, badge: badge)
                            } else {
                                // No longer in the group, and their name isn't known here: nothing to open.
                                PersonRow(person: Person(id: row.user, username: "Someone", friends: [:]), badge: badge)
                            }
                        }
                        .accessibilityValue(badge ?? "")
                    }
                } header: {
                    tabs(summary, shown: shown)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text(privacy)
                }
                if let react, let offer = ReactionSummary.offer(showing: shown, mine: bubble.myReaction) {
                    Section {
                        Button(offer.words) { react(bubble, offer.emoji) }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("reaction-mine")
                    }
                }
            }
        } else {
            ContentUnavailableView("No reactions now", systemImage: "face.smiling",
                                   description: Text("Nobody has reacted to this message now."))
        }
    }

    /// All, then each emoji with how many; they wrap onto more lines rather than scrolling out of sight.
    private func tabs(_ summary: ReactionSummary, shown: String?) -> some View {
        FlowLayout(spacing: 6) {
            tab(nil, "All", count: summary.total, shown: shown)
            ForEach(summary.entries) { entry in
                tab(entry.emoji, entry.emoji, count: entry.people.count, shown: shown)
            }
        }
        .padding(.vertical, 8)
    }

    private func tab(_ emoji: String?, _ label: String, count: Int, shown: String?) -> some View {
        let on = shown == emoji
        return Button { showing = emoji } label: {
            HStack(spacing: 4) {
                Text(label).fontWeight(on ? .semibold : .regular)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: 36)
            .background(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07), in: Capsule())
            .overlay { if on { Capsule().strokeBorder(Color.accentColor.opacity(0.6)) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(emoji.map { "\($0), \(count)" } ?? "All reactions, \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Who else can see them (every client says so in each group, CLAUDE.md).
    private var privacy: String {
        if case .group = conversation.chat {
            "Reactions in groups aren't end-to-end encrypted yet: the napsack server can see them."
        } else {
            "End-to-end encrypted: only the two of you can see these."
        }
    }
}

/// Lays its views out in rows, left to right, starting a new row when the next doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .init(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: width, height: nil))
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + min(size.width, width)
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
