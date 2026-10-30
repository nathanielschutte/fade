import Foundation
import Testing
@testable import Napsack

/// The chat list's own actions against a real napsack server (a local one;
/// it makes accounts): favorite, mute, hide and unhide, leave a group, and
/// search. Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveListActionsTests {
    let live = LiveChatListTests()

    @Test func favoriteMuteHideLeaveAndSearch() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        let anas = FriendsModel(account: ana), bens = FriendsModel(account: ben)
        _ = try await anas.add(ben.user.username)
        try await bens.loadRequests()
        try await bens.accept(try #require(bens.requests.incoming.first))
        let server = try Server(live.address)
        let created = try Server.decoder.decode(LiveChatListTests.Created.self, from: await server.send(
            "groups", method: "POST", token: ben.token, json: LiveChatListTests.NewGroup(name: "Bowling night", memberIds: [ana.user.id])))

        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(ana)
        func row(_ kind: ChatRow.Kind) throws -> ChatRow { try #require(list.rows.first { $0.kind == kind }) }
        let friend = ChatRow.Kind.friend(ben.user.id), group = ChatRow.Kind.group(created.id)

        try await list.setFavorite(try row(friend), true, account: ana)
        #expect(try row(friend).favorite && list.favorites.map(\.kind) == [friend])
        try await list.setFavorite(try row(friend), false, account: ana)
        #expect(list.favorites.isEmpty)

        try await list.setMuted(try row(group), true, hours: 8, account: ana)
        #expect(try row(group).muted)
        try await list.setMuted(try row(group), false, account: ana)
        #expect(try !row(group).muted)

        try await list.setHidden(try row(friend), true, account: ana)
        #expect(list.hiddenRows.map(\.kind) == [friend] && !list.others.contains { $0.kind == friend })
        try await list.setHidden(try row(friend), false, account: ana)
        #expect(list.hiddenRows.isEmpty)

        #expect(list.search("bowling").map(\.kind) == [group])
        // By name; the group matches too, its newest message being "ben… created the group".
        #expect(Set(list.search(ben.user.username.uppercased()).map(\.kind)) == [friend, group])
        #expect(list.search("nothing like this").isEmpty)

        try await list.leave(try row(group), account: ana)
        #expect(!list.rows.contains { $0.kind == group })
    }
}
