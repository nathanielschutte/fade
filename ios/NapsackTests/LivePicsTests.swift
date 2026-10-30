import CryptoKit
import Foundation
import NapsackCrypto
import Testing
import UIKit
@testable import Napsack

/// Opening pics and videos against a real napsack server (a local one; it
/// makes accounts): a photo, a video, and a group photo, each sealed here as
/// the web app seals them, opened once by the friend's app, then gone. Runs
/// only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil))
struct LivePicsTests {
    let live = LiveChatListTests()

    /// Uploads sealed bytes as the web app does: the body raw, the format and id in the query.
    func upload(_ path: String, _ data: Data, format: Int, token: String, keys: String? = nil) async throws {
        let server = try Server(live.address)
        var request = server.request(path, method: "POST", token: token,
                                     query: [URLQueryItem(name: "format", value: String(format)), URLQueryItem(name: "client_id", value: Conversation.newClientId())])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let keys { request.setValue(keys, forHTTPHeaderField: "X-Napsack-Keys") }
        request.httpBody = data
        let (body, response) = try await NetworkTransport().send(request)
        #expect(response.statusCode == 200, "\(String(decoding: body, as: UTF8.self))")
    }

    @Test func photosVideosAndGroupPicsOpenOnce() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        _ = try await FriendsModel(account: ana).add(ben.user.username)
        let bens = FriendsModel(account: ben)
        try await bens.loadRequests()
        try await bens.accept(try #require(bens.requests.incoming.first))
        let key = try E2E.pairKey(mine: ana.identity(), theirs: ben.publicKey, myId: ana.user.id, theirId: ben.user.id)
        let photo = try #require(LiveProfileTests.photo(.systemGreen, width: 400, height: 300).jpegData(compressionQuality: 0.8))
        try await upload("chats/\(ben.user.id)/snaps", try E2E.encryptImage(key, photo, caption: "look", sender: ana.user.id, recipient: ben.user.id, y: 0.3),
                         format: E2E.imageFormat, token: ana.token)
        let clip = Data((0..<2048).map { UInt8($0 % 251) })
        try await upload("chats/\(ben.user.id)/snaps", try E2E.encryptVideo(key, clip, type: "video/mp4", caption: "", sender: ana.user.id, recipient: ben.user.id),
                         format: E2E.videoFormat, token: ana.token)

        // Ben's chat: two waiting, each opened once, exactly as sent.
        let list = ChatList(pinStore: MemoryPinStore())
        try await list.load(ben)
        let chat = Conversation(.friend(try #require(list.reader?.friends[ana.user.id])), account: ben, reader: try #require(list.reader))
        try await chat.loadNewest()
        let waiting = chat.bubbles.compactMap(\.opening)
        #expect(waiting.count == 2 && waiting.map(\.isVideo) == [false, true])
        let opened = try await chat.open(waiting[0])
        #expect(opened.image == photo && opened.caption == "look" && opened.y == 0.3)
        let video = try await chat.open(waiting[1])
        let url = try #require(video.video)
        #expect(try Data(contentsOf: url) == clip)
        try? FileManager.default.removeItem(at: url)
        await chat.confirmOpened(waiting[0])
        await chat.confirmOpened(waiting[1])
        #expect(chat.bubbles.compactMap(\.opening).isEmpty)
        #expect(chat.bubbles.map(\.content).contains(.media("Pic viewed")))
        await #expect(throws: (any Error).self) { _ = try await chat.open(waiting[0]) }  // gone

        // A group photo (format 7): sealed for both, opened by Ben with his own wrap.
        let server = try Server(live.address)
        let created = try Server.decoder.decode(LiveChatListTests.Created.self, from: await server.send(
            "groups", method: "POST", token: ana.token, json: LiveChatListTests.NewGroup(name: "Pics", memberIds: [ben.user.id])))
        let wrapKeys = [
            ana.user.id: try E2E.groupWrapKey(mine: ana.identity(), theirs: ana.publicKey, myId: ana.user.id, theirId: ana.user.id),
            ben.user.id: try E2E.groupWrapKey(mine: ana.identity(), theirs: ben.publicKey, myId: ana.user.id, theirId: ben.user.id),
        ]
        let sealed = try E2E.encryptGroupImage(photo, caption: "all of us", groupId: created.id, senderId: ana.user.id, wrapKeys: wrapKeys)
        let keys = try JSONSerialization.data(withJSONObject: ["client_id": sealed.clientId, "recipients": sealed.recipients,
                                                               "wraps": Dictionary(uniqueKeysWithValues: sealed.wraps.map { (String($0.key), $0.value) })])
        try await upload("groups/\(created.id)/pics", sealed.content, format: E2E.groupImageFormat, token: ana.token,
                         keys: String(decoding: keys, as: UTF8.self))
        try await list.load(ben)
        let group = Conversation(.group(try #require(list.groups[created.id])), account: ben, reader: try #require(list.reader))
        try await group.loadNewest()
        let groupPic = try #require(group.bubbles.compactMap(\.opening).first)
        let shown = try await group.open(groupPic)
        #expect(shown.image == photo && shown.caption == "all of us")
        await group.confirmOpened(groupPic)
        #expect(group.bubbles.compactMap(\.opening).isEmpty)
    }

    @Test func theAppSendsAPhotoThatOpens() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        _ = try await FriendsModel(account: ana).add(ben.user.username)
        let bens = FriendsModel(account: ben)
        try await bens.loadRequests()
        try await bens.accept(try #require(bens.requests.incoming.first))
        let jpeg = try #require(Conversation.photoJPEG(LiveProfileTests.photo(.systemIndigo, width: 3000, height: 2000)))
        #expect(UIImage(data: jpeg).map { max($0.size.width, $0.size.height) } == 1280)

        // Ana's app sends it to Ben, and to a group with him.
        let anas = ChatList(pinStore: MemoryPinStore())
        try await anas.load(ana)
        let toBen = Conversation(.friend(try #require(anas.reader?.friends[ben.user.id])), account: ana, reader: try #require(anas.reader))
        try await toBen.loadNewest()
        try await toBen.sendPhoto(jpeg, caption: "  from my phone  ")
        #expect(toBen.bubbles.last?.content == .media("Sent a pic"))
        let id = try await GroupModel.create(name: "Photos", members: [ben.user.id], account: ana)
        try await anas.load(ana)
        let toGroup = Conversation(.group(try #require(anas.groups[id])), account: ana, reader: try #require(anas.reader))
        try await toGroup.loadNewest()
        try await toGroup.sendPhoto(jpeg, caption: "for the group")

        // Ben's app opens both, exactly as sent.
        let list = ChatList(pinStore: MemoryPinStore())
        try await list.load(ben)
        let fromAna = Conversation(.friend(try #require(list.reader?.friends[ana.user.id])), account: ben, reader: try #require(list.reader))
        try await fromAna.loadNewest()
        let direct = try await fromAna.open(try #require(fromAna.bubbles.compactMap(\.opening).first))
        #expect(direct.image == jpeg && direct.caption == "from my phone")
        let group = Conversation(.group(try #require(list.groups[id])), account: ben, reader: try #require(list.reader))
        try await group.loadNewest()
        let inGroup = try await group.open(try #require(group.bubbles.compactMap(\.opening).first))
        #expect(inGroup.image == jpeg && inGroup.caption == "for the group")
    }
}
