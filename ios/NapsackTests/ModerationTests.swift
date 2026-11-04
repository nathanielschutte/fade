import Foundation
import SwiftUI
import Testing
@testable import Napsack

/// Reporting and blocking against a stand-in server: what can be reported,
/// and that a report carries ids, the reason, and the note, never a message's words.
@MainActor @Suite struct ModerationTests {
    let account = Account(server: "https://napsack.test", token: "t",
                          user: Me(id: 3, username: "bob", displayName: nil, role: "user", hasRecoveryKey: true),
                          publicKey: "", privateKey: Data())

    static func friend(id: Int64 = 7, system: Bool = false) throws -> Friend {
        try ChatListTests.decode(Friend.self, ChatListTests.friendJSON(alice: ["spki": "key"], last: nil, extra: ["id": id, "system": system]))
    }

    static func group(id: Int64 = 12) throws -> GroupSummary {
        try ChatListTests.decode(GroupSummary.self, [
            "id": id, "name": "Road trip", "role": "member", "member_count": 3, "last_message": NSNull(), "unread": 0,
            "favorite": false, "muted": false, "muted_until": NSNull(), "avatar_id": NSNull(), "encrypted": true])
    }

    static func bubble(_ content: Bubble.Content, id: Int64 = 40, mine: Bool = false, sender: Int64 = 7) -> Bubble {
        var b = Bubble(id: id, mine: mine, sender: mine ? nil : "Alice", content: content, replyTo: nil, time: .now, reactions: [])
        b.senderId = mine ? 3 : sender
        return b
    }

    /// Someone else's texts, pics, and videos; never your own, a group's events,
    /// what couldn't be opened, or Team Napsack's.
    @Test func whatCanBeReported() throws {
        let alice = try Self.friend(), team = try Self.friend(id: 1, system: true), group = try Self.group()
        let text = Self.bubble(.text("you're awful", edited: false))
        #expect(ReportTarget.message(text, in: .friend(alice)) == ReportTarget(what: .message(40), person: Reportable(id: 7, name: "Alice")))
        #expect(ReportTarget.message(Self.bubble(.media("Pic opened")), in: .friend(alice))?.what == .message(40))
        #expect(ReportTarget.message(Self.bubble(.media("New video")), in: .group(group))?.what == .groupMessage(group: 12, message: 40))
        #expect(ReportTarget.message(Self.bubble(.text("mine", edited: false), mine: true), in: .friend(alice)) == nil)
        #expect(ReportTarget.message(Self.bubble(.event("Ana added Ben")), in: .group(group)) == nil)
        #expect(ReportTarget.message(Self.bubble(.unreadable(Reader.cantOpen)), in: .friend(alice)) == nil)
        #expect(ReportTarget.message(Self.bubble(.text("Happy birthday!", edited: false), sender: 1), in: .friend(team)) == nil)
        #expect(ReportTarget.message(Self.bubble(.text("hi", edited: false), sender: 1), in: .group(group), friends: [1: team]) == nil)
    }

    /// The request has the ids, the reason, and the note as typed: no key for
    /// anything else, and the message's words nowhere in it.
    @Test func aReportSendsOnlyIds() async throws {
        let secret = "meet me behind the gym at 9"
        let server = StubServer { _ in (200, json(["id": 5, "already": false])) }
        let alice = try Self.friend()
        let direct = try #require(ReportTarget.message(Self.bubble(.text(secret, edited: false)), in: .friend(alice)))
        let filed = try await Moderation.report(direct, reason: .harassment, note: "  they keep at it  ", account: account, transport: server)
        #expect(filed == Moderation.Filed(id: 5, already: false))

        let inGroup = try #require(ReportTarget.message(Self.bubble(.text(secret, edited: false), id: 41), in: .group(try Self.group())))
        _ = try await Moderation.report(inGroup, reason: .spam, note: "   ", account: account, transport: server)
        _ = try await Moderation.report(ReportTarget(what: .person, person: Reportable(id: 7, name: "Alice")), reason: .other, note: "",
                                        account: account, transport: server)

        let sent = await server.requests
        #expect(sent.map(\.url?.path) == ["/api/reports", "/api/reports", "/api/reports"])
        #expect(sent.allSatisfy { $0.httpMethod == "POST" })
        for request in sent {
            let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(!raw.contains("gym") && !raw.contains("Alice"), "\(raw)")
            #expect(Set(body(request).keys).isSubset(of: ["kind", "message_id", "group_id", "user_id", "reason", "note"]), "\(raw)")
        }
        #expect(body(sent[0]) as NSDictionary == ["kind": "message", "message_id": 40, "reason": "harassment", "note": "they keep at it"])
        #expect(body(sent[1]) as NSDictionary == ["kind": "group_message", "message_id": 41, "group_id": 12, "reason": "spam"])
        #expect(body(sent[2]) as NSDictionary == ["kind": "person", "user_id": 7, "reason": "other"])
    }

    /// What the server says no with is what the person reads.
    @Test func aRefusedReportSaysWhy() async throws {
        let server = StubServer { _ in (404, json(["error": "That message isn't one you can report."])) }
        let target = ReportTarget(what: .message(9), person: Reportable(id: 7, name: "Alice"))
        await #expect(throws: ServerError.refused("That message isn't one you can report.", status: 404)) {
            _ = try await Moderation.report(target, reason: .spam, note: "", account: account, transport: server)
        }
    }

    /// Blocking, unblocking, and the list go where the server says, and only the newest list is shown.
    @Test func blockUnblockAndTheList() async throws {
        let server = StubServer { request in
            switch (request.httpMethod, request.url!.path) {
            case ("POST", "/api/blocks/7"): (200, json(["blocked": true, "already": false, "user": ["id": 7, "username": "alice"]]))
            case ("POST", "/api/blocks/7/remove"): (200, json(["blocked": false]))
            case ("GET", "/api/blocks"): (200, json(["blocks": [["id": 7, "username": "alice", "blocked_at": 1_793_300_000]]]))
            default: (404, json(["error": "not here"]))
            }
        }
        #expect(try await Moderation.block(7, account: account, transport: server) == false)
        let model = BlockedModel(account: account, transport: server)
        #expect(!model.loaded)
        await model.load()
        #expect(model.loaded && model.people == [BlockedPerson(id: 7, username: "alice", blockedAt: 1_793_300_000)])
        try await Moderation.unblock(7, account: account, transport: server)
        #expect(await server.requests.map { "\($0.httpMethod!) \($0.url!.path)" }
                == ["POST /api/blocks/7", "GET /api/blocks", "POST /api/blocks/7/remove"])
    }
}

/// Against a real server (a local one; it makes accounts): reporting a
/// message and a person, blocking (the friendship ends, both lists hear it
/// and drop the chat), Profile › Blocked, and unblocking (the friendship stays
/// ended). Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveModerationTests {
    let live = LiveChatListTests()

    func befriend(_ a: Account, _ b: Account) async throws {
        try await LiveGroupsTests().befriend(a, b)
    }

    func chat(_ kind: ChatRow.Kind, as account: Account) async throws -> (ChatList, Conversation) {
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account)
        let reader = try #require(list.reader)
        let chat: Conversation.Chat
        switch kind {
        case .friend(let id): chat = .friend(try #require(reader.friends[id]))
        case .group(let id): chat = .group(try #require(list.groups[id]))
        }
        let c = Conversation(chat, account: account, reader: reader, pinBook: list.pinBook)
        try await c.loadNewest()
        return (list, c)
    }

    @Test func reportingMessagesAndPeople() async throws {
        let ana = try await live.newAccount("rpa"), ben = try await live.newAccount("rpb"), cal = try await live.newAccount("rpc")
        try await befriend(ana, ben)
        try await befriend(ben, cal)
        let group = try await GroupModel.create(name: "Reports", members: [ana.user.id, cal.user.id], account: ben)

        // Ben sends Ana a text and the group one; Ana reports each from what her chats show.
        let (_, bensChat) = try await chat(.friend(ana.user.id), as: ben)
        await bensChat.send("something nasty", replyTo: nil)
        let (_, bensGroup) = try await chat(.group(group), as: ben)
        await bensGroup.send("something nasty for everyone", replyTo: nil)

        let (_, anasChat) = try await chat(.friend(ben.user.id), as: ana)
        let text = try #require(anasChat.bubbles.last)
        let direct = try #require(ReportTarget.message(text, in: anasChat.chat))
        let first = try await Moderation.report(direct, reason: .harassment, note: "not the first time", account: ana)
        #expect(!first.already)
        #expect(try await Moderation.report(direct, reason: .spam, note: "", account: ana) == Moderation.Filed(id: first.id, already: true))

        let (_, anasGroup) = try await chat(.group(group), as: ana)
        let groupText = try #require(anasGroup.bubbles.last { if case .text = $0.content { true } else { false } })
        let inGroup = try #require(ReportTarget.message(groupText, in: anasGroup.chat, friends: anasGroup.friendsById))
        #expect(inGroup.person.id == ben.user.id)
        #expect(!(try await Moderation.report(inGroup, reason: .hate, note: "", account: ana)).already)
        // Cal, in the group but not Ana's friend, can be reported as a person; her own message can't.
        _ = try await Moderation.report(ReportTarget(what: .person, person: Reportable(id: cal.user.id, name: "cal")), reason: .other,
                                        note: "", account: ana)
        let mine = try #require(bensChat.bubbles.last)
        #expect(ReportTarget.message(mine, in: bensChat.chat) == nil)
        await #expect(throws: (any Error).self) {
            _ = try await Moderation.report(ReportTarget(what: .message(mine.id), person: Reportable(id: ana.user.id, name: "ana")),
                                            reason: .spam, note: "", account: ben)
        }
    }

    @Test func blockingEndsTheFriendshipAndUnblockingDoesnt() async throws {
        let ana = try await live.newAccount("bla"), ben = try await live.newAccount("blb")
        try await befriend(ana, ben)
        let anas = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil), bens = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await anas.load(ana)
        try await bens.load(ben)
        #expect(anas.rows.contains { $0.kind == .friend(ben.user.id) } && bens.rows.contains { $0.kind == .friend(ana.user.id) })

        // Both sockets, feeding their lists as the screen does.
        var sockets: [Live] = [], giveUps: [Task<Void, Never>] = []
        var streams: [AsyncStream<LiveEvent>.Iterator] = []
        defer {
            sockets.forEach { $0.stop() }
            giveUps.forEach { $0.cancel() }
        }
        for (account, list) in [(ana, anas), (ben, bens)] {
            let (events, arriving) = AsyncStream.makeStream(of: LiveEvent.self)
            let socket = Live(account: account)
            socket.onEvent = { event in
                list.heard(event, account: account)
                arriving.yield(event)
            }
            socket.start()
            sockets.append(socket)
            giveUps.append(Task { try? await Task.sleep(for: .seconds(15)); arriving.finish() })  // whichever comes first
            var heard = events.makeAsyncIterator()
            var ready = false
            while !ready, let e = await heard.next() { if case .ready = e { ready = true } }
            try #require(ready)
            streams.append(heard)
        }

        // Ana blocks Ben: both hear friends_changed, and both lists drop the chat.
        #expect(try await Moderation.block(ben.user.id, account: ana) == false)
        for i in streams.indices {
            var changed = false
            while !changed, let e = await streams[i].next() { if case .friendsChanged = e { changed = true } }
            #expect(changed)
        }
        await anas.quiet()
        await bens.quiet()
        #expect(!anas.rows.contains { $0.kind == .friend(ben.user.id) })
        #expect(!bens.rows.contains { $0.kind == .friend(ana.user.id) })
        #expect(try await Moderation.block(ben.user.id, account: ana) == true)  // already
        // He can't ask her again; she can't ask him until she unblocks.
        await #expect(throws: (any Error).self) { _ = try await FriendsModel(account: ben).add(ana.user.username) }

        // Profile › Blocked lists him; Unblock takes him off it, and the friendship stays ended.
        let blocked = BlockedModel(account: ana)
        await blocked.load()
        #expect(blocked.loaded && blocked.people.map(\.id) == [ben.user.id] && blocked.people.first?.username == ben.user.username)
        try await blocked.unblock(try #require(blocked.people.first))
        #expect(blocked.people.isEmpty && blocked.problem == nil)
        #expect(try await Moderation.blocked(account: ana).isEmpty)
        try await anas.load(ana)
        #expect(!anas.rows.contains { $0.kind == .friend(ben.user.id) })
        await #expect(throws: (any Error).self) { try await Moderation.unblock(ben.user.id, account: ana) }  // not blocked now
        // And they can be friends again, by asking.
        try await befriend(ana, ben)
        try await anas.load(ana)
        #expect(anas.rows.contains { $0.kind == .friend(ben.user.id) })
    }

    /// Someone in a group with you, not your friend, can be blocked; the group stays.
    @Test func blockingSomeoneInAGroupLeavesTheGroup() async throws {
        let ana = try await live.newAccount("bga"), ben = try await live.newAccount("bgb"), cal = try await live.newAccount("bgc")
        try await befriend(ana, ben)
        try await befriend(ben, cal)
        let group = try await GroupModel.create(name: "Shared", members: [ana.user.id, cal.user.id], account: ben)
        #expect(try await Moderation.block(cal.user.id, account: ana) == false)
        let model = GroupModel(id: group, account: ana)
        try await model.load()
        #expect(Set(model.detail?.members.map(\.id) ?? []) == [ana.user.id, ben.user.id, cal.user.id])
        // A stranger can't be blocked, and gets the same answer as nobody.
        let stranger = try await live.newAccount("bgd")
        await #expect(throws: ServerError.refused("That isn't someone you can block.", status: 404)) {
            try await Moderation.block(stranger.user.id, account: ana)
        }
    }
}
