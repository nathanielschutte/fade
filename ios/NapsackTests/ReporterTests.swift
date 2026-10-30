import Foundation
import Testing
@testable import Napsack

/// The app's reports to the log viewer: batched, sent as whoever's signed in,
/// and never anything but ids, statuses, and error wording.
@MainActor @Suite struct ReporterTests {
    func reporter(_ server: StubServer) -> Reporter {
        let reporter = Reporter(transport: server)
        reporter.use(server: "https://napsack.test", token: "t")
        return reporter
    }

    @Test func entriesGoFiftyAtATimeAsTheAccount() async throws {
        let server = StubServer { _ in (204, Data()) }
        let reporter = reporter(server)
        for n in 0..<60 { reporter.report(.info, "socket closed", ["retry": String(n)]) }
        await reporter.flush()
        let sent = await server.requests
        #expect(sent.count == 2 && sent.allSatisfy { $0.url!.path == "/api/logs" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer t" })
        let first = try #require(body(sent[0])["entries"] as? [[String: Any]])
        #expect(first.count == 50 && first[0]["level"] as? String == "info" && first[0]["message"] as? String == "socket closed")
        #expect((first[0]["fields"] as? [String: String])?["retry"] == "0")
        #expect((body(sent[1])["entries"] as? [Any])?.count == 10 && reporter.queue.isEmpty)
        // The app says who it is, so the viewer shows "ios app".
        #expect(sent[0].value(forHTTPHeaderField: "X-Napsack-Client")?.hasPrefix("ios/") == true)
    }

    @Test func anErrorGoesSoonAndOfflineDropsThem() async throws {
        let server = StubServer { _ in throw URLError(.notConnectedToInternet) }
        let reporter = reporter(server)
        reporter.delays = (.zero, .seconds(60))
        for _ in 0..<(Reporter.kept + 5) { reporter.report(.debug, "socket closed") }
        #expect(reporter.queue.count == Reporter.kept)  // the oldest go
        reporter.report(.error, "unlocking the private key failed")
        await reporter.flush()  // (what the error's timer does, half a second on)
        #expect(reporter.queue.isEmpty)  // offline: dropped, not piled up
        #expect(await server.requests.count == 1)
    }

    @Test func anErrorBecomesItsWordsAndStatus() {
        let fields = Reporter.fields(ServerError.refused(String(repeating: "x", count: 400), status: 409), ["group": "true"])
        #expect(fields["status"] == "409" && fields["error"]?.count == 300 && fields["group"] == "true")
        #expect(Reporter.fields(ServerError.unreachable)["status"] == nil)
    }

    @Test func signedOutReportsGoWithoutAToken() async throws {
        let server = StubServer { _ in (401, json(["error": "Wrong username or password."])) }
        let reporter = Reporter(transport: server)
        let session = Session(transport: server, store: MemoryStore(), reporter: reporter)
        await #expect(throws: (any Error).self) {
            try await session.signIn(server: "https://napsack.test", username: "nobody", password: "wrong password")
        }
        #expect(reporter.queue.map(\.message) == ["sign in failed"] && reporter.queue[0].fields["status"] == "401")
        await reporter.flush()
        let sent = try #require(await server.requests.last)
        #expect(sent.url!.path == "/api/logs" && sent.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
