import Foundation
import Testing
import UIKit
@testable import Napsack

/// Lists of people (X45 to X47): one way of naming anyone, a friend's picture
/// and anyone else's initial, and what a non-friend's profile offers.
@MainActor @Suite struct PeopleTests {
    static func friend(id: Int64 = 7, username: String = "alice", display: String? = "Alice", nickname: String? = nil,
                       avatar: Int64? = nil, system: Bool = false) throws -> Friend {
        try ChatListTests.decode(Friend.self, ChatListTests.friendJSON(alice: ["spki": "key"], nickname: nickname, last: nil, extra: [
            "id": id, "username": username, "display_name": display ?? NSNull(), "avatar_id": avatar ?? NSNull(), "system": system]))
    }

    /// Your nickname, else their display name, else their username, with
    /// @username beside it only where the name shown differs (F5, X47).
    @Test func everyoneIsNamedTheSameWay() throws {
        let nicknamed = Person(try Self.friend(nickname: "Al"))
        #expect(nicknamed.name == "Al" && nicknamed.handle == "@alice")
        let displayed = Person(try Self.friend())
        #expect(displayed.name == "Alice" && displayed.handle == "@alice")
        let plain = Person(try Self.friend(display: nil))
        #expect(plain.name == "alice" && plain.handle == nil)

        // Someone who isn't a friend: only their username, so nothing beside it, and no picture.
        let friends = [Int64(7): try Self.friend(nickname: "Al", avatar: 40)]
        let stranger = Person(id: 9, username: "cal", friends: friends)
        #expect(stranger.name == "cal" && stranger.handle == nil && stranger.avatarId == nil && stranger.friend == nil)
        // A friend found by id from a member list: the friend's name and picture, and their username now.
        let member = Person(id: 7, username: "alice_old", friends: friends)
        #expect(member.name == "Al" && member.handle == "@alice" && member.avatarId == 40 && member.friend != nil)
        #expect(member.reportable == Reportable(id: 7, name: "Al"))
    }

    /// Friends, by the name you see, without Team Napsack (it has no profile to open).
    @Test func yourFriendsByName() throws {
        let model = FriendsModel(account: ModerationTests().account, friends: [
            7: try Self.friend(id: 7, username: "zed", display: "Zed"),
            8: try Self.friend(id: 8, username: "amy", display: nil, nickname: "bee"),
            9: try Self.friend(id: 9, username: "cy", display: "Cy"),
            1: try Self.friend(id: 1, username: "napsack", display: "Team Napsack", system: true),
        ])
        #expect(model.friendList.map(\.name) == ["bee", "Cy", "Zed"])
        #expect(model.friendNames[8] == "bee")
        #expect(Person(try Self.friend(id: 1, system: true)).isTeam)
    }

    /// Under a non-friend's name: where you stand with them.
    @Test func whereYouStand() {
        #expect(PersonProfileScreen.standingWords(.stranger) == "Not your friend")
        #expect(PersonProfileScreen.standingWords(.askedYou) == "Wants to be friends")
        #expect(PersonProfileScreen.standingWords(.youAsked) == "You asked to be friends")
        #expect(PersonProfileScreen.standingWords(.friends) == "You're friends now")
        #expect(PersonProfileScreen.standingWords(.blocked(1_793_300_000)).hasPrefix("You block them, since "))
        #expect(PersonProfileScreen.Standing.blocked(1).isBlocked && !PersonProfileScreen.Standing.stranger.isBlocked)
    }

    /// Asking from a profile says whether you're friends now (they'd asked you), in the server's words.
    @Test func askingSaysWhetherYoureFriendsNow() async throws {
        let account = ModerationTests().account
        let requested = StubServer { request in
            request.url?.path == "/api/friends/requests" && request.httpMethod == "GET"
                ? (200, json(["incoming": [], "outgoing": []]))
                : (200, json(["status": "requested", "user": ["id": 9, "username": "cal"]]))
        }
        let asked = try await FriendsModel(account: account, transport: requested).ask("cal")
        #expect(!asked.friends && asked.words == "Request sent to cal.")
        let accepted = StubServer { request in
            request.httpMethod == "GET" ? (200, json(["incoming": [], "outgoing": []]))
                : (200, json(["status": "friends", "user": ["id": 9, "username": "cal"]]))
        }
        let both = try await FriendsModel(account: account, transport: accepted).ask("cal")
        #expect(both.friends && both.words == "You and cal are now friends.")
    }
}

/// Against a real server (a local one; it makes accounts): a group's members
/// as the app lists them, a friend with your nickname for them and their
/// picture, someone who isn't your friend with only their username; and
/// adding that someone from their profile. Runs only with NAPSACK_TEST_SERVER
/// set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LivePeopleTests {
    let live = LiveChatListTests()

    @Test func aGroupsMembersAreNamedAndPicturedByFriendship() async throws {
        let ana = try await live.newAccount("pea"), ben = try await live.newAccount("peb"), cal = try await live.newAccount("pec")
        try await LiveGroupsTests().befriend(ana, ben)
        try await LiveGroupsTests().befriend(ben, cal)
        let bens = ProfileModel(account: ben)
        try await bens.setName("Benjamin")
        try await bens.setPicture(LiveProfileTests.photo(.systemOrange))
        try await ProfileModel(account: ana).setNickname("Benny", for: ben.user.id)
        let calsOwn = ProfileModel(account: cal)
        try await calsOwn.setName("Calliope")  // friends only: Ana never sees it
        try await calsOwn.setPicture(LiveProfileTests.photo(.systemPurple))
        let group = try await GroupModel.create(name: "Names", members: [ana.user.id, cal.user.id], account: ben)

        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(ana)
        let friends = try #require(list.reader?.friends)
        let model = GroupModel(id: group, account: ana)
        try await model.load()
        let members = (model.detail?.members ?? []).map { Person(id: $0.id, username: $0.username, friends: friends) }
        let benny = try #require(members.first { $0.id == ben.user.id })
        #expect(benny.name == "Benny" && benny.handle == "@\(ben.user.username)" && benny.avatarId != nil)
        let stranger = try #require(members.first { $0.id == cal.user.id })
        #expect(stranger.name == cal.user.username && stranger.handle == nil && stranger.avatarId == nil)

        // From Cal's profile in the group, Ana asks; Cal (who sees her request) asks back: friends.
        let asked = try await FriendsModel(account: ana).ask(cal.user.username)
        #expect(!asked.friends)
        let cals = FriendsModel(account: cal)
        try await cals.loadRequests()
        #expect(cals.requests.incoming.map(\.id) == [ana.user.id])
        let back = try await cals.ask(ana.user.username)
        #expect(back.friends)
        try await list.load(ana)
        let now = Person(id: cal.user.id, username: cal.user.username, friends: try #require(list.reader?.friends))
        #expect(now.name == "Calliope" && now.handle == "@\(cal.user.username)" && now.avatarId != nil)  // a friend now: theirs to see
    }
}
