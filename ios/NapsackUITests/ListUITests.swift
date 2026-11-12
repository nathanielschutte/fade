import UIKit
import XCTest

/// From the chat list (Nate, 2026-11-12): a pic waiting from a friend opens
/// with a tap, counts as opened the moment it's shown (D27), and closes on its
/// own when its time is up (X58), leaving you on the list; a double tap on a
/// chat opens the camera for it, and what's sent there goes to that chat
/// while the list stays (X60). Each with a friend of its own, so the chat the
/// scrolling tests read stays as it was.
extension ChatUITests {
    func testAPicFromTheListClosesOnItsOwn() async throws {
        let chat = try XCTUnwrap(Self.chat)
        let pal = try await chat.server.newAccount("timer")
        try await chat.server.befriend(chat.me, pal)
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { c in
            UIColor.systemOrange.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        try await chat.server.sendPic(try XCTUnwrap(photo.jpegData(compressionQuality: 0.8)), from: pal, to: chat.me)
        try onTheList(Chat(server: chat.server, me: chat.me, friend: pal, newest: ""))

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", pal.username)).firstMatch
        try require(waitUntil(15) { row.exists && row.label.contains("New pic") }, "their row says a pic is waiting")
        row.tap()
        let viewer = app.descendants(matching: .any).matching(identifier: "pic-viewer").firstMatch
        try require(viewer.waitForExistence(timeout: 15), "the pic opened from the list")
        shot("pic-from-the-list-running")

        // Its 10 seconds, then gone by itself, back on the list, which already says it was viewed.
        let opened = Date()
        try require(waitUntil(20) { !viewer.exists }, "it closed on its own")
        XCTAssertGreaterThan(Date().timeIntervalSince(opened), 8, "after its time, not before")
        try require(app.navigationBars["Chats"].exists, "still on the list")
        try require(waitUntil(5) { row.label.contains("Pic viewed") }, "the row says it was viewed")
    }

    func testDoubleTapAChatToSendItAPic() async throws {
        let chat = try XCTUnwrap(Self.chat)
        let pal = try await chat.server.newAccount("reply")
        try await chat.server.befriend(chat.me, pal)
        try await chat.server.send("Send me one", from: pal, to: chat.me)
        try onTheList(Chat(server: chat.server, me: chat.me, friend: pal, newest: ""))

        app.staticTexts[pal.username].doubleTap()
        let library = app.buttons["Choose a photo"]
        try require(library.waitForExistence(timeout: 10), "a double tap opens the camera")
        try require(app.navigationBars["Chats"].exists || !app.staticTexts["Send me one"].isHittable, "not the chat")
        library.tap()
        try pickALibraryPhoto()
        let who = app.buttons["Sending to \(pal.username). Add more people or groups"]
        try require(who.waitForExistence(timeout: 15), "the camera says who it's for: that chat")
        shot("double-tap-camera")
        app.buttons["Send"].tap()

        // The camera closes; the list says where it's going, and it gets there.
        try require(app.staticTexts["Sending your pic to \(pal.username)."].waitForExistence(timeout: 10), "back on the list, with a note")
        try require(app.navigationBars["Chats"].exists, "on the list, not in the chat")
        var snaps = 0
        let until = Date().addingTimeInterval(30)
        while snaps == 0, Date() < until {
            let got = try await chat.server.request("chats/\(chat.me.id)/messages", token: pal.token)
            snaps = ((got as? [[String: Any]]) ?? []).filter { $0["kind"] as? String == "snap" }.count
            if snaps == 0 { try await Task.sleep(for: .milliseconds(200)) }
        }
        XCTAssertEqual(snaps, 1, "they got the pic, once")

        // A single tap still opens the chat.
        app.staticTexts[pal.username].tap()
        try require(composer.waitForExistence(timeout: 10), "a tap opens the chat")
    }
}
