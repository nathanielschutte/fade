import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Searching messages (Search.swift): over what's already on the phone (each
/// chat's kept page, still encrypted, and what's open this session), opened
/// off the main thread, bounded, nothing fetched and nothing written. The
/// people and keys are the vectors' (ChatListTests): I'm Bob (3).
@MainActor @Suite struct SearchTests {
    let t = try! ChatListTests()
    let root = FileManager.default.temporaryDirectory.appending(path: "napsack-search-test-\(UUID().uuidString)")

    /// `chats` friends (ids 100 up, the first the newest chat), each with a
    /// kept page of `per` texts sealed for real, as the server sends them.
    func keptChats(_ chats: Int, per: Int, words: (Int, Int) -> String) throws -> (reader: Reader, cache: ResponseCache, sources: [SearchSource]) {
        let cache = ResponseCache(account: 3, root: root)
        var reader = t.reader
        var sources: [SearchSource] = []
        for c in 0..<chats {
            let id = Int64(100 + c)
            let friend = try ChatListTests.decode(Friend.self, ChatListTests.friendJSON(
                alice: t.alice, last: nil, extra: ["id": id, "username": "friend\(c)", "display_name": "Friend \(c)"]))
            reader.friends[id] = friend
            let key = try E2E.pairKey(mine: t.reader.identity, theirs: t.alice["spki"] as! String, myId: 3, theirId: id)
            var page: [[String: Any]] = []
            for n in 0..<per {
                let (sender, recipient): (Int64, Int64) = n % 3 == 0 ? (3, id) : (id, 3)
                let sealed = try E2E.encryptText2(key, words(c, n), replyTo: nil, sender: sender, recipient: recipient)
                var m = t.message(from: sender, to: recipient, ciphertext: sealed, format: 2, read: true, id: Int64((chats - c) * 1000 + n))
                m["created_at"] = 1_793_300_000 + (chats - c) * 1000 + n  // the first chat's are the newest
                page.append(m)
            }
            cache.write(json(page), SearchSource.cacheKey(.friend(id)))
            sources.append(SearchSource(kind: .friend(id), name: friend.name, chat: .friend(friend)))
        }
        ResponseCache.settle()
        return (reader, cache, sources)
    }

    func finder() -> MessageFinder {
        let finder = MessageFinder()
        finder.pause = .zero
        return finder
    }

    @Test func findsWordsInWhatsKeptNewestFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (reader, cache, friends) = try keptChats(3, per: 6) { c, n in
            n == 4 ? "Lunch at noon? (chat \(c))" : n == 1 ? "line one\nlunch line two" : "nothing here \(n)"
        }
        // A group's kept page too: an old plain text and a sealed one (the vectors').
        let vt = t.vg["text"] as! [String: Any]
        let sealed = t.groupMessage(format: 3, sender: 7, extra: [
            "id": 60, "client_id": vt["client_id"]!, "recipients": vt["recipients"]!, "content": vt["content"]!,
            "key": (vt["wraps"] as! [String: Any])["3"]!, "sender_public_key": t.alice["spki"]!])
        var plain = t.groupMessage(body: "lunch for the road trip")
        plain["id"] = 59
        cache.write(json([plain, sealed]), SearchSource.cacheKey(.group(12)))
        ResponseCache.settle()
        let group = SearchSource(kind: .group(12), name: "Road trip", chat: .group(try t.group(nil)))

        let finder = finder()
        finder.prepare(friends + [group], reader: reader, cache: cache)
        finder.find("LUNCH")
        await finder.settled()
        // Each chat's two, any case, newest first (the first chat's are the newest), then the group's.
        #expect(finder.hits.map(\.name) == ["Friend 0", "Friend 0", "Friend 1", "Friend 1", "Friend 2", "Friend 2", "Road trip"])
        #expect(finder.hits.first.map { String($0.snippet.characters) } == "Lunch at noon? (chat 0)")
        #expect(finder.hits.first.map { bold($0.snippet) } == ["Lunch"])
        #expect(finder.hits[1].message == 3001 && String(finder.hits[1].snippet.characters) == "line one lunch line two")  // one line
        #expect(!finder.looking && finder.answered == "LUNCH")

        // The sealed group text, opened with my own wrap; accents and case don't matter.
        finder.find("ROAD TRÍP")
        await finder.settled()
        #expect(finder.hits.map(\.message) == [60, 59] && finder.hits.first?.kind == .group(12))

        // One letter searches names only (ChatList.search); nothing for messages.
        finder.find("l")
        await finder.settled()
        #expect(finder.hits.isEmpty)
        finder.find("no such words")
        await finder.settled()
        #expect(finder.hits.isEmpty && !finder.looking)
    }

    @Test func aLineAroundTheWords() {
        let text = String(repeating: "a", count: 50) + " the needle " + String(repeating: "b", count: 100)
        let range = text.range(of: "needle")!
        let snippet = SearchIndex.snippet(text, range)
        let words = String(snippet.characters)
        #expect(words == "…" + String(repeating: "a", count: 25) + " the needle " + String(repeating: "b", count: 69) + "…")  // 30 before, 70 after
        #expect(bold(snippet) == ["needle"])
        let short = "a needle"
        #expect(String(SearchIndex.snippet(short, short.range(of: "needle")!).characters) == "a needle")
    }

    /// What this session has open (an open chat's pages) is searched too, each
    /// message once; a kept page that hasn't changed isn't opened again.
    @Test func openPagesAndOnlyWhatChangedIsOpenedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (reader, cache, kept) = try keptChats(2, per: 5) { _, n in "kept \(n)" }
        var sources = kept
        sources[1].opened = [SearchIndex.Entry(id: 7, time: 1_793_000_000, text: "scrolled back to this one"),
                             SearchIndex.Entry(id: 1004, time: 1_793_301_004, text: "kept 4")]  // also on the kept page
        let finder = finder()
        finder.prepare(sources, reader: reader, cache: cache)
        finder.find("scrolled back")
        await finder.settled()
        #expect(finder.hits.map(\.message) == [7])
        finder.find("kept 4")
        await finder.settled()
        #expect(finder.hits.map(\.message) == [2004, 1004])  // once each
        let opened = await finder.index.opens
        #expect(opened == 10)

        // Search opened again: nothing changed, nothing opened again.
        finder.prepare(sources, reader: reader, cache: cache)
        await finder.settled()
        #expect(await finder.index.opens == opened)

        // A chat opened since (its kept page rewritten): only it is opened again.
        let key = try E2E.pairKey(mine: t.reader.identity, theirs: t.alice["spki"] as! String, myId: 3, theirId: 100)
        let new = t.message(from: 100, to: 3, ciphertext: try E2E.encryptText2(key, "a new one", replyTo: nil, sender: 100, recipient: 3),
                            format: 2, read: true, id: 2005)
        cache.write(json([new]), SearchSource.cacheKey(.friend(100)))
        ResponseCache.settle()
        finder.prepare(sources, reader: reader, cache: cache)
        finder.find("a new one")
        await finder.settled()
        #expect(finder.hits.map(\.message) == [2005])
        #expect(await finder.index.opens == opened + 1)
    }

    /// At most 200 of a chat, 5,000 in all (the newest chats'), and nothing
    /// written. (Nothing can be fetched: searching is given no way to ask the server.)
    @Test func boundedAndNothingWritten() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (reader, cache, kept) = try keptChats(1, per: 3) { _, n in "secret plan \(n)" }
        let before = try files()
        var sources = kept
        for c in 0..<30 {
            let id = Int64(500 + c)
            let friend = try ChatListTests.decode(Friend.self, ChatListTests.friendJSON(alice: t.alice, last: nil, extra: ["id": id, "username": "p\(c)"]))
            sources.append(SearchSource(kind: .friend(id), name: "p\(c)", chat: .friend(friend), opened: (0..<300).map {
                SearchIndex.Entry(id: Int64(c * 1000 + $0), time: Int64(1_700_000_000 - c * 1000 + $0), text: "word \($0)")
            }))
        }
        let finder = finder()
        finder.prepare(sources, reader: reader, cache: cache)
        finder.find("secret plan")
        await finder.settled()
        #expect(finder.hits.count == 3)
        #expect(await finder.index.count == SearchIndex.total)  // 3, then 200 for each of 24 chats, and 197 of the 25th
        finder.find("word 299")
        await finder.settled()
        #expect(finder.hits.count == 25)  // each chat's newest (299 among them), and only the chats within the total
        finder.find("word 99")
        await finder.settled()
        #expect(finder.hits.isEmpty)  // older than each chat's newest 200

        // What's on the phone is as it was: the kept pages as sent, nothing opened written anywhere.
        #expect(try files() == before)
        for (_, data) in try files() { #expect(!String(decoding: data, as: UTF8.self).contains("secret plan")) }

        // Signed out: what was opened goes.
        finder.forget()
        await finder.index.forget()
        #expect(await finder.index.count == 0 && finder.hits.isEmpty)
    }

    /// Nate: search mustn't make the app sluggish. 50 chats of 50 kept
    /// messages each, every one opened: none of it on the main thread, which
    /// stays free throughout (a tick every couple of milliseconds, each timing
    /// how late it ran). Other tests share the main thread, so this waits for
    /// it to be calm first, and takes the better of two runs, each from nothing.
    @Test func fiftyChatsOfFiftyKeepTheMainThreadFree() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (reader, cache, sources) = try keptChats(50, per: 50) { c, n in n == 49 ? "the needle in chat \(c)" : "message \(n) in chat \(c)" }
        var runs: [(took: Duration, held: Duration)] = []
        for _ in 0..<2 {
            await Ticker.calm()
            let finder = finder()
            let ticks = Ticker()
            ticks.start()
            let started = ContinuousClock.now
            finder.prepare(sources, reader: reader, cache: cache)
            finder.find("needle")
            await finder.settled()
            let took = ContinuousClock.now - started
            runs.append((took, await ticks.stop()))
            #expect(finder.hits.count == SearchIndex.most && finder.hits.first?.name == "Friend 0")
            #expect(await finder.index.count == 2500)
            #expect(await finder.index.opens == 2500)
            #expect(await !finder.index.workedOnMain)
        }
        let best = try #require(runs.min { $0.held < $1.held })
        // The work takes a while (on a phone, longer); the main thread is never held for more than a moment.
        // What proves it is `workedOnMain` above; this measures it. GitHub's three-core Mac runs every
        // suite at once and stalls the main thread on its own, so there the bound only catches the gross.
        let bound: Duration = ProcessInfo.processInfo.environment["CI"] == nil ? .milliseconds(100) : .milliseconds(500)
        #expect(best.held < bound, "the main thread was held \(best.held) at most while searching took \(best.took) (runs: \(runs))")
        Attachment.record(runs.map { "took \($0.took), the main thread held \($0.held) at most" }.joined(separator: "\n"), named: "search-timings.txt")
    }

    func files() throws -> [String: Data] {
        guard let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: Data] = [:]
        for case let url as URL in all where !url.hasDirectoryPath { out[url.lastPathComponent] = try Data(contentsOf: url) }
        return out
    }
}

/// The words in bold in a snippet.
func bold(_ s: AttributedString) -> [String] {
    s.runs.compactMap { run in run.inlinePresentationIntent == .stronglyEmphasized ? String(s[run.range].characters) : nil }
}

/// Ticks on the main thread every couple of milliseconds, noting the longest
/// it was kept waiting past when it should have run.
@MainActor final class Ticker {
    private var task: Task<Duration, Never>?

    func start() {
        task = Task { @MainActor in
            var longest: Duration = .zero
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                let now = ContinuousClock.now
                longest = max(longest, now - last - .milliseconds(2))
                last = now
            }
            return longest
        }
    }

    func stop() async -> Duration {
        task?.cancel()
        return await task?.value ?? .zero
    }

    /// Returns once the main thread has run every tick on time for `calm`
    /// (other tests, running alongside, use it too), or after `limit`.
    static func calm(_ calm: Duration = .milliseconds(150), limit: Duration = .seconds(5)) async {
        let start = ContinuousClock.now
        var calmSince = start, last = start
        while ContinuousClock.now - start < limit {
            try? await Task.sleep(for: .milliseconds(2))
            let now = ContinuousClock.now
            if now - last - .milliseconds(2) > .milliseconds(15) { calmSince = now }
            last = now
            if now - calmSince >= calm { return }
        }
    }
}
