import Foundation
import Testing
@testable import Napsack

/// Texts not yet sent, kept through quitting napsack (Nate, 2026-11-12;
/// UnsentTexts): sealed on the phone, back in their chat on the next launch
/// and sent as the same messages, gone once sent, and gone at sign-out. In a
/// folder and a Keychain service of the test's own.
@MainActor @Suite struct UnsentTextsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "unsent-\(UUID().uuidString)", directoryHint: .isDirectory)
    let service = "napsack-test-unsent-\(UUID().uuidString)"
    let sending = SendingTests()

    /// The store as a launch makes it.
    func store() -> UnsentTexts {
        UnsentTexts(account: 3, cache: ResponseCache(account: 3, root: root), keychainService: service)
    }

    func texts(_ words: String...) -> [UnsentTexts.Text] {
        words.enumerated().map { UnsentTexts.Text(id: "id\($0.offset)", text: $0.element, replyTo: $0.offset == 1 ? 5 : nil) }
    }

    @Test func keptSealedThroughAQuitAndGoneOnceSent() throws {
        let first = store()
        #expect(first.load(), "nothing there yet: read, empty")
        first.keep(texts("on my way", "see you there"), for: "d7")
        ResponseCache.settle()

        let file = ResponseCache(account: 3, root: root).unsent.file(UnsentTexts.file)
        let sealed = try Data(contentsOf: file)
        #expect(sealed.range(of: Data("on my way".utf8)) == nil && sealed.range(of: Data("see you".utf8)) == nil, "the words aren't in the file")
        #expect(Keychain.accounts(service: service) == ["unsent-3"], "its key, in the Keychain")

        let again = store()  // napsack opened again
        #expect(again.load())
        #expect(again.chats["d7"] == texts("on my way", "see you there"))

        again.keep([], for: "d7")  // sent
        ResponseCache.settle()
        let third = store()
        #expect(third.load() && third.chats.isEmpty)
    }

    /// Signing out (and every other end) leaves nothing of them: the file and
    /// its key go with everything else, and a store from before keeps nothing after.
    @Test func signingOutLeavesNothing() {
        let before = store()
        before.load()
        before.keep(texts("are you up?"), for: "g2")
        ResponseCache.settle()
        let phone = PhoneData(keychainService: service, defaults: "napsack-test-\(UUID().uuidString)", cache: root,
                              temporary: root.appending(path: "tmp"), systemCaches: false)
        #expect(phone.kept().count == 2, "the sealed file and its key: \(phone.kept())")
        phone.forget()
        #expect(phone.kept().isEmpty)

        before.keep(texts("are you up?", "hello?"), for: "g2")  // the old session, still going a moment
        ResponseCache.settle()
        #expect(phone.kept().isEmpty, "nothing of that account is kept again")
    }

    /// A file whose key is gone can never be opened: it counts as nothing,
    /// and what's kept next replaces it, readable.
    @Test func aFileWithoutItsKeyIsNothing() throws {
        let first = store()
        first.load()
        first.keep(texts("lost"), for: "d7")
        ResponseCache.settle()
        try Keychain.delete(account: "unsent-3", service: service)

        let again = store()
        #expect(again.load() && again.chats.isEmpty)
        again.keep(texts("found"), for: "d7")
        ResponseCache.settle()
        let third = store()
        #expect(third.load() && third.chats["d7"]?.map(\.text) == ["found"])
    }

    /// The chat writes its outbox as it changes; the next launch's chat shows
    /// those texts and sends them, in order, each as the same message.
    @Test(.timeLimit(.minutes(1))) func textsComeBackAfterAQuitAndGoAsTheSameMessages() async throws {
        let unsent = store()
        unsent.load()
        let away = Conversation(.friend(sending.alice), account: sending.account, reader: sending.reader,
                                transport: Hanging(first: 100) { _ in (500, Data()) })
        away.retryDelays = [.zero, .zero]
        away.textDeadline = .milliseconds(100)
        away.unsent = unsent
        try await away.loadNewest()
        await away.send("first", replyTo: nil)
        _ = away.queue("second", replyTo: 9)
        #expect(unsent.chats[away.unsentKey]?.map(\.text) == ["first", "second"])
        let ids = away.outbox.map(\.id)
        ResponseCache.settle()

        // Quit, and opened again: a new store and chat, as the next launch makes them.
        let next = store()
        next.load()
        let ids200 = Counter()
        let server = StubServer { request in
            request.httpMethod == "POST" ? (200, SendingTests.stored(request, id: Int64(200 + ids200.add()))) : (200, json([]))
        }
        let back = Conversation(.friend(sending.alice), account: sending.account, reader: sending.reader, transport: server)
        back.unsent = next
        try await back.loadNewest()
        back.restore(next.chats[back.unsentKey] ?? [])
        #expect(back.outbox.map(\.text) == ["first", "second"], "shown at once")
        try await until { back.outbox.isEmpty }
        let posts = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.map { body($0)["client_id"] as? String } == ids, "the same messages, in order")
        #expect(back.bubbles.map(\.content) == [.text("first", edited: false), .text("second", edited: false)])
        ResponseCache.settle()
        let after = store()
        #expect(after.load() && after.chats.isEmpty, "sent: nothing kept")
    }

    func until(_ done: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { Issue.record("never happened"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
