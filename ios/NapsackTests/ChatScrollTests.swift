import CryptoKit
import Foundation
import NapsackCrypto
import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// The open chat on a real screen (a window in the app the tests run in),
/// against a stand-in server: the scroll view's own numbers say where it is.
/// The vectors' people: I'm Bob (3), Alice (7) a friend.
@MainActor final class ChatOnScreen {
    let list = try! ChatListTests()
    let window: UIWindow
    let conversation: Conversation
    /// What the server holds, oldest first.
    private let messages: Messages

    final class Messages: @unchecked Sendable {
        let lock = NSLock()
        var all: [[String: Any]] = []
    }

    /// `text`: the text size it's drawn at; `words`: each text's words, by its number (from 1).
    init(texts: Int, size: CGSize = CGSize(width: 402, height: 874), insets: UIEdgeInsets? = nil, text: DynamicTypeSize = .large,
         words: ((Int) -> String)? = nil) async throws {
        let list = self.list
        let key = try list.pairKey
        messages = Messages()
        for n in 1...texts {
            let mine = n % 3 == 0
            let words = words?(n) ?? (n % 7 == 0 ? "Message \(n).\nA second line.\nAnd a third." : "Message \(n).")
            let sealed = try E2E.encryptText2(key, words, replyTo: nil, sender: mine ? 3 : 7, recipient: mine ? 7 : 3)
            var m = list.message(from: mine ? 3 : 7, to: mine ? 7 : 3, ciphertext: sealed, format: 2, id: Int64(n))
            m["created_at"] = 1_793_300_000 + n
            messages.all.append(m)
        }
        let messages = self.messages
        let server = StubServer { request in
            if request.httpMethod == "POST" { return (200, json(["ok": true])) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let limit = Int(items.first { $0.name == "limit" }?.value ?? "") ?? 50
            let before = Int64(items.first { $0.name == "before" }?.value ?? "") ?? .max
            let page = messages.lock.withLock { messages.all.filter { ($0["id"] as! Int64) < before }.suffix(limit) }
            return (200, json(Array(page)))
        }
        let me = list.reader.me
        let account = Account(server: "https://napsack.test", token: "t", user: me, publicKey: list.bob["spki"] as! String,
                              privateKey: list.reader.identity.derRepresentation)
        conversation = Conversation(.friend(list.reader.friends[7]!), account: account, reader: list.reader, transport: server)
        conversation.retryDelays = [.zero, .zero]
        let session = Session(transport: server, store: MemoryStore(account))
        await session.restore(server: "https://napsack.test")
        let live = Live(account: account)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let screen = NavigationStack { ChatScreen(conversation: conversation) }.environment(session).environment(live)
            .environment(\.dynamicTypeSize, text)
        let host = UIHostingController(rootView: screen)
        window.rootViewController = host
        window.makeKeyAndVisible()
        if let insets {  // as Hosted does: a phone's safe area, past the Simulator's own
            window.layoutIfNeeded()
            let own = window.safeAreaInsets
            host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, insets.top - own.top), left: 0,
                                                         bottom: max(0, insets.bottom - own.bottom), right: 0)
        }
        try await until("the chat loaded") { self.conversation.loaded && self.scroll != nil }
        await settle()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    // ---------- the scroll view's numbers ----------

    var scroll: UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if let s = view as? UIScrollView, s.bounds.height > 300, !(s is UITextView) { return s }
            for sub in view.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return find(window)
    }

    /// How far the newest content is below the bottom of what can be seen (0 at the bottom).
    var belowBottom: CGFloat {
        guard let s = scroll else { return .nan }
        return s.contentSize.height + s.adjustedContentInset.bottom - s.bounds.height - s.contentOffset.y
    }

    var describe: String {
        guard let s = scroll else { return "no scroll view" }
        return "offset \(s.contentOffset.y) content \(s.contentSize.height) insets \(s.adjustedContentInset.top)/\(s.adjustedContentInset.bottom) bounds \(s.bounds.height) below \(belowBottom)"
    }

    /// Lets layout and any scrolling finish: nothing changes for a few frames.
    func settle() async {
        var last = describe, same = 0
        for _ in 0..<200 where same < 6 {
            try? await Task.sleep(for: .milliseconds(16))
            let now = describe
            same = now == last ? same + 1 : 0
            last = now
        }
    }

    /// The window as it is, into NAPSACK_SHOTS (a folder on the Mac) when that's set, to look at.
    func shoot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["NAPSACK_SHOTS"], !folder.isEmpty else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
    }

    // ---------- what happens in the chat ----------

    func theyNewMessage(_ n: Int) throws {
        let key = try list.pairKey
        let sealed = try E2E.encryptText2(key, "Message \(n).", replyTo: nil, sender: 7, recipient: 3)
        var m = list.message(from: 7, to: 3, ciphertext: sealed, format: 2, id: Int64(n))
        m["created_at"] = 1_793_300_000 + n
        messages.lock.withLock { messages.all.append(m) }
        conversation.arrived(try ChatListTests.decode(DirectMessage.self, m))
    }

    func until(_ what: String, _ seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(16))
        }
    }
}

// Its windows take turns with the other suites' (Hosting.swift).
extension OnScreen {
@MainActor @Suite(.serialized) struct ChatScrollTests {
    /// At the bottom (where a chat opens), what comes below keeps the newest in
    /// sight: a new message and the typing line. On a small and a large phone.
    /// Scrolling away from the bottom needs a finger: NapsackUITests checks it.
    @Test(arguments: [CGSize(width: 375, height: 667), CGSize(width: 440, height: 956)])
    func atTheBottomTheNewestStaysInSight(size: CGSize) async throws {
        let chat = try await ChatOnScreen(texts: 60, size: size)
        defer { chat.close() }
        let name = "\(Int(size.width))x\(Int(size.height))"
        #expect(abs(chat.belowBottom) < 1, "opens on the newest: \(chat.describe)")
        chat.shoot("chat-open-\(name)")

        try chat.theyNewMessage(61)
        await chat.settle()
        #expect(abs(chat.belowBottom) < 1, "a new message at the bottom: \(chat.describe)")

        chat.conversation.typing(from: 7, group: nil)
        await chat.settle()
        #expect(abs(chat.belowBottom) < 1, "the typing line: \(chat.describe)")
        chat.shoot("chat-typing-\(name)")
    }

    /// The keyboard coming up while the content grows (a phone measuring its
    /// rows as it animates): the newest ends just above the keyboard, not a
    /// keyboard's height further (Nate, 2026-11-03: the chat scrolled off the top).
    @Test(arguments: [CGSize(width: 375, height: 667), CGSize(width: 440, height: 956)])
    func theKeyboardAndGrowthTogetherDontOvershoot(size: CGSize) async throws {
        let chat = try await ChatOnScreen(texts: 60, size: size)
        defer { chat.close() }
        let host = try #require(chat.window.rootViewController)
        host.additionalSafeAreaInsets.bottom = 300  // a keyboard
        try chat.theyNewMessage(61)
        await chat.settle()
        #expect(abs(chat.belowBottom) < 1, "the keyboard and a new message at once: \(chat.describe)")
        chat.shoot("chat-keyboard-growth-\(Int(size.width))")
    }

    /// Left past its end (a blank screen above the composer, however it came
    /// about), the chat goes back to its end as soon as nothing moves it.
    @Test func leftPastItsEndItGoesBack() async throws {
        let chat = try await ChatOnScreen(texts: 60)
        defer { chat.close() }
        let scroll = try #require(chat.scroll)
        scroll.contentOffset.y += 400
        await chat.settle()
        #expect(abs(chat.belowBottom) < 1, "pushed 400 points past the end: \(chat.describe)")
    }
}
}
