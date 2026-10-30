import Foundation
import Testing
@testable import Napsack

/// The friend map: laid out the same way every time, you in the middle, nobody
/// on top of anyone; and against a real server, a friend's friend you don't
/// know is only a "?" (no id).
@MainActor @Suite struct FriendMapTests {
    @Test func theLayoutIsStableAndSpreadOut() {
        let graph = FriendMapModel.Graph(
            nodes: [.init(key: "me", userId: 1, kind: "self"), .init(key: "u2", userId: 2, kind: "friend"),
                    .init(key: "u3", userId: 3, kind: "friend"), .init(key: "?1", userId: nil, kind: "unknown")],
            edges: [["me", "u2"], ["me", "u3"], ["u2", "u3"], ["u2", "?1"]])
        let a = FriendMapModel.layout(graph), b = FriendMapModel.layout(graph)
        #expect(a == b && a["me"] == .zero)
        let points = Array(a.values)
        for i in points.indices { for j in points.indices where j > i {
            #expect(hypot(points[i].x - points[j].x, points[i].y - points[j].y) > 20)
        } }
        #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
    func aFriendsFriendIsOnlyAQuestionMark() async throws {
        let live = LiveChatListTests(), groups = LiveGroupsTests()
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben"), dan = try await live.newAccount("dan")
        try await groups.befriend(ana, ben)
        try await groups.befriend(ben, dan)
        let map = FriendMapModel(account: ana)
        try await map.load()
        let graph = try #require(map.graph)
        #expect(graph.nodes.filter { $0.kind == "friend" }.compactMap(\.userId) == [ben.user.id])
        let unknown = graph.nodes.filter { $0.kind == "unknown" }
        #expect(unknown.count == 1 && unknown.allSatisfy { $0.userId == nil && !$0.key.contains(String(dan.user.id)) })
        #expect(map.positions.count == graph.nodes.count)
    }
}
