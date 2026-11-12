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
    /// Friends or requests changed (a friendship, a name, a picture, a mark): the friends list refetches.
    case friendsChanged
    /// A group changed (its name, members, your marks, or your reads on another device): the groups list refetches.
    case groupsChanged(Int64?)
    /// Someone's typing to you, or in a group (for a few seconds).
    case typing(from: Int64, group: Int64?)
    /// A friend came on screen or left (only friends who share it, and only if you do).
    case presence(user: Int64, active: Bool, lastSeenAt: Int64?)
    /// A friend read your texts up to `at`, or (`by` you) you read a chat on another device.
    case read(by: Int64, at: Int64)
    /// Someone in a group read up to a message.
    case groupRead(group: Int64, user: Int64, last: Int64)
    /// The Admins' announcement changed: a new one, or none.
    case announcement(ChatList.Announcement?)
    /// Anything else (visibility changes): not acted on.
    case other

    /// One pass over the frame, which can be a whole message with its ciphertext.
    static func decode(_ data: Data) -> LiveEvent {
        (try? Server.decoder.decode(Frame.self, from: data))?.event ?? .other
    }

    private struct Frame: Decodable {
        let event: LiveEvent

        // As the decoder sees them: snake_case on the wire, camelCase here.
        enum Keys: String, CodingKey { case type, message, groupId, from, userId, active, lastSeenAt, by, at, lastReadId, announcement }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "ready": event = .ready
            case "auth_failed": event = .authFailed
            case "pong": event = .pong
            case "message", "message_updated":
                event = (try? c.decode(DirectMessage.self, forKey: .message)).map { .message($0) } ?? .other
            case "group_message":
                event = (try? c.decode(GroupMessage.self, forKey: .message)).map { .groupMessage($0) } ?? .other
            case "announcement":
                do { event = .announcement(try c.decodeIfPresent(ChatList.Announcement.self, forKey: .announcement)) } catch { event = .other }
            case "typing":
                do { event = .typing(from: try c.decode(Int64.self, forKey: .from), group: try c.decodeIfPresent(Int64.self, forKey: .groupId)) } catch {
                    event = .other
                }
            case "presence":
                do {
                    event = .presence(user: try c.decode(Int64.self, forKey: .userId), active: try c.decode(Bool.self, forKey: .active),
                                      lastSeenAt: try c.decodeIfPresent(Int64.self, forKey: .lastSeenAt))
                } catch {
                    event = .other
                }
            case "read":
                // Unreadable: refetch the list, which is never wrong.
                do { event = .read(by: try c.decode(Int64.self, forKey: .by), at: try c.decode(Int64.self, forKey: .at)) } catch { event = .friendsChanged }
            case "group_read":
                do {
                    event = .groupRead(group: try c.decode(Int64.self, forKey: .groupId), user: try c.decode(Int64.self, forKey: .userId),
                                       last: try c.decode(Int64.self, forKey: .lastReadId))
                } catch {
                    event = .groupsChanged(nil)
                }
            case "friends_changed": event = .friendsChanged
            case "groups_changed": event = .groupsChanged(try? c.decodeIfPresent(Int64.self, forKey: .groupId))
            default: event = .other
            }
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
        // A request found the connection bad, or the network changed: the socket may be dead too.
        timers["renewed"] = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NetworkTransport.Connection.renewed) {
                guard let self, self.running else { return }
                self.checkAlive()
            }
        }
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
        let task = NetworkTransport.session.webSocketTask(with: request)
        self.task = task
        task.resume()
        send(["type": "auth", "token": account.token], on: task)
        Task.detached { await Self.listen(task, for: self) }
    }

    /// Frames as they come, each decoded once off the main thread, then handled
    /// on it in the order they came.
    nonisolated private static func listen(_ task: URLSessionWebSocketTask, for live: Live) async {
        while true {
            let event: LiveEvent
            do {
                switch try await task.receive() {
                case .string(let text): event = LiveEvent.decode(Data(text.utf8))
                case .data(let data): event = LiveEvent.decode(data)
                @unknown default: continue
                }
            } catch {
                await live.ended(task)
                return
            }
            guard await live.take(event, from: task) else { return }  // replaced meanwhile
        }
    }

    /// An event from `task`, handled if that's still the connection.
    private func take(_ event: LiveEvent, from task: URLSessionWebSocketTask) -> Bool {
        guard self.task === task else { return false }
        handle(event)
        return true
    }

    private func ended(_ task: URLSessionWebSocketTask) {
        if self.task === task, running { closed() }
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

    /// Tells a friend (or a group) you're typing. The caller keeps it to every couple of seconds.
    func sendTyping(to chat: ChatRow.Kind) {
        guard let task else { return }
        switch chat {
        case .friend(let id): send(["type": "typing", "to": id], on: task)
        case .group(let id): send(["type": "typing", "group": id], on: task)
        }
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
