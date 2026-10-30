import Foundation

/// What goes wrong on the phone, for the log viewer (`/admin#logs`, source "ios
/// app"), as the web app's `report()` does: batched, sent half a second after
/// an error or five seconds after anything else, up to 50 at a time, and sent
/// at once when the app leaves the screen. Only ids, counts, statuses, and
/// error wording: never message content, keys, tokens, or passwords
/// (CLAUDE.md, Logging). The server redacts content-like fields as a backstop;
/// don't rely on it.
@MainActor final class Reporter {
    static let shared = Reporter()

    enum Level: String, Encodable {
        case debug, info, warn, error
    }

    struct Entry: Encodable, Equatable {
        let level: Level
        let message: String
        let fields: [String: String]
    }

    static let batch = 50
    /// Beyond this, the oldest go: a phone offline for a long time shouldn't pile them up.
    static let kept = 200

    private(set) var queue: [Entry] = []
    /// Where entries go, and as whom (none while signed out: sign-in's own problems).
    private var server: String?
    private var token: String?
    private let transport: any Transport
    private var timer: Task<Void, Never>?
    var delays: (error: Duration, other: Duration) = (.milliseconds(500), .seconds(5))

    init(transport: any Transport = NetworkTransport()) {
        self.transport = transport
    }

    /// Whether reports go as an account.
    var signedIn: Bool { token != nil }

    /// Who's signed in now, or only the server, while signed out.
    func use(server: String?, token: String?) {
        self.server = server
        self.token = token
    }

    func report(_ level: Level, _ message: String, _ fields: [String: String] = [:]) {
        queue.append(Entry(level: level, message: message, fields: fields))
        if queue.count > Self.kept { queue.removeFirst(queue.count - Self.kept) }
        timer?.cancel()
        let delay = level == .error ? delays.error : delays.other
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Sends what's waiting, 50 at a time. Offline, they're dropped rather than kept.
    func flush() async {
        timer?.cancel()
        while !queue.isEmpty {
            guard let server, let api = try? Server(server, transport: transport) else { return }
            let entries = Array(queue.prefix(Self.batch))
            queue.removeFirst(entries.count)
            struct Batch: Encodable { let entries: [Entry] }
            do {
                _ = try await api.send("logs", method: "POST", token: token, json: Batch(entries: entries))
            } catch {
                queue.removeAll()
                return
            }
        }
    }

    /// An error as fields: its words (at most 300 characters) and the server's status, if any.
    static func fields(_ error: any Error, _ more: [String: String] = [:]) -> [String: String] {
        var fields = more
        fields["error"] = String(error.localizedDescription.prefix(300))
        if case ServerError.refused(_, let status) = error { fields["status"] = String(status) }
        return fields
    }
}
