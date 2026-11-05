import CryptoKit
import Foundation
import NapsackCrypto
import Testing
import UIKit
@testable import Napsack

/// A pic or video going to several chats (Send to…): made ready once, off the
/// main thread, then sealed for each chat on its own. Against a stand-in
/// server, with the vectors' people (SendingTests): I'm Bob (3); Alice (7) is
/// a friend, and in the group (12).
@MainActor @Suite struct CameraSendTests {
    let sending = SendingTests()
    var bobKey: String { sending.account.publicKey }
    var aliceKey: String { sending.list.alice["spki"] as! String }

    /// The server's copy of a direct pic, as it answers an upload.
    nonisolated static func storedSnap(_ request: URLRequest) -> Data {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        return json(["id": 300, "sender_id": 3, "recipient_id": 7, "kind": "snap", "ciphertext": NSNull(),
                     "format": Int(value("format") ?? "") ?? 0, "snap_state": "pending", "created_at": 1_793_300_000, "read_at": NSNull(),
                     "client_id": value("client_id").map { $0 as Any } ?? NSNull(), "edit_ciphertext": NSNull(), "edit_format": NSNull(), "edited_at": NSNull(),
                     "reactions": []])
    }

    /// The keys a group pic's upload carries (its X-Napsack-Keys header).
    nonisolated static func keys(_ request: URLRequest) -> [String: Any] {
        let header = request.value(forHTTPHeaderField: "X-Napsack-Keys") ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(header.utf8))) as? [String: Any] ?? [:]
    }

    /// The server's copy of a group pic, as Bob receives it (his own wrap).
    nonisolated static func storedGroupPic(_ request: URLRequest, senderKey: String) -> Data {
        let k = keys(request)
        let format = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "format" }?.value
        return json(["id": 61, "group_id": 12, "sender_id": 3, "sender_name": "bob", "kind": "text", "body": "", "format": Int(format ?? "") ?? 0,
                     "created_at": 1_793_300_000, "pic_id": 9, "reply_to": NSNull(), "pic": ["id": 9, "viewers": [], "discard_reason": NSNull()],
                     "reactions": [], "client_id": k["client_id"] ?? NSNull(), "recipients": k["recipients"] ?? NSNull(), "content": NSNull(),
                     "key": (k["wraps"] as? [String: Any])?["3"] ?? NSNull(), "sender_public_key": senderKey])
    }

    func server() -> StubServer {
        let bobKey = bobKey, aliceKey = aliceKey
        return StubServer { request in
            if request.httpMethod == "GET" {  // the group's members, to seal for
                return (200, json(["id": 12, "name": "Road trip", "members": [SendingTests.member(3, bobKey), SendingTests.member(7, aliceKey)]]))
            }
            return (200, request.url!.path.hasSuffix("/snaps") ? Self.storedSnap(request) : Self.storedGroupPic(request, senderKey: bobKey))
        }
    }

    /// What Alice gets from each upload: the direct one opened with her side of
    /// the pair key, the group's with her own wrap.
    func opened(_ uploads: [URLRequest], video: Bool) throws -> (direct: E2E.Media, group: E2E.Media) {
        let direct = try #require(uploads.first { $0.url!.path.hasSuffix("/snaps") })
        let group = try #require(uploads.first { $0.url!.path.hasSuffix("/pics") })
        let pairKey = try E2E.pairKey(mine: sending.aliceIdentity, theirs: bobKey, myId: 7, theirId: 3)
        let k = Self.keys(group)
        let opening = E2E.GroupOpening(groupId: 12, senderId: 3, myId: 7, clientId: try #require(k["client_id"] as? String),
                                       recipients: try #require(k["recipients"] as? [Int64]),
                                       wrapKey: try E2E.groupWrapKey(mine: sending.aliceIdentity, theirs: bobKey, myId: 7, theirId: 3))
        let wrap = try #require((k["wraps"] as? [String: String])?["7"])
        let sealedDirect = try #require(direct.httpBody), sealedGroup = try #require(group.httpBody)
        #expect(sealedDirect != sealedGroup)  // sealed apart, each for its chat
        return video
            ? (try E2E.decryptVideo(pairKey, sealedDirect, sender: 3, recipient: 7), try E2E.decryptGroupVideo(sealedGroup, wrap: wrap, opening))
            : (try E2E.decryptImage(pairKey, sealedDirect, sender: 3, recipient: 7), try E2E.decryptGroupImage(sealedGroup, wrap: wrap, opening))
    }

    /// A photo drawn on is flattened and compressed once (at most 1280 on its
    /// longest side, under the server's cap), and every chat gets those bytes.
    @Test func aPhotoIsMadeReadyOnceAndSealedForEachChat() async throws {
        let photo = TestPicture.plain(.white, size: CGSize(width: 3000, height: 4000))
        let across = Stroke(points: [CGPoint(x: 900, y: 2000), CGPoint(x: 2100, y: 2000)], width: 240)
        let ready = try await ReadyToSend.prepare(.photo(photo), strokes: [across], caption: "look", y: 0.3)
        guard case .photo(let jpeg) = ready.media else {
            Issue.record("not a photo")
            return
        }
        #expect(jpeg.count <= 500_000 && !ready.isVideo)
        let sent = try #require(UIImage(data: jpeg))
        #expect(sent.size == CGSize(width: 960, height: 1280))
        // What was drawn is in the photo itself: its middle is the pen's red.
        let cg = try #require(sent.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        #expect(pixel[0] > 200 && pixel[1] < 120, "red, not white: \(pixel)")

        let server = server()
        try await ready.send(to: sending.chat(.friend(sending.alice), server: server), limits: nil)
        try await ready.send(to: sending.chat(.group(try sending.list.group(nil)), server: server), limits: nil)
        let uploads = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(uploads.count == 2)
        let (direct, group) = try opened(uploads, video: false)
        #expect(direct.media == jpeg && direct.caption == "look" && direct.y == 0.3 && direct.type == "image/jpeg")
        #expect(group.media == jpeg && group.caption == "look" && group.y == 0.3)
    }

    /// A video is read from its file once: with the file gone, every chat
    /// still gets the same bytes.
    @Test func aVideoIsReadOnceForEveryChat() async throws {
        let clip = Data((0..<8192).map { UInt8(($0 * 13) % 256) })
        let file = FileManager.default.temporaryDirectory.appending(path: "napsack-test-\(UUID().uuidString).mp4")
        try clip.write(to: file)
        let ready = try await ReadyToSend.prepare(.video(file), strokes: [], caption: "listen", y: 0.75)
        try FileManager.default.removeItem(at: file)
        #expect(ready.isVideo)

        let server = server()
        try await ready.send(to: sending.chat(.friend(sending.alice), server: server), limits: nil)
        try await ready.send(to: sending.chat(.group(try sending.list.group(nil)), server: server), limits: nil)
        let (direct, group) = try opened(await server.requests.filter { $0.httpMethod == "POST" }, video: true)
        #expect(direct.media == clip && direct.caption == "listen" && direct.type == "video/mp4")
        #expect(group.media == clip && group.caption == "listen")
    }

    /// Over the server's cap, a chat says so rather than uploading.
    @Test func overTheCapIsSaid() async throws {
        let ready = ReadyToSend(media: .photo(Data(repeating: 7, count: 2000)), caption: "", y: 0.75)
        let server = server()
        let limits = try ServerConfig.decode(json(["server_version": "0.49.0", "build": "test", "api_version": 1, "invite_required": false,
                                                   "message_formats": [6], "min_client_versions": [String: String](),
                                                   "snap_max_bytes": 1000, "video_max_bytes": 1000, "video_max_seconds": 10]))
        await #expect(throws: SendError.self) { try await ready.send(to: sending.chat(.friend(sending.alice), server: server), limits: limits) }
        #expect(await server.requests.isEmpty)
    }

    /// Send again after a failure (from the camera, or Send to…) is the same
    /// pic: a friend's with the same id, a group's the same sealed copy, so a
    /// response that was lost never makes a second one. A chat that has it isn't
    /// sent it again, and another capture is another pic.
    @Test func sendingAgainIsTheSamePic() async throws {
        let failing = FirstFailures(3)  // one send's three tries, the connection down for each
        let bobKey = bobKey, aliceKey = aliceKey
        let server = StubServer { request in
            if request.httpMethod == "GET" {
                return (200, json(["id": 12, "name": "Road trip", "members": [SendingTests.member(3, bobKey), SendingTests.member(7, aliceKey)]]))
            }
            if failing.fails() { return (503, json(["error": "Try again in a moment."])) }
            return (200, request.url!.path.hasSuffix("/snaps") ? Self.storedSnap(request) : Self.storedGroupPic(request, senderKey: bobKey))
        }
        let ready = ReadyToSend(media: .photo(Data(repeating: 7, count: 2000)), caption: "hi", y: 0.75)
        let friend = sending.chat(.friend(sending.alice), server: server)
        let group = sending.chat(.group(try sending.list.group(nil)), server: server)
        let clientId = { (r: URLRequest) in
            URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value
        }

        await #expect(throws: ServerError.self) { try await ready.send(to: friend, limits: nil) }
        try await ready.send(to: friend, limits: nil)
        let direct = await server.requests.filter { $0.url!.path.hasSuffix("/snaps") }
        #expect(direct.count == 4 && Set(direct.map(clientId)).count == 1 && clientId(direct[0]) != nil)

        failing.reset(3)
        await #expect(throws: ServerError.self) { try await ready.send(to: group, limits: nil) }
        try await ready.send(to: group, limits: nil)
        let pics = await server.requests.filter { $0.url!.path.hasSuffix("/pics") }
        #expect(pics.count == 4)
        #expect(Set(pics.map { Self.keys($0)["client_id"] as? String }).count == 1 && Set(pics.map(\.httpBody)).count == 1)

        // Both have it: sent again, nothing goes.
        let before = await server.requests.count
        try await ready.send(to: friend, limits: nil)
        try await ready.send(to: group, limits: nil)
        #expect(await server.requests.count == before)

        // Another capture, another pic.
        let next = ReadyToSend(media: .photo(Data(repeating: 8, count: 2000)), caption: "", y: 0.75)
        try await next.send(to: friend, limits: nil)
        let last = try #require(await server.requests.last)
        #expect(clientId(last) != clientId(direct[0]))
    }

    /// The camera keeps what it made ready while nothing changes, so Send
    /// again (or Send to… after a failed Send) is the same pic; a new caption,
    /// drawing, place, or the sound turned off makes a new one.
    @Test func whatsMadeReadyIsKeptUntilItChanges() {
        let content = MadeReady.Content(strokes: [], caption: "hi", y: 0.75, muted: false)
        var made = 0
        let make = { () -> Task<ReadyToSend, any Error> in
            made += 1
            return Task { ReadyToSend(media: .photo(Data()), caption: "", y: 0.75) }
        }
        let first = MadeReady.reusing(nil, for: content, make: make)
        #expect(MadeReady.reusing(first, for: content, make: make).ready == first.ready && made == 1)
        let line = Stroke(points: [.zero, CGPoint(x: 1, y: 1)], width: 4)
        for changed in [MadeReady.Content(strokes: [], caption: "hello", y: 0.75, muted: false),
                        MadeReady.Content(strokes: [line], caption: "hi", y: 0.75, muted: false),
                        MadeReady.Content(strokes: [], caption: "hi", y: 0.3, muted: false),
                        MadeReady.Content(strokes: [], caption: "hi", y: 0.75, muted: true)] {
            #expect(MadeReady.reusing(first, for: changed, make: make).ready != first.ready)
        }
        #expect(made == 5)
    }

    /// From a chat's camera, "To Ben +" is there while the chat is one a pic
    /// can go to; Send to… then lists it picked, even when it's hidden.
    @Test func addingMoreFromAChat() {
        let row = { (kind: ChatRow.Kind, name: String, hidden: Bool) in
            ChatRow(kind: kind, name: name, preview: "", waiting: nil, time: nil, favorite: false, muted: false, hidden: hidden)
        }
        var chats = [row(.friend(7), "alice", true), row(.group(12), "Road trip", false), row(.friend(8), "cal", true)]
        let more = { (here: ChatRow.Kind) in
            CameraSend.AddMore(here: here, chats: { chats }, send: { _, _ in }, done: { _ in })
        }
        #expect(more(.friend(7)).offered && more(.group(12)).offered)
        #expect(!more(.friend(9)).offered, "not a chat a pic can go to (Team Napsack, a changed key, gone)")
        chats.removeFirst()
        #expect(!more(.friend(7)).offered, "gone since: Send alone")

        let all = [row(.friend(7), "alice", true), row(.group(12), "Road trip", false), row(.friend(8), "cal", true)]
        #expect(SendToScreen.shown(all, search: "").map(\.kind) == [.group(12)])
        #expect(SendToScreen.shown(all, search: "", keeping: [.friend(7)]).map(\.kind) == [.friend(7), .group(12)])
        #expect(SendToScreen.shown(all, search: "ca", keeping: [.friend(7)]).map(\.kind) == [.friend(8)])
    }

    /// Send to… goes to a few chats at once, never more; what failed is said
    /// for that chat, in the order they were picked.
    @Test(.timeLimit(.minutes(1))) func aFewChatsAtATimeEachSayingHowItWent() async throws {
        let gate = UploadGate()
        let all = Array(0..<7)
        let going = Task { @MainActor in
            await SendToScreen.each(all, atOnce: SendToScreen.atOnce) { i in
                await gate.enter()
                if i == 4 { throw SendError.tooLarge }
            }
        }
        var letGo = 0
        while letGo < all.count {
            // Each upload waits at the gate; let one go once all that may be going are there.
            if gate.waiting.count == min(SendToScreen.atOnce, all.count - letGo) {
                #expect(gate.inFlight <= SendToScreen.atOnce)
                gate.waiting.removeFirst().resume()
                letGo += 1
            }
            await Task.yield()
        }
        let why = await going.value
        #expect(gate.most == SendToScreen.atOnce && gate.started == all.count)
        #expect(why == [nil, nil, nil, nil, "That's too large to send.", nil, nil])
    }
}

/// Holds each send until the test lets it go, counting how many are going at once.
@MainActor final class UploadGate {
    var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var inFlight = 0
    private(set) var most = 0

    func enter() async {
        started += 1
        inFlight += 1
        most = max(most, inFlight)
        await withCheckedContinuation { waiting.append($0) }
        inFlight -= 1
    }
}

/// The first `n` uploads fail (then `reset` for more), for a stand-in server's answers.
final class FirstFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int

    init(_ n: Int) { left = n }

    func reset(_ n: Int) { lock.withLock { left = n } }

    func fails() -> Bool {
        lock.withLock {
            guard left > 0 else { return false }
            left -= 1
            return true
        }
    }
}
