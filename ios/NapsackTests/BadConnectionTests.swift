import Foundation
import Testing
@testable import Napsack

/// Bad connections (Nate, 2026-11-12). What retires the connection so the
/// next request goes out on a new one (D26); opening a pic tries again while
/// the connection is the problem; a pic counts as opened the moment it's shown,
/// in the chat and the list, and the server's told until it hears (D27); an
/// upload that keeps moving isn't cut off, however long it takes (X57). With
/// the vectors' people (SendingTests): I'm Bob (3), Alice (7) a friend.
@MainActor @Suite struct BadConnectionTests {
    let sending = SendingTests()
    var alice: Friend { sending.alice }

    // ---------- a new connection after a bad one (D26) ----------

    @Test func whatRetiresTheConnection() {
        let quick = Duration.milliseconds(100), slow = Duration.seconds(4)
        #expect(NetworkTransport.retires(URLError(.timedOut), took: quick))
        #expect(NetworkTransport.retires(URLError(.networkConnectionLost), took: quick))
        #expect(NetworkTransport.retires(URLError(.notConnectedToInternet), took: quick))
        #expect(NetworkTransport.retires(URLError(.cannotConnectToHost), took: quick))
        #expect(!NetworkTransport.retires(URLError(.cancelled), took: quick), "left at once: just not wanted any more")
        #expect(NetworkTransport.retires(URLError(.cancelled), took: slow), "given up after a while: likely stuck on its connection")
        #expect(NetworkTransport.retires(CancellationError(), took: slow))
        #expect(!NetworkTransport.retires(URLError(.badServerResponse), took: slow), "the server's answer, not the connection")
    }

    @Test func aNewConnectionAtMostEveryFewSeconds() {
        let connection = NetworkTransport.Connection()
        let first = connection.current
        #expect(connection.renew("test"))
        let second = connection.current
        #expect(second !== first)
        #expect(!connection.renew("test"), "one bad moment fails several requests: one new connection for them all")
        #expect(connection.current === second && connection.renewals == 1)
    }

    /// A request that can't reach the server retires the connection it went
    /// out on: the next goes out on a new one.
    @Test func aRequestThatCantConnectRetiresItsConnection() async throws {
        let connection = NetworkTransport.Connection()
        let before = connection.current
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/api/config")!)  // nothing listens there
        request.timeoutInterval = 10
        await #expect(throws: (any Error).self) { try await NetworkTransport(connection: connection).send(request) }
        #expect(connection.renewals == 1 && connection.current !== before)
    }

    // ---------- opening a pic ----------

    /// A pic waiting from Alice (format 6), as the server lists it.
    nonisolated static func pendingPic(id: Int64 = 300) -> [String: Any] {
        ["id": id, "sender_id": 7, "recipient_id": 3, "kind": "snap", "ciphertext": NSNull(), "format": 6,
         "snap_state": "pending", "created_at": 1_793_300_000, "read_at": NSNull(), "client_id": "pic\(id)",
         "edit_ciphertext": NSNull(), "edit_format": NSNull(), "edited_at": NSNull(), "reactions": []]
    }

    /// Fetching it tries again while the connection is the problem, each a new
    /// request; the server's "gone" then ends it (on to the next).
    @Test func openingTriesAgainWhileTheConnectionIsTheProblem() async throws {
        let tries = Counter()
        let server = StubServer { request in
            if request.url!.path.hasSuffix("/messages") { return (200, json([Self.pendingPic()])) }
            return tries.add() < 2 ? (503, json(["error": "busy"])) : (410, json(["error": "This pic was already opened or has expired."]))
        }
        let chat = sending.chat(.friend(alice), server: server)
        try await chat.loadNewest()
        let pic = try #require(chat.bubbles.first?.opening)
        await #expect(throws: ServerError.refused("This pic was already opened or has expired.", status: 410)) { try await chat.open(pic) }
        let fetches = await server.requests.filter { $0.url!.path == "/api/snaps/300" }
        #expect(fetches.count == 3)
    }

    // ---------- shown is opened, at once (D27) ----------

    /// Shown: the chat says it was viewed at once, the list's row (through
    /// the shared memo) stops offering it and counts it read, the server is
    /// told until it hears, and an answer from before it heard, which still
    /// says it's waiting, never offers it again.
    @Test func aPicShownIsOpenedAtOnceAndToldUntilTheServerHears() async throws {
        let posts = Counter()
        let server = StubServer { request in
            if request.url!.path.hasSuffix("/opened") { return posts.add() < 2 ? (503, json(["error": "busy"])) : (200, json(["ok": true])) }
            return (200, json([Self.pendingPic()]))  // the server's word, until it hears: still waiting
        }
        let reader = sending.reader
        let chat = Conversation(.friend(alice), account: sending.account, reader: reader, transport: server)
        chat.confirmDelays = [.zero, .zero, .zero, .zero]
        var told: [PicToOpen] = []
        chat.picOpened = { told.append($0) }
        try await chat.loadNewest()
        let pic = try #require(chat.bubbles.first?.opening)
        #expect(chat.bubbles.first?.content == .media("New pic"))

        let withPic = try sending.list.direct(Self.pendingPic(), extra: ["unread": 1])
        #expect(reader.row(withPic).opensPics && reader.row(withPic).waiting == .snap)

        chat.opened(pic)
        #expect(chat.bubbles.first?.content == .media("Pic viewed") && chat.bubbles.first?.opening == nil, "at once, in the chat")
        #expect(told == [pic], "the list hears")
        let row = reader.row(withPic)
        #expect(row.preview == "Pic viewed" && row.waiting == nil && !row.opensPics, "the list's row, before the server's heard")

        try await until { posts.value == 3 }
        try await chat.catchUp()
        #expect(try await PicViewer.waiting(in: chat).isEmpty, "never offered again, whatever an older answer says")
        #expect(chat.bubbles.first?.content == .media("Pic viewed"))
    }

    // ---------- uploads that keep moving (X57) ----------

    /// An upload slower than the stall window in all, but moving the whole
    /// time, is sent; one that stops moving isn't (SendingAtOnceTests).
    @Test(.timeLimit(.minutes(1))) func aSlowUploadThatKeepsMovingIsSent() async throws {
        // Wide margins: tests run side by side, and a busy moment mustn't look like a stall.
        let chat = Conversation(.friend(alice), account: sending.account, reader: sending.reader, transport: Trickling(steps: 10, every: .milliseconds(300)))
        chat.uploads = PicUploads()
        chat.picStall = .milliseconds(1500)
        try await chat.loadNewest()
        chat.queuePic(Task { ReadyToSend(media: .photo(Data(repeating: 7, count: 2000)), caption: "", y: 0.75) }, isVideo: false, limits: nil)
        try await until { chat.pics.isEmpty || chat.pics.first?.status != .sending }
        #expect(chat.pics.isEmpty && chat.bubbles.map(\.content) == [.media("Sent a pic")],
                "3 seconds in all, never 1.5 without moving: \(String(describing: chat.pics.first?.status))")
    }

    func until(_ done: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { Issue.record("never happened"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A stand-in server whose uploads take a while but keep moving, saying so as
/// they go (as NetworkTransport tells TransferWatch).
actor Trickling: Transport {
    let steps: Int
    let every: Duration

    init(steps: Int, every: Duration) {
        self.steps = steps
        self.every = every
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        guard request.httpMethod == "POST" else { return (json([]), ok) }
        let watcher = TransferWatch.watcher
        for step in 1...steps {
            try await Task.sleep(for: every)
            watcher?(Transfer(sent: Int64(step), toSend: Int64(steps)))
        }
        return (CameraSendTests.storedSnap(request), ok)
    }
}
