import Foundation
import Testing
import UIKit
@testable import Napsack

/// Groups against a real napsack server (a local one; it makes accounts):
/// made with friends, renamed, a picture, members added and removed (the owner
/// only), and leaving. Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil))
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
}
