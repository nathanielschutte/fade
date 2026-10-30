import Foundation

/// What the server says over the socket (docs/spec/api.md, WebSocket events),
/// as far as the app acts on it so far. The socket only says what changed;
/// the API is the truth, so anything missed while disconnected is fetched
/// again on the next `ready`.
enum LiveEvent: Sendable {
    /// Signed in on this socket: refetch everything shown.
    case ready
    case authFailed
    case pong
    /// A direct message, new or updated.
    case message(DirectMessage)
    /// A group message, new or updated.
    case groupMessage(GroupMessage)
    /// Friends, groups, or reads changed: the chat list refetches.
    case listChanged
    /// Typing, presence, announcements: not shown in the app yet.
    case other

    static func decode(_ data: Data) -> LiveEvent {
        struct Head: Decodable { let type: String }
        struct Direct: Decodable { let message: DirectMessage }
        struct Group: Decodable { let message: GroupMessage }
        guard let head = try? Server.decoder.decode(Head.self, from: data) else { return .other }
        switch head.type {
        case "ready": return .ready
        case "auth_failed": return .authFailed
        case "pong": return .pong
        case "message", "message_updated":
            return (try? Server.decoder.decode(Direct.self, from: data)).map { .message($0.message) } ?? .other
        case "group_message":
            return (try? Server.decoder.decode(Group.self, from: data)).map { .groupMessage($0.message) } ?? .other
        case "friends_changed", "groups_changed", "read", "group_read": return .listChanged
        default: return .other
        }
    }
}

/// The live connection while the app is on screen (app.js, `connectSocket`).
/// It signs in with the first frame, pings every 25 seconds and starts over
/// when no answer comes within 10 (a phone switching networks can drop a
/// socket without saying so), and reconnects after a drop, waiting a little
/// longer each time, up to 30 seconds.
@MainActor @Observable final class Live {
    /// The connection's been down more than a few seconds.
    private(set) var reconnecting = false
    /// Where events go.
    @ObservationIgnored var onEvent: (LiveEvent) -> Void = { _ in }
    /// The chat on screen, if any: its messages arrive here as they come.
    @ObservationIgnored weak var openChat: Conversation?

    private let account: Account
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]

    init(account: Account) {
        self.account = account
    }

    /// `ws://host/api/ws` for `http://host`, `wss://` for `https://`.
    static func socketURL(_ server: String) -> URL? {
        guard var parts = URLComponents(string: server), let scheme = parts.scheme else { return nil }
        parts.scheme = scheme == "https" ? "wss" : "ws"
        return parts.url?.appending(path: "api/ws")
    }

    /// On screen: connect (or check the connection is still alive).
    func start() {
        if running { return checkAlive() }
        running = true
        connect()
    }

    /// Off screen: the connection goes, and comes back with `start`.
    func stop() {
        running = false
        timers.values.forEach { $0.cancel() }
        timers = [:]
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        timers["retry"]?.cancel()
        timers["pong"]?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        guard let url = Self.socketURL(account.server) else { return }
        var request = URLRequest(url: url)
        request.setValue(AppInfo.clientHeader, forHTTPHeaderField: "X-Napsack-Client")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        send(["type": "auth", "token": account.token], on: task)
        Task { await receive(task) }
    }

    private func receive(_ task: URLSessionWebSocketTask) async {
        while true {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                if self.task === task, running { closed() }
                return
            }
            guard self.task === task else { return }  // replaced meanwhile
            switch frame {
            case .string(let text): handle(LiveEvent.decode(Data(text.utf8)))
            case .data(let data): handle(LiveEvent.decode(data))
            @unknown default: continue
            }
        }
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case .ready:
            retries = 0
            timers.removeValue(forKey: "banner")?.cancel()
            reconnecting = false
            if let task { send(["type": "visibility", "visible": true], on: task) }
            later("heartbeat", every: .seconds(25)) { $0.checkAlive() }
        case .pong:
            timers["pong"]?.cancel()
        case .authFailed:
            stop()
        default:
            break
        }
        onEvent(event)
    }

    /// Dropped: try again soon. A short blip passes unnoticed; a longer one shows.
    private func closed() {
        Reporter.shared.report(.debug, "socket closed", ["retry": String(retries)])
        task = nil
        timers["heartbeat"]?.cancel()
        timers["pong"]?.cancel()
        let delay = min(30, 1 << min(retries, 5))
        retries += 1
        later("retry", after: .seconds(delay)) { $0.connect() }
        if timers["banner"] == nil { later("banner", after: .seconds(4)) { $0.reconnecting = true } }
    }

    /// Pings; no answer within 10 seconds means start a new connection.
    func checkAlive() {
        guard running, let task else { return }
        send(["type": "ping"], on: task)
        later("pong", after: .seconds(10)) {
            Reporter.shared.report(.info, "socket unresponsive; reconnecting")
            $0.connect()
        }
    }

    private func send(_ frame: [String: any Sendable], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func later(_ name: String, after delay: Duration, _ run: @escaping @MainActor (Live) -> Void) {
        timers[name]?.cancel()
        timers[name] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.running else { return }
            run(self)
        }
    }

    private func later(_ name: String, every interval: Duration, _ run: @escaping @MainActor (Live) -> Void) {
        timers[name]?.cancel()
        timers[name] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.running else { return }
                run(self)
            }
        }
    }
}
