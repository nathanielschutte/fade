import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Pictures of reporting and blocking to look at, from the narrowest iPhone
/// (320 points, an SE with Display Zoom) to the largest, and with large text.
/// Only with `NAPSACK_SHOTS` set to a folder for them:
///   TEST_RUNNER_NAPSACK_SHOTS=/tmp/shots ONLY=NapsackTests/OnScreen/ModerationLookTests bash scripts/test-ios.sh
extension OnScreen {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_SHOTS"] != nil))
    struct ModerationLookTests {
        static let narrow = (size: CGSize(width: 320, height: 568), insets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))
        let account = ModerationTests().account
        let target = ReportTarget(what: .groupMessage(group: 3, message: 12), person: Reportable(id: 7, name: "Alexandria Ocasio"))

        func shoot(_ name: String, _ view: some View, text: DynamicTypeSize = .large) async throws {
            for (size, phone) in [("narrow", Self.narrow), ("small", Phone.small), ("large", Phone.large)] {
                let host = try Hosted(view.environment(Session(store: MemoryStore())).environment(\.dynamicTypeSize, text),
                                      size: phone.size, insets: phone.insets)
                try await Task.sleep(for: .milliseconds(700))  // pictures only: let it draw (and a dialog come up)
                try host.save("\(name)-\(size)")
                host.close()
            }
        }

        @Test func reporting() async throws {
            try await shoot("report-form", ReportSheet(target: target, account: account))
            try await shoot("report-form-big-text", ReportSheet(target: target, account: account), text: .accessibility2)
            try await shoot("report-person", ReportSheet(target: ReportTarget(what: .person, person: target.person), account: account))
            try await shoot("report-sent", ReportSheet(target: target, account: account, filed: Moderation.Filed(id: 1, already: false)))
            try await shoot("report-sent-big-text", ReportSheet(target: target, account: account, filed: Moderation.Filed(id: 1, already: false)),
                            text: .accessibility2)
        }

        @Test func theMessageMenu() async throws {
            let bubble = ModerationTests.bubble(.text("A message someone sent, which you might report.", edited: false))
            let actions = ["Reply", "Copy", "Report"].map { MessageActions.Action(title: $0, icon: "circle") {} }
            try await shoot("report-menu", MessageActions(bubble: bubble, quote: nil, reactions: ["👍", "❤️", "😂"], actions: actions,
                                                          react: { _ in }, dismiss: {}))
        }

        @Test func blocking() async throws {
            try await shoot("block-question", BlockQuestionStandIn(person: target.person))
            let server = StubServer { _ in
                (200, json(["blocks": [["id": 7, "username": "alexandria_ocasio_the_third", "blocked_at": 1_793_300_000],
                                       ["id": 8, "username": "ben", "blocked_at": 1_793_000_000]]]))
            }
            try await shoot("blocked-list", NavigationStack { BlockedScreen(model: BlockedModel(account: account, transport: server)) })
            try await shoot("blocked-list-big-text", NavigationStack { BlockedScreen(model: BlockedModel(account: account, transport: server)) },
                            text: .accessibility2)
            let none = StubServer { _ in (200, json(["blocks": []])) }
            try await shoot("blocked-none", NavigationStack { BlockedScreen(model: BlockedModel(account: account, transport: none)) })
        }
    }
}

/// "Block …?" asked as soon as it's on screen.
private struct BlockQuestionStandIn: View {
    let person: Reportable
    @State private var asking: Reportable?

    var body: some View {
        NavigationStack { List { Text("A profile") }.navigationTitle("Profile") }
            .blockQuestion($asking) { _ in }
            .task { asking = person }
    }
}
