import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// Nothing sent waits on the network (X57): texts, pics, edits, and reactions
/// show at once and go when they can; what can't go by its deadline says so,
/// stays, and goes again as the same message. Against stand-in servers, with
/// the vectors' people (SendingTests): I'm Bob (3), Alice (7) a friend.
@MainActor @Suite struct SendingAtOnceTests {
    let sending = SendingTests()
    var alice: Friend { sending.alice }

    func chat(_ transport: any Transport) -> Conversation {
        let chat = Conversation(.friend(alice), account: sending.account, reader: sending.reader, transport: transport)
        chat.retryDelays = [.zero, .zero]
        chat.uploads = PicUploads()
        return chat
    }

    // ---------- texts ----------

    /// A text the server doesn't answer in time is "Not sent" at its deadline,
    /// its words kept; Try again sends it as the same message.
    @Test(.timeLimit(.minutes(1))) func aTextPastItsDeadlineIsNotSentAndKept() async throws {
        let server = Hanging(first: 1) { request in (200, SendingTests.stored(request)) }
        let chat = chat(server)
        chat.textDeadline = .milliseconds(200)
        let started = Date()
        await chat.send("still there?", replyTo: nil)
        #expect(Date().timeIntervalSince(started) < 5, "given up at the deadline, not the request's own timeout")
        #expect(chat.outbox.map(\.status) == [.failed("Not sent: the connection is too slow.")])
        #expect(chat.outbox.first?.text == "still there?" && chat.bubbles.isEmpty)
        #expect(chat.hasUnsent && !chat.nothingWaiting)

        await chat.retry(try #require(chat.outbox.first).id)
        let posts = await server.requests
        #expect(posts.count == 2 && Set(posts.map { body($0)["client_id"] as! String }).count == 1, "the same message again")
        #expect(chat.outbox.isEmpty && chat.bubbles.map(\.content) == [.text("still there?", edited: false)])
    }

    /// A text that timed out goes again by itself once the connection's back.
    @Test(.timeLimit(.minutes(1))) func aTimedOutTextGoesAgainOnReconnect() async throws {
        let server = Hanging(first: 1) { request in (200, SendingTests.stored(request)) }
        let chat = chat(server)
        chat.textDeadline = .milliseconds(200)
        await chat.send("back?", replyTo: nil)
        #expect(chat.hasUnsent)
        await chat.flush()
        #expect(chat.outbox.isEmpty && chat.bubbles.count == 1)
    }

    /// Texts and pics show under the chat in the order they were sent.
    @Test func whatsOnItsWayShowsInTheOrderSent() async throws {
        let chat = chat(Hanging(first: 100) { _ in (500, Data()) })
        _ = chat.queue("one", replyTo: nil)
        chat.queuePic(Task { ReadyToSend(media: .photo(Data(repeating: 1, count: 100)), caption: "", y: 0.75) }, isVideo: false, limits: nil)
        _ = chat.queue("two", replyTo: nil)
        let order = chat.waiting.map { waiting -> String in
            switch waiting {
            case .text(let item): item.text
            case .pic(let item): item.isVideo ? "video" : "pic"
            }
        }
        #expect(order == ["one", "pic", "two"])
    }

    // ---------- pics and videos ----------

    /// A pic shows in the chat at once, while it uploads, and its server copy
    /// takes its place once it's there.
    @Test(.timeLimit(.minutes(1))) func aPicShowsAtOnceAndGoesOnItsOwn() async throws {
        let server = StubServer { request in (200, CameraSendTests.storedSnap(request)) }
        let chat = chat(server)
        chat.queuePic(Task { ReadyToSend(media: .photo(Data(repeating: 7, count: 2000)), caption: "hi", y: 0.75) }, isVideo: false, limits: nil)
        #expect(chat.pics.map(\.status) == [.sending] && chat.pics.first?.isVideo == false, "shown at once, before anything's gone")
        #expect(await server.requests.isEmpty)
        try await until { chat.pics.isEmpty }
        #expect(chat.bubbles.map(\.content) == [.media("Sent a pic")])
    }

    /// One that can't go waits as not sent; Try again is the same pic (the
    /// same client_id), never a second one.
    @Test(.timeLimit(.minutes(1))) func aPicThatCantGoWaitsAndGoesAgainAsItself() async throws {
        let online = Counter()
        let server = StubServer { request in
            if online.value == 0 { throw URLError(.notConnectedToInternet) }
            return (200, CameraSendTests.storedSnap(request))
        }
        let chat = chat(server)
        let id = chat.queuePic(Task { ReadyToSend(media: .video(Data(repeating: 7, count: 2000)), caption: "", y: 0.75) }, isVideo: true, limits: nil)
        try await until { chat.pics.first?.status != .sending }
        #expect(chat.pics.map(\.status) == [.failed("Not sent: no connection.")] && chat.hasUnsent)

        online.add()
        await chat.retryPic(id)
        #expect(chat.pics.isEmpty && chat.bubbles.map(\.content) == [.media("Sent a video")])
        let uploads = await server.requests
        let clientIds = Set(uploads.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value })
        #expect(uploads.count == 4 && clientIds.count == 1, "three tries, then Try again: one pic")
    }

    /// A pic whose upload stops moving is not sent; if its own copy then
    /// comes back (the server had it after all), it's sent.
    @Test(.timeLimit(.minutes(1))) func aPicThatStopsMovingThenFoundIsSent() async throws {
        let server = Hanging(first: 100) { _ in (200, Data()) }
        let chat = chat(server)
        try await chat.loadNewest()
        chat.picStall = .milliseconds(200)
        chat.queuePic(Task { ReadyToSend(media: .photo(Data(repeating: 7, count: 2000)), caption: "", y: 0.75) }, isVideo: false, limits: nil)
        try await until { chat.pics.first?.status != .sending }
        #expect(chat.pics.map(\.status) == [.failed("Not sent: the connection is too slow.")])

        let upload = try #require(await server.requests.last { $0.httpMethod == "POST" })
        let copy = try ChatListTests.decode(DirectMessage.self, try JSONSerialization.jsonObject(with: CameraSendTests.storedSnap(upload)) as! [String: Any])
        chat.arrived(copy)
        #expect(chat.pics.isEmpty && chat.bubbles.count == 1)
    }

    /// Uploads go a few at a time across every chat, the rest waiting their
    /// turn in the order they came.
    @Test func uploadsTakeTurns() async {
        let uploads = PicUploads()
        var order: [Int] = []
        for _ in 0..<PicUploads.atOnce { await uploads.turn() }
        #expect(uploads.going == PicUploads.atOnce)
        let later = (0..<2).map { i in Task { @MainActor in await uploads.turn(); order.append(i) } }
        for _ in 0..<20 { await Task.yield() }
        #expect(order.isEmpty, "waiting for a place")
        uploads.done()
        await later[0].value
        uploads.done()
        await later[1].value
        #expect(order == [0, 1] && uploads.going == PicUploads.atOnce)
        for _ in 0..<PicUploads.atOnce { uploads.done() }
        #expect(uploads.going == 0)
    }

    /// Send to… says where it's going.
    @Test func sendToSaysWhereItsGoing() {
        #expect(SendToScreen.words(["Ana"], video: false) == "Sending your pic to Ana.")
        #expect(SendToScreen.words(["Ana", "Ben", "Road trip"], video: true) == "Sending your video to Ana and 2 more.")
    }

    // ---------- edits and reactions ----------

    func myText() throws -> (sealed: String, bubble: Bubble) {
        let sealed = try E2E.encryptText2(sending.list.pairKey, "at 8", replyTo: nil, sender: 3, recipient: 7)
        let bubble = sending.reader.bubble(try ChatListTests.decode(DirectMessage.self, ReactionsAndEditsTests.myText(sealed)), with: alice)
        return (sealed, bubble)
    }

    /// An edit shows in place at once; one that can't be saved stays shown,
    /// with Try again, which saves it as the same edit.
    @Test(.timeLimit(.minutes(1))) func anEditShowsAtOnceAndIsNeverLost() async throws {
        let (sealed, text) = try myText()
        let online = Counter()
        let server = StubServer { request in
            if online.value == 0 { throw URLError(.notConnectedToInternet) }
            return (200, json(ReactionsAndEditsTests.myText(sealed, edit: body(request)["ciphertext"]!)))
        }
        let chat = chat(server)
        let going = chat.edit(text, to: "at 8:30")
        #expect(chat.shown(text).content == .text("at 8:30", edited: true) && chat.shown(text).pendingEdit == .sending, "shown at once")
        await going.value
        #expect(chat.shown(text).content == .text("at 8:30", edited: true))
        #expect(chat.shown(text).pendingEdit == .failed("Not saved: no connection.") && chat.hasUnsent)

        online.add()
        await chat.retryEdit(text.id)?.value
        #expect(chat.edits.isEmpty && chat.bubble(100)?.content == .text("at 8:30", edited: true))
        let edits = await server.requests
        #expect(Set(edits.map { body($0)["client_id"] as! String }).count == 1 && Set(edits.map { body($0)["ciphertext"] as! String }).count == 1)
    }

    /// Undo gives an edit up: the text shows as it was, and the words come back.
    @Test(.timeLimit(.minutes(1))) func anUnsavedEditCanBeUndone() async throws {
        let (_, text) = try myText()
        let chat = chat(StubServer { _ in throw URLError(.notConnectedToInternet) })
        await chat.edit(text, to: "at 9").value
        #expect(chat.dropEdit(text.id) == "at 9")
        #expect(chat.shown(text).content == .text("at 8", edited: false) && chat.shown(text).pendingEdit == nil && !chat.hasUnsent)
    }

    /// A reaction shows at once; one that can't go is taken off again, and says so.
    @Test(.timeLimit(.minutes(1))) func aReactionShowsAtOnceAndComesOffIfItCantGo() async throws {
        let (_, text) = try myText()
        let chat = chat(Hanging(first: 100) { _ in (500, Data()) })
        chat.textDeadline = .milliseconds(300)
        let going = Task { try await chat.react(text, "😂") }
        try await until { chat.reacting[100] != nil }
        #expect(chat.shown(text).myReaction == "😂" && chat.shown(text).reactions == [.init(user: 3, emoji: "😂")], "shown at once")
        await #expect(throws: ReactionError.notSent) { try await going.value }
        #expect(chat.shown(text).myReaction == nil && chat.shown(text).reactions.isEmpty, "taken off again")
    }

    /// Waits for something that happens off the test's own path (each check polls, never sleeps blind).
    func until(_ done: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { Issue.record("never happened"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A stand-in server that never answers the first `first` requests (until
/// they're cancelled, as a deadline does), then answers as `answer` says.
actor Hanging: Transport {
    private let first: Int
    private let answer: StubServer.Answer
    private(set) var requests: [URLRequest] = []

    init(first: Int, _ answer: @escaping StubServer.Answer) {
        self.first = first
        self.answer = answer
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if requests.count <= first {
            if request.httpMethod == "GET" { return (json([]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            try await Task.sleep(for: .seconds(600))
        }
        let (status, body) = try answer(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
