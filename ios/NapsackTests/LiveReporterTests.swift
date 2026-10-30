import Foundation
import Testing
@testable import Napsack

/// The app's reports reach the log viewer, as "ios app", against a real
/// napsack server. Needs an Admin to read the logs back: runs only with
/// NAPSACK_TEST_SERVER and NAPSACK_TEST_ADMIN (a username in the server's
/// FADE_ADMINS; it's signed up, or signed in if it exists, with the live tests' password).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil
                           && ProcessInfo.processInfo.environment["NAPSACK_TEST_ADMIN"] != nil), .timeLimit(.minutes(1)))
struct LiveReporterTests {
    let live = LiveChatListTests()

    @Test func reportsShowInTheLogViewerAsTheIOSApp() async throws {
        let admin = ProcessInfo.processInfo.environment["NAPSACK_TEST_ADMIN"]!
        let session = Session(store: MemoryStore(), reporter: Reporter())
        do {
            try await session.signUp(server: live.address, username: admin, password: "correct horse battery", inviteCode: live.invite)
        } catch {
            try await session.signIn(server: live.address, username: admin, password: "correct horse battery")
        }
        let account = try #require(session.account)
        #expect(account.user.isAdmin)

        let reporter = Reporter()
        reporter.use(server: account.server, token: account.token)
        let marker = "live check \(UUID().uuidString.prefix(8))"
        reporter.report(.warn, marker, ["friend_id": "7", "ciphertext": "must not show"])
        await reporter.flush()

        struct Entry: Decodable { let message: String; let target: String; let fields: [[String]]? }
        struct Page: Decodable { let entries: [Entry] }
        let found = try Server.decoder.decode(Page.self, from: await Server(account.server).send(
            "admin/logs", token: account.token, query: [URLQueryItem(name: "q", value: marker), URLQueryItem(name: "source", value: "client")]))
        let entry = try #require(found.entries.first { $0.message == marker })
        #expect(entry.target.hasSuffix("ios"))
        let fields = Dictionary(uniqueKeysWithValues: (entry.fields ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil })
        #expect(fields["friend_id"] == "7" && fields["user_id"] == String(account.user.id))
        #expect(fields["ciphertext"] == "[redacted]")  // the server's backstop
    }

    /// The Admins' announcement reaches the app's list (and is withdrawn after: it's everyone's).
    @Test func anAnnouncementReachesTheList() async throws {
        let admin = ProcessInfo.processInfo.environment["NAPSACK_TEST_ADMIN"]!
        let session = Session(store: MemoryStore(), reporter: Reporter())
        do {
            try await session.signUp(server: live.address, username: admin, password: "correct horse battery", inviteCode: live.invite)
        } catch {
            try await session.signIn(server: live.address, username: admin, password: "correct horse battery")
        }
        let account = try #require(session.account)
        struct Post: Encodable { let body: String; let hours: Int }
        struct Posted: Decodable { let announcement: ChatList.Announcement }
        let server = try Server(account.server)
        let text = "Live check \(UUID().uuidString.prefix(6))"
        let posted = try Server.decoder.decode(Posted.self, from: await server.send("admin/announcements", method: "POST", token: account.token,
                                                                                     json: Post(body: text, hours: 1)))
        defer { Task { _ = try? await server.send("admin/announcements/\(posted.announcement.id)/withdraw", method: "POST", token: account.token) } }
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(account)
        #expect(list.announcement?.body == text)
    }
}
