import Foundation
import SwiftUI

// Searching messages (Nate, 2026-11-02: "we need to be mindful of the app's
// speed, it can't get sluggish"). Messages are end-to-end encrypted, so search
// happens on the phone, over what's already here: the newest page of each
// chat, kept on the phone still encrypted (ResponseCache), and the pages of
// chats opened this session. Nothing is fetched for a search. What's opened
// for it stays in memory only, never written, and goes with the session.
// Bounded: a page per chat (200 at most of what's been scrolled through), and
// 5,000 messages in all, the newest chats first. Opened off the main thread,
// a few chats at a time, results appearing as each few are done; typing waits
// a moment before searching, and only matches what's already open.

/// A chat to search: who it is, how to open its messages, and what's open of it already.
struct SearchSource: Sendable {
    let kind: ChatRow.Kind
    let name: String
    var avatarId: Int64? = nil
    let chat: Conversation.Chat
    /// Texts already opened this session (a chat's loaded pages), newest last.
    var opened: [SearchIndex.Entry] = []

    /// Where its newest page is kept (Conversation keeps it under the same name).
    static func cacheKey(_ kind: ChatRow.Kind) -> String {
        switch kind {
        case .friend(let id): "chat-d-\(id)"
        case .group(let id): "chat-g-\(id)"
        }
    }

    /// An open chat's texts, as shown (each edit's newest words).
    @MainActor static func opened(_ conversation: Conversation) -> [SearchIndex.Entry] {
        conversation.bubbles.suffix(SearchIndex.perChat).compactMap { b in
            guard case .text(let text, _) = b.content else { return nil }
            return SearchIndex.Entry(id: b.id, time: Int64(b.time.timeIntervalSince1970), text: text)
        }
    }
}

/// A message search found: the chat, the message, and a line around the words (in bold).
struct MessageHit: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let kind: ChatRow.Kind
        let message: Int64
    }

    let kind: ChatRow.Kind
    let name: String
    var avatarId: Int64? = nil
    let message: Int64
    let time: Date
    let snippet: AttributedString

    var id: ID { ID(kind: kind, message: message) }
}

/// The opened texts of each chat, for search; off the main thread (an actor of its own).
actor SearchIndex {
    struct Entry: Equatable, Sendable {
        let id: Int64
        let time: Int64
        let text: String
    }

    /// At most this many of a chat's newest texts are searched.
    static let perChat = 200
    /// And this many in all, the newest chats first.
    static let total = 5_000
    /// Chats opened at a time, between results.
    static let batch = 6
    /// Results shown, newest first.
    static let most = 30

    private struct Chat {
        var name: String
        var avatarId: Int64?
        /// The kept page's version when it was opened, and what it said.
        var version: ResponseCache.Version?
        var kept: [Entry] = []
        var opened: [Entry] = []
        /// Both, newest first, within the bounds.
        var entries: [Entry] = []
    }

    private var chats: [ChatRow.Kind: Chat] = [:]
    /// The list's order, newest first: the order the total is counted in.
    private var order: [ChatRow.Kind] = []
    /// Texts taken so far in this pass (against `total`).
    private var taken = 0
    /// Messages opened from kept pages (tests: what's done again and what isn't).
    private(set) var opens = 0
    /// Whether any of the work (reading, opening, matching) ever ran on the main thread (tests: never).
    private(set) var workedOnMain = false

    private func noteThread() {
        if pthread_main_np() != 0 { workedOnMain = true }
    }

    /// A new pass over the chats in the list, newest first; chats no longer in it are forgotten.
    func begin(_ kinds: [ChatRow.Kind]) {
        order = kinds
        let now = Set(kinds)
        chats = chats.filter { now.contains($0.key) }
        taken = 0
    }

    /// Brings these chats up to date: a kept page that changed is opened again,
    /// and what's open this session is taken as it is. Returns whether anything changed.
    func load(_ sources: [SearchSource], reader: Reader, cache: ResponseCache?) -> Bool {
        noteThread()
        var changed = false
        for source in sources {
            let room = Self.total - taken
            guard room > 0 else {
                if chats.removeValue(forKey: source.kind) != nil { changed = true }
                continue
            }
            var chat = chats[source.kind] ?? Chat(name: source.name, avatarId: source.avatarId)
            let key = SearchSource.cacheKey(source.kind)
            let version = cache?.version(key)
            if version != chat.version || chats[source.kind] == nil {
                chat.kept = cache?.read(key).map { open($0, source.chat, reader) } ?? []
                chat.version = version
            }
            chat.name = source.name
            chat.avatarId = source.avatarId
            chat.opened = source.opened
            let entries = Self.merge(chat.kept, chat.opened, most: min(Self.perChat, room))
            let before = chats[source.kind]
            if before?.entries != entries || before?.name != chat.name || before?.avatarId != chat.avatarId { changed = true }
            chat.entries = entries
            chats[source.kind] = chat
            taken += entries.count
        }
        return changed
    }

    /// Both lists, each message once (the session's copy), newest first.
    private static func merge(_ kept: [Entry], _ opened: [Entry], most: Int) -> [Entry] {
        var byId: [Int64: Entry] = [:]
        for e in kept { byId[e.id] = e }
        for e in opened { byId[e.id] = e }
        return Array(byId.values.sorted { $0.id > $1.id }.prefix(most))
    }

    /// A kept page (the server's answer, still encrypted), its texts opened here.
    private func open(_ data: Data, _ chat: Conversation.Chat, _ reader: Reader) -> [Entry] {
        switch chat {
        case .friend(let friend):
            guard let messages = try? Server.decoder.decode([DirectMessage].self, from: data) else { return [] }
            return messages.compactMap { m in
                guard m.kind == "text" else { return nil }
                opens += 1
                return reader.body(m, with: friend).map { Entry(id: m.id, time: m.createdAt, text: $0.text.text) }
            }
        case .group:
            guard let messages = try? Server.decoder.decode([GroupMessage].self, from: data) else { return [] }
            return messages.compactMap { m in
                guard m.kind == "text", m.pic == nil else { return nil }
                opens += 1
                return reader.groupBody(m).map { Entry(id: m.id, time: m.createdAt, text: $0.text.text) }
            }
        }
    }

    /// Texts with the words (any case, any accents), newest first, the newest chats' first within the total.
    func match(_ words: String) -> [MessageHit] {
        noteThread()
        var found: [(kind: ChatRow.Kind, chat: Chat, entry: Entry, range: Range<String.Index>)] = []
        for kind in order {
            guard let chat = chats[kind] else { continue }
            for entry in chat.entries {
                if let range = entry.text.range(of: words, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) {
                    found.append((kind, chat, entry, range))
                }
            }
        }
        found.sort { $0.entry.time != $1.entry.time ? $0.entry.time > $1.entry.time : $0.entry.id > $1.entry.id }
        return found.prefix(Self.most).map {
            MessageHit(kind: $0.kind, name: $0.chat.name, avatarId: $0.chat.avatarId, message: $0.entry.id,
                       time: Date(timeIntervalSince1970: TimeInterval($0.entry.time)), snippet: Self.snippet($0.entry.text, $0.range))
        }
    }

    /// Up to 30 characters before the words and 70 after (as the web shows it), on one line, the words in bold.
    static func snippet(_ text: String, _ range: Range<String.Index>) -> AttributedString {
        let before = text[..<range.lowerBound].suffix(30), after = text[range.upperBound...].prefix(70)
        func line(_ s: Substring) -> String { s.replacingOccurrences(of: "\n", with: " ") }
        var snippet = AttributedString((before.startIndex > text.startIndex ? "…" : "") + line(before))
        var words = AttributedString(line(text[range]))
        words.inlinePresentationIntent = .stronglyEmphasized
        snippet += words
        snippet += AttributedString(line(after) + (after.endIndex < text.endIndex ? "…" : ""))
        return snippet
    }

    /// Everything opened, gone (signing out).
    func forget() {
        chats = [:]
        order = []
        taken = 0
    }

    /// How many texts are open for search now (tests).
    var count: Int { chats.values.reduce(0) { $0 + $1.entries.count } }
}

/// Search as you type, for the chat list: names and newest messages match at
/// once (ChatList.search); messages a moment after typing rests, from the index.
@MainActor @Observable final class MessageFinder {
    /// Messages with the words, newest first, for `answered`.
    private(set) var hits: [MessageHit] = []
    /// The words `hits` are for.
    private(set) var answered = ""
    /// Still opening what's kept: more may come.
    private(set) var opening = false

    @ObservationIgnored private var words = ""
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var matching: Task<Void, Never>?
    @ObservationIgnored let index = SearchIndex()
    /// How long typing rests before messages are searched (the web's 250 ms).
    @ObservationIgnored var pause: Duration = .milliseconds(250)

    /// Messages are searched from two letters, as on the web.
    static let shortest = 2

    /// Whether the words are long enough to search messages for.
    static func searchesMessages(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= shortest
    }

    /// Search opened (or reopened): what's kept is brought up to date in the
    /// background, a few chats at a time, results updating as each few are done.
    func prepare(_ sources: [SearchSource], reader: Reader, cache: ResponseCache?) {
        preparing?.cancel()
        opening = true
        let index = index
        preparing = Task {
            await index.begin(sources.map(\.kind))
            var start = 0
            while start < sources.count {
                let batch = Array(sources[start..<min(start + SearchIndex.batch, sources.count)])
                start += batch.count
                let changed = await index.load(batch, reader: reader, cache: cache)
                if Task.isCancelled { return }
                if changed { await match() }
            }
            opening = false
            await match()
        }
    }

    /// What's typed. Messages are searched a moment after the last key, over what's open.
    func find(_ text: String) {
        words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        matching?.cancel()
        guard words.count >= Self.shortest else {
            if !hits.isEmpty { hits = [] }
            answered = words
            return
        }
        let pause = pause
        matching = Task {
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            await match()
        }
    }

    /// Waits for the opening and searching under way (tests).
    func settled() async {
        await preparing?.value
        await matching?.value
    }

    private func match() async {
        let words = words
        guard words.count >= Self.shortest else { return }
        let found = await index.match(words)
        guard words == self.words else { return }  // typing moved on
        if found != hits { hits = found }
        answered = words
    }

    /// Whether more may still come for what's typed.
    var looking: Bool { opening || answered != words }

    /// Signed out: what was opened for search goes.
    func forget() {
        preparing?.cancel()
        matching?.cancel()
        hits = []
        let index = index
        Task { await index.forget() }
    }
}

/// While searching: the chats whose name or newest message match (at once),
/// then the messages that do, as they're found.
struct SearchResults<Rows: View>: View {
    let text: String
    let chats: [ChatRow]
    let finder: MessageFinder
    let rows: ([ChatRow]) -> Rows
    let open: (MessageHit) -> Void

    var body: some View {
        if chats.isEmpty && !MessageFinder.searchesMessages(text) {
            ContentUnavailableView.search(text: text)
        } else {
            Section("Chats") {
                if chats.isEmpty {
                    Text("No chats by that name.").foregroundStyle(.secondary)
                } else {
                    rows(chats)
                }
            }
            if MessageFinder.searchesMessages(text) {
                Section {
                    ForEach(finder.hits) { hit in
                        Button { open(hit) } label: { MessageHitRow(hit: hit) }
                            .buttonStyle(.plain)
                    }
                    if finder.looking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Looking through your messages…").foregroundStyle(.secondary)
                        }
                    } else if finder.hits.isEmpty {
                        Text("No recent messages with that.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Messages")
                } footer: {
                    Text("Searches each chat's newest messages on this phone.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A message found: the chat, when, and the line with the words in it.
struct MessageHitRow: View {
    let hit: MessageHit

    var body: some View {
        HStack(spacing: 12) {
            Avatar(kind: hit.kind, avatarId: hit.avatarId, name: hit.name, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ChatRowView.when(hit.time)).font(.caption).foregroundStyle(.secondary)
                }
                Text(hit.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the chat at this message")
    }
}

extension EnvironmentValues {
    /// The message a search result opened its chat at (ChatScreen brings it into view).
    @Entry var foundMessage: Int64? = nil
}

/// Brings the message a search found into view once it's among those loaded,
/// in the middle of the screen. If it's further back than what's loaded, the
/// chat opens at its newest, as on the web.
struct ShowFound: ViewModifier {
    @Environment(\.foundMessage) private var found
    let conversation: Conversation
    let proxy: ScrollViewProxy
    @State private var shown: Int64?

    func body(content: Content) -> some View {
        let ready = found.flatMap { id in conversation.bubble(id) != nil ? id : nil }
        content.task(id: ready) {
            guard let ready, ready != shown else { return }
            shown = ready
            // A lazy stack only guesses the heights of messages it hasn't drawn:
            // the first jump lands near, those around it get drawn, and the
            // second puts it in the middle.
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(60))
                proxy.scrollTo(ready, anchor: .center)
            }
        }
    }
}
