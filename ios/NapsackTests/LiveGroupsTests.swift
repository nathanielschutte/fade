import Foundation
import Testing
import UIKit
@testable import Napsack

/// Groups against a real napsack server (a local one; it makes accounts):
/// made with friends, renamed, a picture, members added and removed (the owner
/// only), and leaving. Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveGroupsTests {
    let live = LiveChatListTests()

    func befriend(_ a: Account, _ b: Account) async throws {
        _ = try await FriendsModel(account: a).add(b.user.username)
        let theirs = FriendsModel(account: b)
        try await theirs.loadRequests()
        try await theirs.accept(try #require(theirs.requests.incoming.first))
    }

    @Test func makeRenamePictureMembersAndLeave() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben"), cal = try await live.newAccount("cal")
        try await befriend(ana, ben)
        try await befriend(ana, cal)

        let id = try await GroupModel.create(name: "  Road trip  ", members: [ben.user.id], account: ana)
        let anas = GroupModel(id: id, account: ana), bens = GroupModel(id: id, account: ben)
        try await anas.load()
        #expect(anas.detail?.name == "Road trip" && anas.isOwner && anas.detail?.members.count == 2)

        try await bens.rename("Road trip 2")  // any member
        try await anas.load()
        #expect(anas.detail?.name == "Road trip 2")

        try await anas.setPicture(LiveProfileTests.photo(.systemPink))
        let list = ChatList(pinStore: MemoryPinStore())
        try await list.load(ben)
        #expect(list.rows.first { $0.kind == .group(id) }?.avatarId != nil)

        try await anas.add(cal.user.id)
        #expect(anas.detail?.members.map(\.id).contains(cal.user.id) == true)
        try await bens.load()
        #expect(!bens.isOwner)
        await #expect(throws: (any Error).self) { try await bens.remove(cal.user.id) }  // only the owner removes
        try await anas.remove(cal.user.id)
        #expect(anas.detail?.members.map(\.id).contains(cal.user.id) == false)

        try await bens.remove(ben.user.id)  // leaving
        try await list.load(ben)
        #expect(!list.rows.contains { $0.kind == .group(id) })
    }

    @Test func seenByAndEveryVersionOfAnEdit() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben"), cal = try await live.newAccount("cal")
        try await befriend(ana, ben)
        try await befriend(ana, cal)
        let id = try await GroupModel.create(name: "Seen", members: [ben.user.id, cal.user.id], account: ana)
        func chat(_ account: Account) async throws -> Conversation {
            let list = ChatList(pinStore: MemoryPinStore())
            try await list.load(account)
            let c = Conversation(.group(try #require(list.groups[id])), account: account, reader: try #require(list.reader), pinBook: list.pinBook)
            try await c.loadNewest()
            return c
        }
        let anas = try await chat(ana)
        await anas.send("first draft", replyTo: nil)
        let text = try #require(anas.bubbles.last)
        try await anas.edit(text, to: "second draft")
        try await anas.edit(try #require(anas.bubble(text.id)), to: "final")

        await anas.loadGroupReads()
        #expect(anas.seenBy == nil)
        let bens = try await chat(ben)
        await bens.markRead()
        await anas.loadGroupReads()
        #expect(anas.seenBy?.hasPrefix("Seen by") == true && anas.seenBy?.contains("ben") == true)
        let cals = try await chat(cal)
        await cals.markRead()
        await anas.loadGroupReads()
        #expect(anas.seenBy?.contains(" and ") == true)

        // Ben sees every version, oldest first, each opened on his phone.
        let edited = try #require(bens.bubble(text.id))
        #expect(edited.original == "first draft")
        let versions = try await bens.versions(of: edited)
        #expect(versions.map(\.text) == ["first draft", "second draft", "final"] && versions.map(\.label) == ["Sent", "Edited", "Edited"])
    }

    @Test func everyVersionOfADirectEdit() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        try await befriend(ana, ben)
        let list = ChatList(pinStore: MemoryPinStore())
        try await list.load(ana)
        let toBen = Conversation(.friend(try #require(list.reader?.friends[ben.user.id])), account: ana, reader: try #require(list.reader))
        try await toBen.loadNewest()
        await toBen.send("8pm?", replyTo: nil)
        let text = try #require(toBen.bubbles.last)
        try await toBen.edit(text, to: "8:30?")
        let edited = try #require(toBen.bubble(text.id))
        #expect(edited.original == "8pm?")
        #expect(try await toBen.versions(of: edited).map(\.text) == ["8pm?", "8:30?"])
    }
}
