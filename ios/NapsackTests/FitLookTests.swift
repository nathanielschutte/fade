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
            // From a chat, with others to add: "To Ben +" beside Send, short and long names.
            for (shown, name) in [("short", "Ben"), ("long", "Alexandria Ocasio-Cortez")] {
                let more = CameraSend.AddMore(here: .friend(8), chats: { Self.sendable }, send: { _, _ in }, done: { _ in })
                try await shoot("fit-camera-review-more-\(shown)", wait: .milliseconds(500)) {
                    CameraScreen(maxSeconds: 10, maxBytes: 4 << 20, send: .chat(name, { _ in }, more: more), start: .photo(TestPicture.photo()))
                }
            }
        }

        static let sendable = [
            ChatRow(kind: .friend(8), name: "Alexandria Ocasio-Cortez", preview: "", waiting: nil, time: nil, favorite: false, muted: false,
                    hidden: false, avatarId: 41, username: "aoc"),
            ChatRow(kind: .group(12), name: "Road trip", preview: "", waiting: nil, time: nil, favorite: false, muted: false, hidden: false),
            ChatRow(kind: .friend(9), name: "ben", preview: "", waiting: nil, time: nil, favorite: false, muted: false, hidden: false,
                    username: "ben"),
        ]

        /// What's on its way (X57): a text going (a small clock), one waiting
        /// behind one not sent, a pic going and one not sent, an edit not
        /// saved, and the chat list's row for a chat with something not sent.
        @Test func onItsWay() async throws {
            let sending = SendingTests()
            let down = Conversation(.friend(sending.alice), account: sending.account, reader: sending.reader,
                                    transport: StubServer { _ in throw URLError(.notConnectedToInternet) })
            down.retryDelays = [.zero, .zero]
            await down.send("Are we still on for tonight?", replyTo: nil)
            let row = ChatRow(kind: .friend(7), name: "alice", preview: "See you then", waiting: nil, time: .now, favorite: false, muted: false,
                              hidden: false)
            let edited = Bubble(id: 1, mine: true, sender: nil, content: .text("Running ten minutes late, sorry!", edited: true), replyTo: nil,
                                time: .now, reactions: [], pendingEdit: .failed("Not saved: no connection."))
            try await shoot("fit-on-its-way", wait: .milliseconds(200)) {
                VStack(spacing: 12) {
                    ChatRowView(row: row, sending: down)
                    ScrollView {
                        VStack(spacing: 6) {
                            BubbleView(bubble: edited, quote: nil, showTime: true, pending: edited.pendingEdit)
                            NotSentLine(why: "Not saved: no connection.", retry: {}, removeTitle: "Undo", remove: {})
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            OutgoingView(text: Outgoing(id: "a", text: "On my way now", replyTo: nil, status: .sending), quote: nil, retry: {}, remove: {})
                            OutgoingView(pic: OutgoingPic(id: "b", isVideo: false), retry: {}, remove: {})
                            OutgoingView(text: Outgoing(id: "c", text: "Can you grab milk?", replyTo: nil, status: .failed("Not sent: the connection is too slow.")),
                                         quote: nil, retry: {}, remove: {})
                            OutgoingView(text: Outgoing(id: "d", text: "And bread", replyTo: nil, status: .held), quote: nil, retry: {}, remove: {})
                            OutgoingView(pic: OutgoingPic(id: "e", isVideo: true, status: .failed("Not sent: no connection.")), retry: {}, remove: {})
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
        }

        /// Send to…, opened from a chat's camera: that chat picked already.
        @Test func sendToFromAChat() async throws {
            try await shoot("fit-send-to-from-chat") {
                NavigationStack {
                    SendToScreen(pic: PicToSend(ready: Task { ReadyToSend(media: .photo(Data()), caption: "", y: 0.75) }, isVideo: false), chats: Self.sendable,
                                 picked: [.friend(8)], send: { _, _ in }, done: { _ in })
                }
            }
        }
    }
}
