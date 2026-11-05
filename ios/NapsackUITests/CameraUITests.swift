import XCTest

/// A pic from inside a chat, to that chat and more (as on the web): the
/// camera opened on a photo from the library (the Simulator has no camera),
/// "To <them> +" beside Send opens Send to… with the chat picked, another
/// friend is added, and both get it. In chats of their own, so the chat the
/// scrolling tests read stays as it was.
extension ChatUITests {
    func testAPicFromAChatGoesToMoreChats() async throws {
        let chat = try XCTUnwrap(Self.chat)
        let here = try await chat.server.newAccount("here"), also = try await chat.server.newAccount("also")
        try await chat.server.befriend(chat.me, here)
        try await chat.server.befriend(chat.me, also)
        try openChat(Chat(server: chat.server, me: chat.me, friend: here, newest: ""))

        app.buttons["Send a photo"].firstMatch.tap()
        try pickALibraryPhoto()

        // On the photo: who it's going to, with a + to add more, and Send beside it.
        let who = app.buttons["Sending to \(here.username). Add more people or groups"]
        try require(who.waitForExistence(timeout: 15), "the camera, opened on the photo, says who it's for")
        try require(app.buttons["Send"].exists, "Send beside it")
        shot("camera-from-a-chat")

        who.tap()
        try require(app.navigationBars["Send to 1"].waitForExistence(timeout: 10), "Send to…, with this chat picked")
        let other = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", also.username)).firstMatch
        try require(other.waitForExistence(timeout: 10), "the other friend is offered")
        other.tap()
        try require(app.navigationBars["Send to 2"].waitForExistence(timeout: 5), "both picked")
        shot("send-to-from-a-chat")
        app.navigationBars.buttons["Send"].tap()

        let note = app.staticTexts["Pic sent to \(here.username) and 1 more."]
        try require(note.waitForExistence(timeout: 20), "the camera closed, and a note says where it went")
        try require(composer.exists, "back in the chat")
        shot("sent-from-a-chat-to-more")

        // Each has their own copy, from the chat with me.
        for person in [here, also] {
            let got = try await chat.server.request("chats/\(chat.me.id)/messages", token: person.token)
            let messages = (got as? [[String: Any]]) ?? ((got as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            XCTAssertEqual(messages.filter { $0["kind"] as? String == "snap" }.count, 1, "\(person.username) got the pic, once")
        }
    }

    /// In iOS's photo picker (out of the app's process, but on its screen): the
    /// first of the Simulator's photos. Its grid's pictures, not the smaller
    /// images around them (the Photos icon in its note about private access).
    /// Read from snapshots of the screen, and tapped where it settled: the
    /// picker redraws its grid as it opens, and an element found by its place
    /// in the grid can be gone by the time it's tapped (iOS 26).
    func pickALibraryPhoto() throws {
        var frame: CGRect?
        try require(poll(20) { screen in
            let height = screen.root.frame.height
            let now = screen.first { $0.elementType == .image && $0.frame.width >= 80 && $0.frame.height >= 80
                && $0.frame.minY >= 0 && $0.frame.maxY <= height }?.frame
            defer { frame = now }
            return now != nil && now == frame  // in the same place twice: settled
        }, "the photo picker showed the Simulator's photos")
        let photo = try XCTUnwrap(frame)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: photo.midX, dy: photo.midY)).tap()
    }
}
