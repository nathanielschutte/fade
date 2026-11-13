import CryptoKit
import Foundation
import NapsackCrypto
import Testing
import UIKit
@testable import Napsack

/// The next pic in a run, fetched and opened while the one before shows
/// (X61): its page takes it ready, a photo already decoded, without asking
/// the server again; closing the viewer lets go of what was never shown, a
/// video's file deleted. With the vectors' people (SendingTests): Alice (7)
/// sends, I'm Bob (3).
@MainActor @Suite struct PicsAheadTests {
    let sending = SendingTests()

    /// A pic from Alice as the server lists it, and its sealed bytes as it serves them.
    func waiting(_ id: Int64, video: Bool) throws -> (listed: [String: Any], sealed: Data) {
        let key = try E2E.pairKey(mine: sending.aliceIdentity, theirs: sending.account.publicKey, myId: 7, theirId: 3)
        let sealed = video
            ? try E2E.encryptVideo(key, Data("not really a movie".utf8), type: "video/mp4", caption: "watch", sender: 7, recipient: 3)
            : try E2E.encryptImage(key, TestPicture.photo().jpegData(compressionQuality: 0.8)!, caption: "look", sender: 7, recipient: 3)
        var listed = BadConnectionTests.pendingPic(id: id)
        listed["format"] = video ? E2E.videoFormat : E2E.imageFormat
        return (listed, sealed)
    }

    @Test func theNextIsReadyWithoutAskingAgain() async throws {
        let pic = try waiting(300, video: false)
        let server = StubServer { request in
            request.url!.path == "/api/snaps/300" ? (200, pic.sealed) : (200, json([pic.listed]))
        }
        let chat = sending.chat(.friend(sending.alice), server: server)
        try await chat.loadNewest()
        let next = try #require(chat.bubbles.first?.opening)

        let ahead = PicsAhead()
        ahead.fetch(next, in: chat)
        ahead.fetch(next, in: chat)  // once is enough
        let handed = try #require(ahead.take(next))
        let ready = try await handed.ready.value
        #expect(ready.opened.caption == "look" && ready.photo != nil, "opened, and the photo decoded for showing")
        #expect(ahead.take(next) == nil, "its page took it")
        let fetches = await server.requests.filter { $0.url!.path == "/api/snaps/300" }
        #expect(fetches.count == 1)
        #expect(chat.bubbles.first?.opening != nil, "fetched isn't opened: only showing it is")
    }

    @Test func closingLetsGoOfWhatWasNeverShown() async throws {
        let pic = try waiting(301, video: true)
        let server = StubServer { request in
            request.url!.path == "/api/snaps/301" ? (200, pic.sealed) : (200, json([pic.listed]))
        }
        let chat = sending.chat(.friend(sending.alice), server: server)
        try await chat.loadNewest()
        let next = try #require(chat.bubbles.first?.opening)

        let ahead = PicsAhead()
        ahead.fetch(next, in: chat)
        try await until { await server.requests.contains { $0.url!.path == "/api/snaps/301" } }
        let deleted = await ahead.letGo().value
        #expect(deleted.count == 1 && !FileManager.default.fileExists(atPath: deleted[0].path(percentEncoded: false)), "its video file, gone")
        #expect(ahead.take(next) == nil)
    }

    func until(_ done: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await done()) {
            guard Date() < deadline else { Issue.record("never happened"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
