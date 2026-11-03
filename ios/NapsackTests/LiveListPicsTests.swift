import CryptoKit
import Foundation
import NapsackCrypto
import Testing
import UIKit
@testable import Napsack

/// Opening pics straight from the chat list (Nate, 2026-11-02), against a
/// real napsack server (a local one; it makes accounts): a friend's two pics
/// are shown back to back, the list hears they were opened and leaves the chat
/// read; a group's is read only when nothing else waited there. What the
/// screen does with a tap is `ChatRow.opensPics`; what its viewer does is
/// `PicViewer.waiting(in:)`, then opening each as it's shown. Runs only with
/// NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveListPicsTests {
    let live = LiveChatListTests()
    let pics = LivePicsTests()

    func friends() async throws -> (ana: Account, ben: Account) {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        _ = try await FriendsModel(account: ana).add(ben.user.username)
        let bens = FriendsModel(account: ben)
        try await bens.loadRequests()
        try await bens.accept(try #require(bens.requests.incoming.first))
        return (ana, ben)
    }

    @Test func aFriendsTwoPicsOpenFromTheListAndLeaveTheChatRead() async throws {
        let (ana, ben) = try await friends()
        let key = try E2E.pairKey(mine: ana.identity(), theirs: ben.publicKey, myId: ana.user.id, theirId: ben.user.id)
        let photo = try #require(LiveProfileTests.photo(.systemPink, width: 300, height: 400).jpegData(compressionQuality: 0.8))
        for caption in ["one", "two"] {
            try await pics.upload("chats/\(ben.user.id)/snaps", try E2E.encryptImage(key, photo, caption: caption, sender: ana.user.id, recipient: ben.user.id),
                                  format: E2E.imageFormat, token: ana.token)
        }

        // Ben's list: Ana's newest is a pic waiting for him, so a tap shows it from the list.
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(ben)
        let row = try #require(list.rows.first { $0.kind == .friend(ana.user.id) })
        #expect(row.preview == "New pic" && row.waiting == .snap && row.opensPics)

        // His socket, feeding the list as the screen does.
        let (events, arriving) = AsyncStream.makeStream(of: LiveEvent.self)
        let socket = Live(account: ben)
        socket.onEvent = { event in
            list.heard(event, account: ben)
            arriving.yield(event)
        }
        socket.start()
        defer { socket.stop() }
        let giveUp = Task { try? await Task.sleep(for: .seconds(15)); arriving.finish() }  // whichever comes first
        defer { giveUp.cancel() }
        var heard = events.makeAsyncIterator()
        var ready = false
        while !ready, let e = await heard.next() { if case .ready = e { ready = true } }
        try #require(ready)

        // The viewer from the list: the chat's waiting pics as the server says now, oldest first, each opened as it's shown.
        let chat = Conversation(.friend(try #require(list.reader?.friends[ana.user.id])), account: ben, reader: try #require(list.reader))
        let waiting = try await PicViewer.waiting(in: chat)
        #expect(waiting.count == 2)
        var captions: [String] = []
        for pic in waiting {
            let shown = try await chat.open(pic)
            #expect(shown.image == photo)
            captions.append(shown.caption)
            await chat.confirmOpened(pic)
        }
        #expect(captions == ["one", "two"])

        // The list hears both were opened (no reload for it): nothing waits, and the server says it's all read.
        var opened = 0
        while opened < 2, let e = await heard.next() { if case .message(let m) = e, m.snapState == "opened" { opened += 1 } }
        #expect(opened == 2)
        await list.quiet()
        let after = try #require(list.rows.first { $0.kind == .friend(ana.user.id) })
        #expect(after.preview == "Pic viewed" && after.waiting == nil && !after.opensPics)
        #expect(list.waitingCount == 0)
        let fromServer = try await Server(live.address).friends(token: ben.token)
        #expect(fromServer.first { $0.id == ana.user.id }?.unread == 0)
    }

    @Test func aGroupsPicFromTheListReadsItOnlyWhenNothingElseWaited() async throws {
        let (ana, ben) = try await friends()
        let id = try await GroupModel.create(name: "Pics", members: [ben.user.id], account: ana)
        let anas = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await anas.load(ana)
        let toGroup = Conversation(.group(try #require(anas.groups[id])), account: ana, reader: try #require(anas.reader))
        try await toGroup.loadNewest()
        let jpeg = try #require(Conversation.photoJPEG(LiveProfileTests.photo(.systemMint, width: 600, height: 800)))
        try await toGroup.sendPhoto(jpeg, caption: "all of us")

        // Ben's list: the group's newest is Ana's pic, waiting; only it is unread.
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(ben)
        var row = try #require(list.rows.first { $0.kind == .group(id) })
        #expect(row.waiting == .snap && row.opensPics && list.groups[id]?.unread == 1)
        let chat = Conversation(.group(try #require(list.groups[id])), account: ben, reader: try #require(list.reader))
        var waiting = try await PicViewer.waiting(in: chat)
        #expect(waiting.count == 1)
        #expect(try await chat.open(waiting[0]).caption == "all of us")
        await chat.confirmOpened(waiting[0])
        // The pic was all that was unread: the group is read, as opening it would have done.
        #expect(Reader.readAfterShowing([waiting[0].messageId], unread: 1, in: chat.bubbles))
        await chat.markRead()
        try await list.load(ben)
        row = try #require(list.rows.first { $0.kind == .group(id) })
        #expect(row.waiting == nil && list.groups[id]?.unread == 0)

        // A text, then a pic: the pic shows from the list, and the text stays unread for when he opens the chat.
        await toGroup.send("did you see the last one?", replyTo: nil)
        try await toGroup.sendPhoto(jpeg, caption: "")
        try await list.load(ben)
        row = try #require(list.rows.first { $0.kind == .group(id) })
        #expect(row.opensPics && list.groups[id]?.unread == 2)
        waiting = try await PicViewer.waiting(in: chat)
        #expect(waiting.count == 1)
        _ = try await chat.open(waiting[0])
        await chat.confirmOpened(waiting[0])
        #expect(!Reader.readAfterShowing([waiting[0].messageId], unread: 2, in: chat.bubbles))
        try await list.load(ben)
        row = try #require(list.rows.first { $0.kind == .group(id) })
        #expect(row.waiting == .text && !row.opensPics)  // the text is still unread; a tap opens the chat
    }
}
