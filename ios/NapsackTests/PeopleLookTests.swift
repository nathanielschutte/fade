import NapsackCrypto
import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Pictures of the lists of people (X45 to X47), a non-friend's profile, the
/// reaction row with its +, and the camera's flash button, from the narrowest
/// iPhone to the largest, and with large text. Only with `NAPSACK_SHOTS` set:
///   TEST_RUNNER_NAPSACK_SHOTS=/tmp/shots ONLY=NapsackTests/OnScreen/PeopleLookTests bash scripts/test-ios.sh
extension OnScreen {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_SHOTS"] != nil))
    struct PeopleLookTests {
        let account = ModerationTests().account  // Bob, id 3

        /// Friends 7 (a nickname and a picture), 8 (a long display name, a picture), 9 (just a username).
        func friends() throws -> [Int64: Friend] {
            [7: try PeopleTests.friend(id: 7, username: "alice", display: "Alice", nickname: "Al", avatar: 40),
             8: try PeopleTests.friend(id: 8, username: "alexandria_ocasio_the_third", display: "Alexandria Ocasio-Cortez the Third", avatar: 41),
             9: try PeopleTests.friend(id: 9, username: "ben", display: nil)]
        }

        /// A server with the group, the requests, a profile, and every picture.
        let server = StubServer { request in
            let path = request.url?.path ?? ""
            if path.contains("/avatar/") {
                let color: UIColor = path.contains("/40") ? .systemTeal : .systemOrange
                return (200, TestPicture.plain(color, size: CGSize(width: 300, height: 300)).jpegData(compressionQuality: 0.8)!)
            }
            switch path {
            case "/api/groups/12":
                return (200, json(["id": 12, "name": "Road trip", "role": "owner", "members": [
                    ["id": 3, "username": "bob", "role": "owner", "joined_at": 1],
                    ["id": 7, "username": "alice", "role": "member", "joined_at": 2],
                    ["id": 8, "username": "alexandria_ocasio_the_third", "role": "member", "joined_at": 3],
                    ["id": 20, "username": "cal_who_isnt_your_friend_yet", "role": "member", "joined_at": 4],
                ]]))
            case "/api/friends/requests":
                return (200, json(["incoming": [["id": 21, "username": "dana_with_a_long_username", "created_at": 1]],
                                   "outgoing": [["id": 22, "username": "eli", "created_at": 1]]]))
            case "/api/friend-link":
                return (200, json(["path": "/i/abc123", "created_at": 1, "uses": 0]))
            case "/api/users/7/profile":
                return (200, json(["kind": "friend", "id": 7, "username": "alice", "display_name": "Alice", "nickname": "Al",
                                   "avatar_id": 40, "joined_at": 1_790_000_000, "birthday": NSNull(), "friends_since": 1_791_000_000,
                                   "friend_count": 3, "mutual_friends": [["id": 8, "username": "alexandria_ocasio_the_third", "since": 1],
                                                                         ["id": 9, "username": "ben", "since": 1]],
                                   "together": ["texts": 12, "pics": 3, "first_message_at": 1_791_000_000],
                                   "streak": ["current": 0, "expiring": false, "longest": 0], "past_usernames": []]))
            default:
                return (404, json(["error": "Not found."]))
            }
        }

        /// `tall`: the whole list in one picture (a phone that many times as tall), to see every row.
        func shoot(_ name: String, _ view: some View, text: DynamicTypeSize = .large, tall: CGFloat = 1) async throws {
            let pictures = Pictures(account: account, transport: server)
            for (size, phone) in [("narrow", ModerationLookTests.narrow), ("small", Phone.small), ("large", Phone.large)] {
                let host = try Hosted(view.environment(Session(store: MemoryStore())).environment(pictures).environment(\.dynamicTypeSize, text),
                                      size: CGSize(width: phone.size.width, height: phone.size.height * tall), insets: phone.insets)
                try await Task.sleep(for: .milliseconds(900))  // pictures only: let it load and draw
                try host.save("\(name)-\(size)")
                host.close()
            }
        }

        @Test func groupMembers() async throws {
            let friends = try friends()
            func info() -> some View {
                NavigationStack {
                    GroupInfoScreen(model: GroupModel(id: 12, account: account, transport: server), account: account, avatarId: nil,
                                    friends: friends, left: {})
                }
            }
            try await shoot("group-members", info(), tall: 2.4)
            try await shoot("group-members-big-text", info(), text: .accessibility2, tall: 3.2)
        }

        @Test func friendsAndRequests() async throws {
            let friends = try friends()
            func screen() -> some View {
                NavigationStack { FriendsScreen(model: FriendsModel(account: account, transport: server), friends: friends) }
            }
            try await shoot("friends", screen(), tall: 2.6)
            try await shoot("friends-big-text", screen(), text: .accessibility2, tall: 3.2)
        }

        @Test func profiles() async throws {
            let friends = try friends()
            let stranger = Person(id: 20, username: "cal_who_isnt_your_friend_yet", friends: friends)
            try await shoot("person-stranger", NavigationStack { PersonProfileScreen(person: stranger, account: account, transport: server) })
            try await shoot("person-asked-you-big-text", NavigationStack {
                PersonProfileScreen(person: stranger, account: account, standing: .askedYou, transport: server)
            }, text: .accessibility2)
            try await shoot("person-blocked", NavigationStack {
                PersonProfileScreen(person: Person(id: 22, username: "eli", friends: [:]), account: account, standing: .blocked(1_793_300_000),
                                    transport: server)
            })
            let alice = try #require(friends[7])
            try await shoot("friend-profile-nickname", NavigationStack {
                FriendProfileScreen(friend: alice, account: account, safetyCode: "12345 67890", unfriended: {},
                                    model: ProfileModel(account: account, transport: server), friends: friends)
            })
        }

        @Test func pickers() async throws {
            let friends = try friends().values.sorted { $0.name < $1.name }
            try await shoot("new-group", NewGroupScreen(account: account, friends: friends, created: { _ in }), tall: 1.3)
            try await shoot("new-group-big-text", NewGroupScreen(account: account, friends: friends, created: { _ in }), text: .accessibility2,
                            tall: 3)
        }

        @Test func reactingWithAnyEmoji() async throws {
            var bubble = ModerationTests.bubble(.text("Who's bringing snacks for the drive?", edited: false))
            bubble.myReaction = "🦩"  // one from the emoji keyboard: in the row too, to take back
            let actions = ["Reply", "Copy", "Report"].map { MessageActions.Action(title: $0, icon: "circle") {} }
            try await shoot("react-any", MessageActions(bubble: bubble, quote: nil, reactions: E2E.reactions, actions: actions,
                                                        react: { _ in }, dismiss: {}))
        }

        @Test func theFlashButton() async throws {
            var back = CameraSession.Lenses.of(multiplier: 0.5, switchOvers: [2, 10], minFactor: 1, maxFactor: 30)
            back.flash = FlashOffer.of(photoModes: [.off, .on, .auto], torch: true)
            for (name, phone) in [("small", Phone.small), ("large", Phone.large)] {
                let host = try Hosted(CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .pick([], { _, _ in }, done: { _ in }), offering: back),
                                      size: phone.size, insets: phone.insets)
                try await Task.sleep(for: .milliseconds(500))
                try host.save("camera-flash-\(name)")
                host.close()
            }
        }
    }
}
