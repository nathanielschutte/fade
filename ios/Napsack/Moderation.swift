import SwiftUI

// Reporting and blocking (docs/design/report-and-block.md; the server's
// reports.rs and blocks.rs). A report carries ids only: the message's id
// (and its group's), or the person's, with a reason from a fixed list and the
// reporter's own note. Never a message's content, decrypted or not: the
// server can't see it, and a report mustn't change that. Blocking ends the
// friendship, stops them sending you anything or adding you to groups, and
// they aren't told; groups you're both in stay (you can leave). Both answer
// the same "not someone you can…" for anyone you don't know, whether they
// exist or not.

/// Why something's reported: the server's fixed list, in the design's words.
enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case spam, harassment, nudity, violence, hate, other

    var id: String { rawValue }

    var words: String {
        switch self {
        case .spam: "Spam"
        case .harassment: "Harassment or bullying"
        case .nudity: "Nudity or sexual content"
        case .violence: "Violence or threats"
        case .hate: "Hate"
        case .other: "Something else"
        }
    }
}

/// Someone who can be reported or blocked, as the app names them.
struct Reportable: Equatable, Sendable, Identifiable {
    let id: Int64
    let name: String
}

/// What's being reported: a message (in a direct chat or a group) or a person.
struct ReportTarget: Equatable, Sendable, Identifiable {
    enum What: Equatable, Sendable {
        case message(Int64)
        case groupMessage(group: Int64, message: Int64)
        case person
    }

    let what: What
    /// Whom it's about: who sent the message, or the person.
    let person: Reportable

    var id: String {
        switch what {
        case .message(let m): "m\(m)"
        case .groupMessage(let g, let m): "g\(g)-\(m)"
        case .person: "p\(person.id)"
        }
    }

    var isMessage: Bool { what != .person }

    /// A message in a chat, if it's one you can report: a text, pic, or video
    /// someone else sent. Not your own, not a group's events, not one that
    /// couldn't be opened (you haven't seen it), and not Team Napsack's.
    static func message(_ bubble: Bubble, in chat: Conversation.Chat, friends: [Int64: Friend] = [:]) -> ReportTarget? {
        guard !bubble.mine else { return nil }
        switch bubble.content {
        case .text, .media: break
        case .event, .unreadable: return nil
        }
        switch chat {
        case .friend(let friend):
            guard friend.system != true else { return nil }
            return ReportTarget(what: .message(bubble.id), person: Reportable(id: friend.id, name: friend.name))
        case .group(let group):
            guard bubble.senderId > 0, friends[bubble.senderId]?.system != true else { return nil }
            return ReportTarget(what: .groupMessage(group: group.id, message: bubble.id),
                                person: Reportable(id: bubble.senderId, name: bubble.sender ?? friends[bubble.senderId]?.name ?? "them"))
        }
    }

    /// What goes to the server (`POST /api/reports`): ids, the reason, and the note. Nothing else.
    struct Body: Encodable, Equatable {
        let kind: String
        let messageId: Int64?
        let groupId: Int64?
        let userId: Int64?
        let reason: String
        let note: String?
    }

    func body(reason: ReportReason, note: String) -> Body {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = note.isEmpty ? nil : note
        switch what {
        case .message(let m):
            return Body(kind: "message", messageId: m, groupId: nil, userId: nil, reason: reason.rawValue, note: words)
        case .groupMessage(let g, let m):
            return Body(kind: "group_message", messageId: m, groupId: g, userId: nil, reason: reason.rawValue, note: words)
        case .person:
            return Body(kind: "person", messageId: nil, groupId: nil, userId: person.id, reason: reason.rawValue, note: words)
        }
    }
}

/// Someone you've blocked (`GET /api/blocks`).
struct BlockedPerson: Decodable, Equatable, Identifiable, Sendable {
    let id: Int64
    let username: String
    let blockedAt: Int64
}

/// The requests (reports.rs, blocks.rs).
enum Moderation {
    /// The note's longest (the server's limit).
    static let noteLimit = 500

    struct Filed: Decodable, Equatable, Sendable {
        let id: Int64
        /// Reported before: this is the first report, still the one that counts.
        let already: Bool
    }

    static func report(_ target: ReportTarget, reason: ReportReason, note: String, account: Account,
                       transport: any Transport = NetworkTransport()) async throws -> Filed {
        let data = try await Server(account.server, transport: transport).send(
            "reports", method: "POST", token: account.token, json: target.body(reason: reason, note: note))
        return try Server.decoder.decode(Filed.self, from: data)
    }

    /// Blocks them; returns whether they were blocked already. The server then
    /// sends both of you `friends_changed`, which reloads the chat list.
    @discardableResult
    static func block(_ id: Int64, account: Account, transport: any Transport = NetworkTransport()) async throws -> Bool {
        struct Answer: Decodable { let already: Bool }
        let data = try await Server(account.server, transport: transport).send("blocks/\(id)", method: "POST", token: account.token)
        return try Server.decoder.decode(Answer.self, from: data).already
    }

    /// Unblocks them. The friendship stays ended.
    static func unblock(_ id: Int64, account: Account, transport: any Transport = NetworkTransport()) async throws {
        _ = try await Server(account.server, transport: transport).send("blocks/\(id)/remove", method: "POST", token: account.token)
    }

    /// Who you block, newest first.
    static func blocked(account: Account, transport: any Transport = NetworkTransport()) async throws -> [BlockedPerson] {
        struct Answer: Decodable { let blocks: [BlockedPerson] }
        return try Server.decoder.decode(Answer.self, from: await Server(account.server, transport: transport)
            .send("blocks", token: account.token)).blocks
    }

    /// What reporting tells you, under the reasons (the design's words for a message).
    static func whatHappens(_ target: ReportTarget) -> String {
        target.isMessage
            ? "An Admin will look at it. They'll see who sent it and when, but never what it said."
            : "An Admin will look at it. They'll see who you reported, but never what either of you said."
    }

    /// Asked before blocking.
    static func blockTitle(_ name: String) -> String { "Block \(name)?" }
    static let blockWords = "Your friendship ends, and they can't send you anything or add you to groups. They aren't told. Groups you're both in stay as they are, and you can leave them."
    static let unblockWords = "They can send you a friend request again. Your friendship stays ended until one of you asks and the other accepts."
}

extension View {
    /// "Block Ana?" with what it does, then `block` if they say yes.
    func blockQuestion(_ person: Binding<Reportable?>, block: @escaping (Reportable) -> Void) -> some View {
        confirmationDialog(person.wrappedValue.map { Moderation.blockTitle($0.name) } ?? "",
                           isPresented: Binding(get: { person.wrappedValue != nil }, set: { if !$0 { person.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: person.wrappedValue) { who in
            Button("Block", role: .destructive) { block(who) }
        } message: { _ in
            Text(Moderation.blockWords)
        }
    }
}

/// Reporting a message or a person: a reason, an optional line of your own,
/// then send. Once it's sent, it offers to block them too.
struct ReportSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let target: ReportTarget
    let account: Account
    /// Whether they're blocked already (nothing to offer after).
    var alreadyBlocked = false
    /// They were blocked from here.
    var blocked: (Reportable) -> Void = { _ in }
    var transport: any Transport = NetworkTransport()
    @State private var reason: ReportReason?
    @State private var note = ""
    @State private var sending = false
    @State private var problem: String?
    /// Sent, and what the server said (set at the start only to look at it, in tests).
    @State var filed: Moderation.Filed? = nil
    @State private var blocking: Reportable?
    @State private var blockedHere = false

    var body: some View {
        NavigationStack {
            Form {
                if let filed { sent(filed) } else { form }
            }
            .navigationTitle(target.isMessage ? "Report message" : "Report \(target.person.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: filed == nil ? .cancellationAction : .confirmationAction) {
                    Button(filed == nil ? "Cancel" : "Done") { dismiss() }.disabled(sending)
                }
            }
            .interactiveDismissDisabled(sending)
            .blockQuestion($blocking) { who in Task { await block(who) } }
        }
    }

    @ViewBuilder private var form: some View {
        Section {
            ForEach(ReportReason.allCases) { r in
                Button { reason = r } label: {
                    HStack {
                        Text(r.words)
                        Spacer()
                        if reason == r { Image(systemName: "checkmark").fontWeight(.semibold) }
                    }
                    .contentShape(Rectangle())
                }
                .tint(.primary)  // the words in the text's own color (the pale accent is hard to read)
                .accessibilityAddTraits(reason == r ? .isSelected : [])
            }
        } header: {
            Text(target.isMessage ? "What's wrong with it?" : "What's wrong?")
        } footer: {
            Text(Moderation.whatHappens(target))
        }
        Section {
            TextField("Add a note (optional)", text: $note)
                .onChange(of: note) { _, n in if n.count > Moderation.noteLimit { note = String(n.prefix(Moderation.noteLimit)) } }
                .submitLabel(.done)
        } footer: {
            Text("A line in your own words, for the Admins. Don't paste the message here.")
        }
        Section {
            Button(sending ? "Sending…" : "Send report") { Task { await send() } }
                .disabled(reason == nil || sending)
        } footer: {
            if let problem { Text(problem).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private func sent(_ filed: Moderation.Filed) -> some View {
        Section {
            Label(filed.already ? "You've reported this already." : "Reported. Thanks for telling us.", systemImage: "checkmark.circle")
                .foregroundStyle(.primary)
        } footer: {
            Text(filed.already ? "Your first report is the one an Admin will look at." : Moderation.whatHappens(target))
        }
        if blockedHere {
            Section {
                Label("You blocked \(target.person.name).", systemImage: "hand.raised")
            } footer: {
                Text("You can unblock them in Profile › Blocked.")
            }
        } else if !alreadyBlocked {
            Section {
                Button("Block \(target.person.name)", role: .destructive) { blocking = target.person }
            } header: {
                Text("Block them too?")
            } footer: {
                Text(Moderation.blockWords)
            }
        }
        if let problem {
            Section { Text(problem).foregroundStyle(.red) }
        }
    }

    private func send() async {
        guard let reason, !sending else { return }
        sending = true
        problem = nil
        defer { sending = false }
        do {
            filed = try await Moderation.report(target, reason: reason, note: note, account: account, transport: transport)
        } catch {
            Reporter.shared.report(.warn, "report failed", Reporter.fields(error, ["user_id": String(target.person.id)]))
            session.noticed(error)
            problem = error.localizedDescription
        }
    }

    private func block(_ who: Reportable) async {
        do {
            try await Moderation.block(who.id, account: account, transport: transport)
            blockedHere = true
            blocked(who)
        } catch {
            Reporter.shared.report(.warn, "block failed", Reporter.fields(error, ["user_id": String(who.id)]))
            session.noticed(error)
            problem = error.localizedDescription
        }
    }
}

/// Who you block, and Unblock (Profile › Blocked).
@MainActor @Observable final class BlockedModel {
    private(set) var people: [BlockedPerson] = []
    private(set) var loaded = false
    private(set) var problem: String?
    private let account: Account
    private let transport: any Transport
    /// Each load's turn: only the newest answer is used.
    @ObservationIgnored private var turn = 0

    init(account: Account, transport: any Transport = NetworkTransport()) {
        self.account = account
        self.transport = transport
    }

    func load() async {
        turn += 1
        let mine = turn
        do {
            let people = try await Moderation.blocked(account: account, transport: transport)
            guard mine == turn else { return }  // a newer load is on its way
            self.people = people
            problem = nil
        } catch {
            guard mine == turn else { return }
            problem = error.localizedDescription
            Reporter.shared.report(.warn, "loading blocked failed", Reporter.fields(error))
        }
        loaded = true
    }

    func unblock(_ person: BlockedPerson) async throws {
        try await Moderation.unblock(person.id, account: account, transport: transport)
        people.removeAll { $0.id == person.id }
        await load()
    }
}

struct BlockedScreen: View {
    @Environment(Session.self) private var session
    @State var model: BlockedModel
    @State private var unblocking: BlockedPerson?
    @State private var note: String?

    var body: some View {
        List {
            if let note { Text(note) }  // what was just done, or why it couldn't be
            if !model.loaded {
                Label("Loading…", systemImage: "ellipsis").foregroundStyle(.secondary)
            } else if model.people.isEmpty {
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.red)
                } else {
                    ContentUnavailableView("No one blocked", systemImage: "hand.raised",
                                           description: Text("If you block someone, they show up here."))
                }
            } else {
                Section {
                    ForEach(model.people) { person in
                        // Stacked when the words are large or the screen is narrow.
                        ViewThatFits(in: .horizontal) {
                            HStack { who(person); Spacer(minLength: 8); unblockButton(person) }
                            VStack(alignment: .leading, spacing: 8) { who(person); unblockButton(person) }
                        }
                    }
                } footer: {
                    Text("They can't send you anything or add you to groups, and they aren't told.")
                }
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog(unblocking.map { "Unblock @\($0.username)?" } ?? "",
                            isPresented: Binding(get: { unblocking != nil }, set: { if !$0 { unblocking = nil } }),
                            titleVisibility: .visible, presenting: unblocking) { person in
            Button("Unblock") { Task { await unblock(person) } }
        } message: { _ in
            Text(Moderation.unblockWords)
        }
    }

    private func who(_ person: BlockedPerson) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("@\(person.username)")
            Text("Blocked \(Date(timeIntervalSince1970: TimeInterval(person.blockedAt)).formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func unblockButton(_ person: BlockedPerson) -> some View {
        Button("Unblock") { unblocking = person }.buttonStyle(.bordered).tint(.primary)
    }

    private func unblock(_ person: BlockedPerson) async {
        do {
            try await model.unblock(person)
            note = "Unblocked @\(person.username)."
        } catch {
            Reporter.shared.report(.warn, "unblock failed", Reporter.fields(error, ["user_id": String(person.id)]))
            session.noticed(error)
            note = error.localizedDescription
        }
    }
}
