import UIKit
import XCTest

/// An open chat, driven as a person drives it, against the local test server
/// (TestServer). Two accounts are friends with 60 texts between them; the app
/// signs in as one through its sign-in screen, and the other (here) sends
/// texts and types. The rules checked are the chat's few scrolling decisions
/// (ChatScreen): it opens on the newest; while you're at the bottom, the
/// newest stays in sight above the composer and the keyboard; once you've
/// scrolled up, nothing moves what you're reading. And holding a message
/// brings its menu while the finger is still down.
@MainActor final class ChatUITests: XCTestCase {
    /// The accounts and their chat, made once for every test here.
    struct Chat {
        let server: TestServer
        let me: TestServer.Person
        let friend: TestServer.Person
        /// The newest text so far.
        var newest: String
        var sent = 60
        /// Each of the first 60 texts' message id, by its words.
        var ids: [String: Int64] = [:]
    }
    static var chat: Chat?
    /// The app has been launched fresh once this run.
    static var started = false

    var app: XCUIApplication!

    /// Ends a test that can't go on (after XCTFail has said why, where).
    struct Stop: Error {}

    override func setUp() async throws {
        guard let server = TestServer.configured else {
            throw XCTSkip("needs a server: scripts/test-ios.sh runs one (NAPSACK_TEST_SERVER)")
        }
        if Self.chat == nil {
            let me = try await server.newAccount("ui"), friend = try await server.newAccount("pal")
            try await server.befriend(me, friend)
            var ids: [String: Int64] = [:]
            for n in 1...60 {
                // Theirs and mine, a few of them longer, as a chat goes.
                let text = n % 7 == 0 ? "Message \(n).\nA second line.\nAnd a third." : "Message \(n)."
                ids[text] = n % 3 == 0 ? try await server.send(text, from: me, to: friend) : try await server.send(text, from: friend, to: me)
            }
            // The friend has a picture, as the chat list shows it (X48: tapping it opens the chat).
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { c in
                UIColor.systemTeal.setFill()
                c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            }
            try await server.setPicture(try XCTUnwrap(picture.jpegData(compressionQuality: 0.8)), for: friend)
            Self.chat = Chat(server: server, me: me, friend: friend, newest: "Message 60.", ids: ids)
        }
        app = XCUIApplication()
        app.launchEnvironment["NAPSACK_UI_TEST_SERVER"] = server.address
        if !Self.started {
            // The first launch starts as if just installed (keys pinned in an earlier run, from a server since thrown away, go).
            app.launchEnvironment["NAPSACK_FRESH_START"] = "1"
            Self.started = true
        }
        app.launch()
    }

    // ---------- the newest message stays in sight ----------

    /// Opening the chat, the keyboard coming up, four lines in the composer,
    /// the friend typing, and a new message: each time, the newest is in sight.
    func testTheNewestStaysInSight() async throws {
        var chat = try XCTUnwrap(Self.chat)
        try openChat(chat)
        try expectInSight(chat.newest, "opening the chat")
        // The composer's buttons are a finger's worth to tap (ios-onboarding.md, screen sizes: 44 × 44 at least).
        for name in ["Camera", "Send a photo", "Send"] {
            let frame = app.buttons[name].firstMatch.frame
            try require(frame.width >= 44 && frame.height >= 44, "\(name) is at least 44 × 44 points: \(frame.size)")
        }

        composer.tap()
        try require(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard came up")
        try expectInSight(chat.newest, "with the keyboard up")

        composer.typeText("One\nTwo\nThree\nFour")
        try expectInSight(chat.newest, "with four lines in the composer")

        let socket = try await FriendSocket(chat.server, as: chat.friend)
        defer { socket.close() }
        try await socket.typing(to: chat.me)
        let typing = "\(chat.friend.username) is typing…"
        try require(poll(5) { $0.message(typing) != nil }, "the typing line showed")
        try expectInSight(typing, "the typing line itself")
        try expectInSight(chat.newest, "while they're typing")
        shot("chat-keyboard-four-lines-typing")

        chat = try await friendSends(chat)
        try expectInSight(chat.newest, "a new message")
        try require(poll(0) { !$0.has(identifier: "new-messages") }, "no note about new messages: it's in sight")
    }

    /// A chat opened before (from its kept page, with what came since joining
    /// it), then the keyboard: the newest sits just above the composer, never
    /// scrolled off the top (Nate, 2026-11-03, on his phone).
    func testReopenedThenKeyboard() async throws {
        let chat = try XCTUnwrap(Self.chat)
        try openChat(chat)
        try expectInSight(chat.newest, "opening the chat")
        app.navigationBars.buttons.firstMatch.tap()  // back to the list
        let later = try await friendSends(chat)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", chat.friend.username)).firstMatch
        try require(row.waitForExistence(timeout: 10), "back on the list")
        row.tap()
        try require(composer.waitForExistence(timeout: 10), "the chat opened again")
        try expectInSight(later.newest, "opened again")
        composer.tap()
        try require(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard came up")
        shot("chat-reopened-keyboard")
        try expectInSight(later.newest, "opened again, with the keyboard up")
    }

    // ---------- scrolled up, nothing moves ----------

    /// Scrolled up to read, a new message doesn't move what you're reading;
    /// a quiet note says it's there, and takes you to it.
    func testScrolledUpNothingMoves() async throws {
        var chat = try XCTUnwrap(Self.chat)
        try openChat(chat)
        try expectInSight(chat.newest, "opening the chat")

        messages.swipeDown()
        let reading = try settledMessageInMiddle()

        chat = try await friendSends(chat)
        let note = app.buttons["new-messages"]
        try require(note.waitForExistence(timeout: 5), "a note said a new message came")
        try expectStill(reading, "after a new message came")
        shot("chat-scrolled-up-new-messages")

        note.tap()
        try expectInSight(chat.newest, "after tapping the note")
        try require(poll(5) { !$0.has(identifier: "new-messages") }, "the note went once you were at the newest")
    }

    /// Scrolling up a little at a time to the beginning: each drag moves what's
    /// on screen as far as the finger went, and no further. The page before
    /// joins above what you're reading without pushing it.
    func testOlderMessagesJoinAboveWithoutAJump() async throws {
        let chat = try XCTUnwrap(Self.chat)
        try openChat(chat)
        try expectInSight(chat.newest, "opening the chat")
        let drag: CGFloat = 250
        for step in 1...30 {
            if poll(0, { $0.beginningInSight }) { break }
            let reading = try settledMessageInMiddle()
            let start = messages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: drag)), withVelocity: .slow, thenHoldForDuration: 0.25)
            let moved = try settled(reading).minY - reading.frame.minY
            try require(moved <= drag + 30, "step \(step): \(reading.words) moved \(Int(moved)) points for a \(Int(drag)) point drag (pushed by what joined above)")
            try require(moved > 20 || poll(0) { $0.beginningInSight }, "step \(step): the drag scrolled the chat (moved \(Int(moved)))")
        }
        try require(poll(5) { $0.message("Message 1.") != nil }, "the oldest message, at the beginning")
    }

    // ---------- holding a message ----------

    /// Holding a message brings its menu while the finger is still down (it
    /// stays when the finger then moves), and a swipe still replies.
    func testHoldingAndSwiping() async throws {
        let chat = try XCTUnwrap(Self.chat)
        try openChat(chat)
        let message = messages.staticTexts[chat.newest]
        try require(message.waitForExistence(timeout: 5), "the newest message showed")

        // Held, then moved before letting go: if the menu waited for the
        // release, the move would have started a scroll instead.
        let start = message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)), withVelocity: .slow, thenHoldForDuration: 0.1)
        try require(app.buttons["Reply"].waitForExistence(timeout: 2), "the menu came up while holding")
        shot("chat-held-menu")
        app.buttons["Close"].firstMatch.tap()
        try require(poll(5) { !$0.has(label: "Reply") }, "the menu closed")

        // A plain hold.
        message.press(forDuration: 0.6)
        try require(app.buttons["Reply"].waitForExistence(timeout: 2), "the menu came up")
        app.buttons["Close"].firstMatch.tap()
        try require(poll(5) { !$0.has(label: "Reply") }, "the menu closed")

        // Swipe right to reply.
        let middle = message.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 140, dy: 0)), withVelocity: .default, thenHoldForDuration: 0)
        try require(app.buttons["Cancel reply"].waitForExistence(timeout: 3), "swiping replied")
    }

    /// + after the quick row brings the system's emoji keyboard, and the first
    /// emoji typed is the reaction (X49): it shows under the message, as the
    /// server stored it.
    func testReactingWithAnyEmoji() async throws {
        let chat = try XCTUnwrap(Self.chat)
        try openChat(chat)
        let message = messages.staticTexts[chat.newest]
        try require(message.waitForExistence(timeout: 5), "the newest message showed")
        message.press(forDuration: 0.6)
        let more = app.buttons["React with another emoji"]
        try require(more.waitForExistence(timeout: 3), "the menu has + after the quick row")
        more.tap()
        try require(app.keyboards.firstMatch.waitForExistence(timeout: 5), "a keyboard came up for any emoji")
        shot("chat-react-any-keyboard")
        app.typeText("🦩")
        let reacted = app.buttons["🦩 1, including you. Tap to take yours back"]
        try require(reacted.waitForExistence(timeout: 10), "the flamingo shows under the message")
        try require(!app.buttons["React with another emoji"].exists, "the menu closed")
        reacted.tap()  // the same again takes it back
        try require(waitUntil(10) { !reacted.exists }, "taken back")
    }

    // ---------- lists of people ----------

    /// In the chat list, a chat's picture is part of its row: tapping it opens
    /// the chat (X48), not the picture.
    func testAChatsPictureOpensTheChat() async throws {
        let chat = try XCTUnwrap(Self.chat)
        try openChat(chat)  // the list showed first, with the friend's picture
        app.navigationBars.buttons.firstMatch.tap()
        let name = app.staticTexts[chat.friend.username]
        try require(name.waitForExistence(timeout: 10), "back on the list")
        // The picture sits left of the name, 44 points across.
        let picture = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: name.frame.minX - 12 - 22, dy: name.frame.midY + 10))
        picture.tap()
        try require(composer.waitForExistence(timeout: 10), "tapping the picture opened the chat")
    }

    /// A friend request's row opens what their profile can show (X46), and its
    /// Accept button accepts, right there.
    func testARequestOpensTheirProfile() async throws {
        let chat = try XCTUnwrap(Self.chat)
        let stranger = try await chat.server.newAccount("asker")
        _ = try await chat.server.request("friends/requests", method: "POST", token: stranger.token, json: ["username": chat.me.username])
        try openChat(chat)
        app.navigationBars.buttons.firstMatch.tap()
        let friends = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Friends'")).firstMatch
        try require(friends.waitForExistence(timeout: 10), "back on the list")
        friends.tap()
        let row = app.staticTexts[stranger.username]
        try require(row.waitForExistence(timeout: 10), "their request is listed")
        row.tap()
        try require(app.staticTexts["Wants to be friends"].waitForExistence(timeout: 5), "their profile opened")
        try require(app.buttons["Report \(stranger.username)"].exists, "it offers Report")
        shot("profile-of-a-request")
        app.navigationBars.buttons.firstMatch.tap()
        let accept = app.buttons["Accept"]
        try require(accept.waitForExistence(timeout: 5), "back on Friends")
        accept.tap()
        try require(waitUntil(10) { !self.app.buttons["Accept"].exists }, "accepted")
        try require(!app.staticTexts["Wants to be friends"].exists, "Accept didn't open the profile")
        try require(app.navigationBars["Friends"].exists, "still on Friends")
    }

    // ---------- links in texts ----------

    /// A link in a text to the app's own site, at a message (as Team Napsack's
    /// warnings carry), is tappable and brings that message into view; a link
    /// to anywhere else in the same text isn't a link at all.
    func testALinkToAMessageOpensIt() async throws {
        var chat = try XCTUnwrap(Self.chat)
        let target = try XCTUnwrap(chat.ids["Message 30."])
        let site = chat.server.address.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await chat.server.send("Open it: \(site)/#chat=\(chat.friend.id)&message=\(target) or https://evil.example/#chat=\(chat.friend.id)",
                                   from: chat.friend, to: chat.me)
        chat = try await friendSends(chat)  // a plain newest after it, as the other tests expect
        try openChat(chat)
        try expectInSight(chat.newest, "opening the chat")
        let link = messages.links.firstMatch
        try require(link.waitForExistence(timeout: 5), "the app's own link showed as a link")
        try require(messages.links.count == 1, "only the app's own link is one (\(messages.links.count) links)")
        try require(poll(1) { screen in
            guard let m = screen.message("Message 30.") else { return true }
            return m.frame.maxY < screen.top || m.frame.minY > screen.bottom
        }, "Message 30. out of sight before the tap")
        link.tap()
        try expectInSight("Message 30.", "after tapping the link")
        shot("chat-link-opened-message")
        try require(!app.buttons["Reply"].exists, "a tap on a link doesn't bring the message's menu")
    }

    // ---------- Profile ----------

    /// Delete account sits below Sign out, and Sign out asks first: until
    /// it's answered, you're still signed in (Nate: it was instant).
    func testSigningOutAsksFirst() async throws {
        let chat = try XCTUnwrap(Self.chat)
        try openChat(chat)
        app.tabBars.buttons["Profile"].tap()
        let signOut = app.buttons["Sign out"], delete = app.buttons["Delete account"]
        for _ in 0..<6 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        try require(signOut.isHittable && signOut.frame.maxY <= delete.frame.minY, "Delete account is below Sign out")
        signOut.tap()
        try require(app.staticTexts["Sign out?"].waitForExistence(timeout: 5), "signing out asks first")
        shot("profile-sign-out-asks")
        try require(!app.textFields["Username"].exists, "still signed in while it asks")
        try confirmSignOut()
        try require(app.textFields["Username"].waitForExistence(timeout: 10), "signed out once it's answered")
    }

    // ---------- helpers ----------

    var composer: XCUIElement { app.descendants(matching: .any).matching(identifier: "composer").firstMatch }
    /// The chat's own scroll view (the keyboard's suggestions are a scroll view too).
    var messages: XCUIElement { app.scrollViews["messages"] }

    /// Signed in (through the sign-in screen, the first time), then into the chat with the friend.
    func openChat(_ chat: Chat) throws {
        let username = app.textFields["Username"]
        let row = app.staticTexts[chat.friend.username]
        let list = app.navigationBars["Chats"]
        // A session from an earlier test may still be signed in (a stale one ends by itself and shows sign-in).
        try require(waitUntil(20) { username.exists || row.exists || list.exists }, "the app started")
        if !username.exists && !waitUntil(5, { username.exists || row.exists }) {
            // Someone else from an earlier run, still signed in: out first.
            try signOut()
            try require(username.waitForExistence(timeout: 10), "signed out of the other account")
        }
        if username.exists {
            username.tap()
            username.typeText(chat.me.username)
            let password = app.secureTextFields["Password"]
            password.tap()
            password.typeText(chat.me.password)
            app.buttons["Sign in"].tap()
        }
        // The system's questions (notifications; saving the password) come once, in any order.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try require(waitUntil(30) {
            if springboard.alerts.firstMatch.exists {
                let allow = springboard.alerts.buttons["Allow"]
                if allow.exists { allow.tap() } else { springboard.alerts.buttons.firstMatch.tap() }
            }
            let notNow = self.app.buttons["Not Now"]
            if notNow.exists { notNow.tap() }
            return row.exists && row.isHittable
        }, "signed in, with the chat in the list")
        row.tap()
        try require(composer.waitForExistence(timeout: 10), "the chat opened")
    }

    /// Profile › Sign out, and yes to "Sign out?".
    func signOut() throws {
        app.tabBars.buttons["Profile"].tap()
        let signOut = app.buttons["Sign out"]
        for _ in 0..<6 where !(signOut.exists && signOut.isHittable) { app.swipeUp() }
        signOut.tap()
        try confirmSignOut()
    }

    /// Yes to "Sign out?": the question's own Sign out, not the row under it.
    func confirmSignOut() throws {
        try require(app.staticTexts["Sign out?"].waitForExistence(timeout: 5), "signing out asks first")
        let inDialog = app.sheets.buttons["Sign out"]
        if inDialog.exists { inDialog.tap() } else { app.buttons.matching(identifier: "Sign out").allElementsBoundByIndex.last?.tap() }
    }

    /// The friend sends the next text; returns the chat with it as the newest.
    func friendSends(_ chat: Chat) async throws -> Chat {
        var chat = chat
        chat.sent += 1
        chat.newest = "Message \(chat.sent)."
        try await chat.server.send(chat.newest, from: chat.friend, to: chat.me)
        Self.chat = chat
        return chat
    }

    /// The message is all there to see: under the navigation bar, above the
    /// composer and the keyboard (waiting for any scroll to finish).
    func expectInSight(_ words: String, _ when: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var last = "not found"
        let ok = poll(5) { screen in
            guard let message = screen.message(words) else { last = "not found"; return false }
            // A bubble reaches 8 points past its words, above and below.
            let frame = message.frame.insetBy(dx: 0, dy: -8)
            last = "message \(frame.minY)...\(frame.maxY), visible \(screen.top)...\(screen.bottom)"
            return frame.minY >= screen.top - 0.5 && frame.maxY <= screen.bottom + 0.5
        }
        try require(ok, "\(words) in sight \(when): \(last)", file: file, line: line)
    }

    /// A message, and where it was.
    struct Reading {
        let words: String
        let frame: CGRect
    }

    /// The message near the middle of what can be seen, once scrolling has stopped.
    func settledMessageInMiddle() throws -> Reading {
        var chosen: Reading?
        let ok = poll(10) { screen in
            let middle = (screen.top + screen.bottom) / 2
            guard let near = screen.messages.filter({ $0.label.hasPrefix("Message ") })
                .min(by: { abs($0.frame.midY - middle) < abs($1.frame.midY - middle) }) else { return false }
            defer { chosen = Reading(words: near.label, frame: near.frame) }
            return chosen?.words == near.label && abs((chosen?.frame.minY ?? .nan) - near.frame.minY) < 0.5  // the same, in the same place twice
        }
        try require(ok, "scrolling settled")
        return try XCTUnwrap(chosen)
    }

    /// Where a message ended up once it stopped moving.
    func settled(_ reading: Reading) throws -> CGRect {
        var last: CGRect?
        let ok = poll(10) { screen in
            guard let frame = screen.message(reading.words)?.frame else { last = nil; return false }
            defer { last = frame }
            return last.map { abs($0.minY - frame.minY) < 0.5 } ?? false
        }
        try require(ok, "\(reading.words) settled on screen (it was pushed out of sight?)")
        return try XCTUnwrap(last)
    }

    /// The message hasn't moved from where it was, and stays put a moment.
    func expectStill(_ reading: Reading, _ when: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var now = reading.frame
        for _ in 0..<4 {
            guard let screen = try? Screen(app), let frame = screen.message(reading.words)?.frame else { continue }
            now = frame
            if abs(now.minY - reading.frame.minY) > 1 { break }
        }
        try require(abs(now.minY - reading.frame.minY) <= 1,
                    "what you were reading stayed put \(when): \(reading.words) was at \(reading.frame.minY), now \(now.minY)", file: file, line: line)
    }

    /// Reads the screen in one go until the condition holds (true) or time runs out (false): never a fixed wait.
    func poll(_ seconds: TimeInterval, _ condition: (Screen) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let screen = try? Screen(app), condition(screen) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < end
        return false
    }

    /// Polls until the condition holds (true) or time runs out (false): never a fixed wait.
    @discardableResult func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < end
        return condition()
    }

    /// Records a failure here, with a screenshot of the moment, and ends the test.
    func require(_ ok: Bool, _ what: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) throws {
        if ok { return }
        shot("failed: \(what())")
        XCTFail(what(), file: file, line: line)
        throw Stop()
    }

    /// A screenshot, kept with the results, and in NAPSACK_SHOTS (a folder on the Mac) when that's set.
    func shot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["NAPSACK_SHOTS"], !folder.isEmpty {
            let file = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(80)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "ui-\(String(file)).png"))
        }
    }
}

/// The app's screen, read in one go: every XCUIElement property is a round
/// trip to the app, and a snapshot of everything is one.
@MainActor struct Screen {
    let root: any XCUIElementSnapshot

    init(_ app: XCUIApplication) throws {
        root = try app.snapshot()
    }

    func all(_ match: (any XCUIElementSnapshot) -> Bool, in node: (any XCUIElementSnapshot)? = nil) -> [any XCUIElementSnapshot] {
        var found: [any XCUIElementSnapshot] = []
        func visit(_ n: any XCUIElementSnapshot) {
            if match(n) { found.append(n) }
            n.children.forEach(visit)
        }
        visit(node ?? root)
        return found
    }

    func first(_ match: (any XCUIElementSnapshot) -> Bool) -> (any XCUIElementSnapshot)? {
        all(match).first
    }

    func has(identifier: String) -> Bool { first { $0.identifier == identifier } != nil }
    func has(label: String) -> Bool { first { $0.label == label } != nil }

    /// The chat's words, in its own scroll view.
    var messages: [any XCUIElementSnapshot] {
        guard let chat = first({ $0.identifier == "messages" }) else { return [] }
        return all({ $0.elementType == .staticText }, in: chat)
    }

    func message(_ words: String) -> (any XCUIElementSnapshot)? {
        messages.first { $0.label == words }
    }

    /// "This is the beginning of your chat with …", where it can be seen.
    var beginningInSight: Bool {
        guard let beginning = messages.first(where: { $0.label.hasPrefix("This is the beginning") }) else { return false }
        return beginning.frame.minY >= top - 0.5 && beginning.frame.maxY <= bottom + 0.5
    }

    /// Where messages can be seen: under the navigation bar...
    var top: CGFloat {
        first { $0.elementType == .navigationBar }?.frame.maxY ?? 0
    }

    /// ...and above the composer and the keyboard.
    var bottom: CGFloat {
        let composer = first { $0.identifier == "composer-bar" }?.frame.minY ?? .infinity
        let keyboard = first { $0.elementType == .keyboard }?.frame.minY ?? .infinity
        return min(composer, keyboard)
    }
}
