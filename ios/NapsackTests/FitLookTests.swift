import NapsackCrypto
import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Pictures of the screens the screen-size audit fixed (plan-ios.md, "Fits
/// every iPhone"), at both ends of the range: the narrowest (320 × 568, an SE
/// with Display Zoom) and the widest (669 × 951, the Duo open), each with
/// ordinary text and the largest accessibility text. Only with `NAPSACK_SHOTS` set:
///   TEST_RUNNER_NAPSACK_SHOTS=/tmp/shots ONLY=NapsackTests/OnScreen/FitLookTests bash scripts/test-ios.sh
extension OnScreen {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_SHOTS"] != nil))
    struct FitLookTests {
        static let widest = (size: CGSize(width: 669, height: 951), insets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
        static let phones = [("narrow", ModerationLookTests.narrow), ("widest", widest)]
        static let texts: [(String, DynamicTypeSize)] = [("", .large), ("-biggest-text", .accessibility5)]
        let account = ModerationTests().account

        /// Each phone, each text size: `<name>-<phone>[-biggest-text].png`.
        /// `tall`: a phone that many times as tall, to see all of a long screen.
        func shoot(_ name: String, wait: Duration = .milliseconds(700), tall: CGFloat = 1, _ view: @escaping () -> some View) async throws {
            let pictures = Pictures(account: account, transport: PeopleLookTests().server)
            for (size, phone) in Self.phones {
                for (big, text) in Self.texts {
                    let host = try Hosted(view().environment(Session(store: MemoryStore())).environment(pictures)
                                            .environment(\.dynamicTypeSize, text),
                                          size: CGSize(width: phone.size.width, height: phone.size.height * tall), insets: phone.insets)
                    try await Task.sleep(for: wait)  // pictures only: let it load and draw
                    try host.save("\(name)-\(size)\(big)")
                    host.close()
                }
            }
        }

        /// A chat with long and short texts both ways, its composer, and the
        /// camera and photo buttons beside it.
        @Test func theChat() async throws {
            let long = "The train was late again, so we waited at the station for almost an hour and watched the snow come down over the tracks."
            for (size, phone) in Self.phones {
                for (big, text) in Self.texts {
                    let chat = try await ChatOnScreen(texts: 8, size: phone.size, insets: phone.insets, text: text) { n in
                        [long, "Ok!", "Did you get home all right?", long + " " + long][n % 4]
                    }
                    await chat.settle()
                    chat.shoot("fit-chat-\(size)\(big)")
                    chat.close()
                }
            }
        }

        /// Holding a message: the reactions (with the + and your own), the message, and its actions.
        @Test func theHeldMessage() async throws {
            let words = "The train was late again, so we waited at the station for almost an hour and watched the snow come down."
            let actions = ["Reply", "Copy", "Report"].map { MessageActions.Action(title: $0, icon: "arrowshape.turn.up.left") {} }
            var theirs = ModerationTests.bubble(.text(words, edited: false))
            theirs.myReaction = "🦩"
            try await shoot("fit-held-theirs") {
                MessageActions(bubble: theirs, quote: nil, reactions: E2E.reactions, actions: actions, react: { _ in }, dismiss: {})
            }
            let mine = ModerationTests.bubble(.text(words, edited: true), mine: true)
            let edit = ["Reply", "Copy", "Edit", "Edits"].map { MessageActions.Action(title: $0, icon: "pencil") {} }
            try await shoot("fit-held-mine") {
                MessageActions(bubble: mine, quote: "Alice: Are you home yet?", reactions: E2E.reactions, actions: edit, react: { _ in },
                               dismiss: {})
            }
        }

        /// The chat list's rows: today's time, a day, a date; long names, muted, waiting.
        @Test func theChatList() async throws {
            let today = Calendar.current.date(bySettingHour: 10, minute: 44, second: 0, of: .now)!
            let rows = [
                ChatRow(kind: .friend(8), name: "Alexandria Ocasio-Cortez the Third", preview: "Did you get home all right?", waiting: .text,
                        time: today, favorite: false, muted: false, hidden: false, avatarId: 41, marks: " 🔥5"),
                ChatRow(kind: .friend(7), name: "Al", preview: "Tap to view pic", waiting: .snap, time: today.addingTimeInterval(-60),
                        favorite: false, muted: true, hidden: false, avatarId: 40),
                ChatRow(kind: .group(12), name: "Road trip", preview: "ben: the station was packed", waiting: nil,
                        time: today.addingTimeInterval(-3 * 86_400), favorite: false, muted: false, hidden: false),
                ChatRow(kind: .friend(9), name: "ben", preview: "Ok!", waiting: nil, time: today.addingTimeInterval(-40 * 86_400),
                        favorite: false, muted: false, hidden: false),
            ]
            try await shoot("fit-chat-list") {
                NavigationStack {
                    List(rows) { row in NavigationLink(value: row.id) { ChatRowView(row: row) } }
                        .listStyle(.plain).navigationTitle("Chats")
                }
            }
        }

        @Test func settings() async throws {
            try await shoot("fit-settings", tall: 2) { NavigationStack { SettingsScreen(account: account) } }
        }

        /// Add a friend: the code, Share and Copy link, and the field to add by username.
        @Test func friends() async throws {
            let people = PeopleLookTests()
            let friends = try people.friends()
            let server = people.server
            try await shoot("fit-friends", wait: .milliseconds(900), tall: 4) {
                NavigationStack { FriendsScreen(model: FriendsModel(account: account, transport: server), friends: friends) }
            }
        }

        /// The camera, live: the lens buttons (.5, 1×, 2, 10) and the flash.
        @Test func theCamera() async throws {
            var back = CameraSession.Lenses.of(multiplier: 0.5, switchOvers: [2, 10], minFactor: 1, maxFactor: 30)
            back.flash = FlashOffer.of(photoModes: [.off, .on, .auto], torch: true)
            try await shoot("fit-camera", wait: .milliseconds(500)) {
                CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .pick([], { _, _ in }, done: { _ in }), offering: back)
            }
            try await shoot("fit-camera-review", wait: .milliseconds(500)) {
                CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .chat("Alexandria Ocasio-Cortez") { _ in }, start: .photo(TestPicture.photo()))
            }
        }
    }
}
