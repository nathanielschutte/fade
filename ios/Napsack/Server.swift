import Foundation
import Network
import NapsackCrypto
import Synchronization

/// Who this app is to a server. Every request says `X-Napsack-Client:
/// ios/<version>+<build>`, so the server can turn away an app older than it
/// supports (docs/operations/releasing.md, rule 4).
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    static var clientHeader: String { "ios/\(version)+\(build)" }
    /// The one server this build talks to: `NAPSACK_SERVER_URL` in the build
    /// settings (Config/Base.xcconfig, or your Local.xcconfig). Nothing in the
    /// app changes it. A Debug build launched with `NAPSACK_UI_TEST_SERVER` in its
    /// environment uses that instead: the UI tests (NapsackUITests) point it
    /// at their own server that way. Release builds never read it (compiled
    /// out, and scripts/test-ios.sh checks).
    static let server: String = {
        #if DEBUG
        if let launched = ProcessInfo.processInfo.environment["NAPSACK_UI_TEST_SERVER"], !launched.isEmpty { return launched }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "NapsackServerURL") as? String ?? ""
    }()

    #if DEBUG
    /// A Debug build launched with `NAPSACK_FRESH_START` starts as if just
    /// installed: no session, no pinned keys, no kept chats, no settings (the
    /// Face ID lock among them, which would cover the app). The UI tests ask
    /// for it, because their server is new each run and gives out the same
    /// account ids again, so keys pinned last run would read as changed ones.
    /// Release builds never read it (compiled out, and scripts/test-ios.sh checks).
    static func freshStartIfAsked() {
        guard ProcessInfo.processInfo.environment["NAPSACK_FRESH_START"] == "1" else { return }
        PhoneData.phone.forget()  // what signing out forgets: all of it
    }
    #endif

    /// Shown outside production (in production, nothing says where the app talks to).
    static func serverLabel(environment: String?, server: String = server) -> String? {
        guard let url = URL(string: server) else { return server }
        if environment == nil && url.scheme == "https" { return nil }  // production
        let host = url.host() ?? server
        return environment.map { "\(host) (\($0))" } ?? host
    }
}

/// GET /api/config: what a client needs before signing in (docs/spec/api.md).
struct ServerConfig: Decodable, Equatable {
    let serverVersion: String
    let build: String
    let apiVersion: Int
    let environment: String?
    let inviteRequired: Bool
    let messageFormats: [Int]
    /// Servers before 0.42.0 don't say.
    let groupMessageFormats: [Int]?
    let minClientVersions: [String: String]
    /// The largest pic and video the server takes (sealed), and the longest video.
    let snapMaxBytes: Int?
    let videoMaxBytes: Int?
    let videoMaxSeconds: Int?
    /// The site's address, for links people share (the app talks to the API
    /// on its own name, api.napsack.io). Null in development; servers before 0.47.0 don't say.
    let siteUrl: String?
    /// The site passkeys are made for here (napsack.io; "localhost" in
    /// development). Servers from before passkeys don't say (Passkeys.swift).
    let passkeyRpId: String?

    static func decode(_ data: Data) throws -> ServerConfig {
        try Server.decoder.decode(ServerConfig.self, from: data)
    }

    /// The oldest iOS app this server still serves, if it has a minimum.
    var minimumIOS: String? { minClientVersions["ios"] }
}

/// The signed-in person as they see themselves (`GET /api/me`, and in a sign-in's answer).
struct Me: Codable, Equatable, Sendable {
    let id: Int64
    let username: String
    let displayName: String?
    /// "user", "power", or "admin" (roles.md); the server checks it on every request.
    let role: String
    let hasRecoveryKey: Bool
    /// Your profile picture, if you have one (Settings). Older kept accounts lack it.
    var avatarId: Int64? = nil
    /// Friends see when you're active or typing, and you see theirs (mutual).
    var shareActivity: Bool? = nil

    var isAdmin: Bool { role == "admin" }
    /// PowerUser, PowerXtreme (the same, for now), or Admin.
    var isPowerUser: Bool { role == "power" || role == "powerxtreme" || isAdmin }
}

/// What `POST /api/auth/login` (and later register) answers.
struct SessionResponse: Decodable {
    let token: String
    let user: Me
    let publicKey: String
    let wrappedPrivateKey: String
}

/// What went wrong, in words for the person (the web app's, where it has them).
enum ServerError: LocalizedError, Equatable {
    case badAddress
    case unreachable
    /// The server said no, in its own words (`{"error": "..."}`).
    case refused(String, status: Int)
    case sessionEnded
    case updateRequired(String)

    var errorDescription: String? {
        switch self {
        case .badAddress: "That isn't a server address. Try one like https://staging.napsack.io."
        case .unreachable: "Can't reach the server. Check your connection."
        case .refused(let message, _): message
        case .sessionEnded: "Your session ended. Sign in again."
        case .updateRequired(let message): message
        }
    }

    /// The connection's fault, not the request's: worth trying again (app.js, `retryable`).
    var retryable: Bool {
        switch self {
        case .unreachable: true
        case .refused(_, let status): [502, 503, 504].contains(status)
        default: false
        }
    }
}

/// How requests go out: URLSession in the app, a stand-in in tests.
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// How far a request has got: bytes sent and received, of how many (0 when not known).
struct Transfer: Equatable, Sendable {
    var sent: Int64 = 0
    var toSend: Int64 = 0
    var received: Int64 = 0
    var toReceive: Int64 = 0

    /// How much of the answer has come, once its size is known.
    var receivedPart: Double? { toReceive > 0 ? min(1, Double(received) / Double(toReceive)) : nil }
}

/// Whoever's watching the requests made under it (a pic opening or on its
/// way) hears how far each has got as it moves (NetworkTransport; a stand-in
/// transport in tests says it itself).
enum TransferWatch {
    @TaskLocal static var watcher: (@Sendable (Transfer) -> Void)?
}

struct NetworkTransport: Transport {
    /// The app's connection to napsack: ephemeral, with no cache and no
    /// cookies, so nothing of an account's requests is ever written to the
    /// phone by the system (signing out has nothing of it to clear). Every
    /// request shares it, and its connection to the server, until that goes
    /// bad (`renew`).
    static var session: URLSession { connection.current }

    /// The session, replaced when its connection goes bad (D26). A
    /// connection can die without either end hearing (a weak Wi-Fi, a switch
    /// to cellular), and every request after queues on it until it times
    /// out: trying again would wait on the same dead one, and only quitting
    /// napsack made a new one. So a request that fails for the connection's
    /// sake, or is given up after a few seconds, retires it, and so does a
    /// change of network: the requests after go out on a new connection, and
    /// those still going on the old one finish.
    final class Connection: Sendable {
        private struct State {
            var session: URLSession
            var renewedAt: ContinuousClock.Instant?
            var renewals = 0
        }
        private let state: Mutex<State>
        /// Not again sooner than this: one bad moment fails several requests at once.
        static let calm: Duration = .seconds(2)
        /// Posted when it's been replaced: the live connection checks it's still alive (Live).
        static let renewed = Notification.Name("napsack.connectionRenewed")

        init() {
            state = Mutex(State(session: Self.make()))
        }

        var current: URLSession { state.withLock { $0.session } }
        /// How many times it's been replaced (tests).
        var renewals: Int { state.withLock { $0.renewals } }

        /// A new connection for the requests from now on. False if one was made a moment ago.
        @discardableResult func renew(_ why: String) -> Bool {
            let old = state.withLock { s -> URLSession? in
                if let at = s.renewedAt, ContinuousClock.now - at < Self.calm { return nil }
                let old = s.session
                s.session = Self.make()
                s.renewedAt = .now
                s.renewals += 1
                return old
            }
            guard let old else { return false }
            old.finishTasksAndInvalidate()  // what's still going on it finishes
            NotificationCenter.default.post(name: Self.renewed, object: nil)
            Task { await Reporter.shared.report(.info, "new connection", ["why": why]) }
            return true
        }

        static func make() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: config)
        }
    }

    static let connection: Connection = {
        let connection = Connection()
        NetworkChanges.shared.start { connection.renew("network changed") }
        return connection
    }()

    /// The app's, or one of a test's own.
    var connection: Connection = NetworkTransport.connection

    /// The connection's fault, not the request's: a new connection may well do better.
    static func connectionFault(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .secureConnectionFailed, .cannotLoadFromNetwork, .dataNotAllowed,
         .internationalRoamingOff, .callIsActive].contains(error.code)
    }

    /// A request given up after this long (a deadline, a pic closed while it
    /// opened) was likely stuck on its connection, not just unwanted.
    static let givenUpSlow: Duration = .seconds(3)

    /// Whether a request that ended in `error` after `took` should retire the connection.
    static func retires(_ error: any Error, took: Duration) -> Bool {
        if let error = error as? URLError {
            return connectionFault(error) || (error.code == .cancelled && took >= givenUpSlow)
        }
        return error is CancellationError && took >= givenUpSlow
    }

    #if DEBUG
    /// `NAPSACK_UI_TEST_SLOW_OLDER`: milliseconds each page before the newest takes (UI tests only;
    /// compiled out of Release builds).
    static let slowOlder = ProcessInfo.processInfo.environment["NAPSACK_UI_TEST_SLOW_OLDER"].flatMap { Int($0) }
    #endif

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if DEBUG
        // UI tests: older pages as slow as a phone far from the server (ChatUITests).
        if let ms = Self.slowOlder, request.url?.query?.contains("before=") == true { try await Task.sleep(for: .milliseconds(ms)) }
        #endif
        let started = ContinuousClock.now
        let response: URLResponse, data: Data
        do {
            if let watcher = TransferWatch.watcher {
                (data, response) = try await Self.watched(request, on: connection.current, watcher)
            } else {
                (data, response) = try await connection.current.data(for: request)
            }
        } catch {
            if Self.retires(error, took: ContinuousClock.now - started) {
                connection.renew((error as? URLError)?.code == .cancelled || error is CancellationError ? "request given up" : "request failed")
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw ServerError.unreachable }
        return (data, http)
    }

    /// The request, telling `watcher` how far it's got a few times a second, whenever that changes.
    private static func watched(_ request: URLRequest, on session: URLSession,
                                _ watcher: @escaping @Sendable (Transfer) -> Void) async throws -> (Data, URLResponse) {
        let tracker = TaskTracker()
        let watching = Task {
            var last = Transfer()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let now = tracker.transfer, now != last else { continue }
                last = now
                watcher(now)
            }
        }
        defer { watching.cancel() }
        let answer = try await session.data(for: request, delegate: tracker)
        if let done = tracker.transfer { watcher(done) }  // its answer came: that's moving too, however quick
        return answer
    }

    /// Learns which task a request became, to read how far it's got.
    private final class TaskTracker: NSObject, URLSessionTaskDelegate, Sendable {
        private let task = Mutex<URLSessionTask?>(nil)

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            self.task.withLock { $0 = task }
        }

        var transfer: Transfer? {
            task.withLock { task in
                task.map { Transfer(sent: $0.countOfBytesSent, toSend: max(0, $0.countOfBytesExpectedToSend),
                                    received: $0.countOfBytesReceived, toReceive: max(0, $0.countOfBytesExpectedToReceive)) }
            }
        }
    }
}

/// Changes of network (Wi-Fi to cellular, back online): a connection made
/// on the old one may be dead (NetworkTransport.Connection).
final class NetworkChanges: Sendable {
    static let shared = NetworkChanges()
    private let monitor = NWPathMonitor()
    /// What the network was last: which interfaces, and whether it worked.
    private let last = Mutex<String?>(nil)

    func start(_ changed: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [self] path in
            let now = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
            let before = last.withLock { l in defer { l = now }; return l }
            // The first is how it is at the start, not a change.
            if let before, before != now, path.status == .satisfied { changed() }
        }
        monitor.start(queue: DispatchQueue(label: "napsack.network-changes", qos: .utility))
    }
}

struct Server: Sendable {
    let base: URL
    let transport: any Transport

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    init(_ address: String, transport: any Transport = NetworkTransport()) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw ServerError.badAddress
        }
        base = url
        self.transport = transport
    }

    /// The address as it's kept and shown.
    var address: String { base.absoluteString }

    func request(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil, query: [URLQueryItem] = []) -> URLRequest {
        var url = base.appending(path: "api").appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(AppInfo.clientHeader, forHTTPHeaderField: "X-Napsack-Client")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.timeoutInterval = 20
        return request
    }

    /// Sends a request and returns the body of a successful answer; anything
    /// else becomes a ServerError. A 401 on a signed-in request (not signing
    /// in itself) means the session is over.
    func send(_ path: String, method: String = "GET", token: String? = nil, json: (any Encodable)? = nil, query: [URLQueryItem] = []) async throws -> Data {
        let body = try json.map { try Self.encoder.encode($0) }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request(path, method: method, token: token, body: body, query: query))
        } catch let error as ServerError {
            throw error
        } catch {
            throw ServerError.unreachable
        }
        switch response.statusCode {
        case 200..<300:
            return data
        case 401 where token != nil && !path.hasPrefix("auth/"):
            throw ServerError.sessionEnded
        case let status:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            if status == 426 {
                throw ServerError.updateRequired(message ?? "This version of napsack is too old for the server. Update it to keep going.")
            }
            throw ServerError.refused(message ?? "Request failed (\(status)).", status: status)
        }
    }

    /// Sends raw bytes (a picture, sealed or not): the same answers as `send`.
    func upload(_ path: String, data: Data, contentType: String, token: String,
                query: [URLQueryItem] = [], headers: [String: String] = [:]) async throws -> Data {
        var req = request(path, method: "POST", token: token, query: query)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        req.httpBody = data
        let body: Data, response: HTTPURLResponse
        do {
            (body, response) = try await transport.send(req)
        } catch {
            throw ServerError.unreachable
        }
        switch response.statusCode {
        case 200..<300: return body
        case 401: throw ServerError.sessionEnded
        case let status:
            let message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
            throw ServerError.refused(message ?? "Request failed (\(status)).", status: status)
        }
    }

    func config() async throws -> ServerConfig {
        try ServerConfig.decode(await send("config"))
    }

    struct Login: Encodable {
        let username: String
        let authKey: String
    }

    func login(username: String, authKey: String) async throws -> SessionResponse {
        try Self.decoder.decode(SessionResponse.self, from: await send("auth/login", method: "POST", json: Login(username: username, authKey: authKey)))
    }

    func me(token: String) async throws -> Me {
        try Self.decoder.decode(Me.self, from: await send("me", token: token))
    }

    /// The chat list: friends, each with the newest message between you.
    /// `tz` is minutes east of UTC, for counting streak days.
    func friends(token: String) async throws -> [Friend] {
        let tz = URLQueryItem(name: "tz", value: String(TimeZone.current.secondsFromGMT() / 60))
        return try Self.decoder.decode([Friend].self, from: await send("friends", token: token, query: [tz]))
    }

    func groups(token: String) async throws -> [GroupSummary] {
        try Self.decoder.decode([GroupSummary].self, from: await send("groups", token: token))
    }

    /// A direct chat's messages, oldest first: the newest `limit`, or those before `before`.
    func directMessages(friend: Int64, before: Int64?, limit: Int, token: String) async throws -> [DirectMessage] {
        try Self.decoder.decode([DirectMessage].self, from: await send(
            "chats/\(friend)/messages", token: token, query: Self.page(before: before, limit: limit)))
    }

    func groupMessages(group: Int64, before: Int64?, limit: Int, token: String) async throws -> [GroupMessage] {
        try Self.decoder.decode([GroupMessage].self, from: await send(
            "groups/\(group)/messages", token: token, query: Self.page(before: before, limit: limit)))
    }

    struct DirectText: Encodable {
        let ciphertext: String
        let format: Int
        let clientId: String
    }

    /// Sends a sealed text. The same `clientId` again returns the message already stored.
    func sendText(to friend: Int64, ciphertext: String, clientId: String, token: String) async throws -> DirectMessage {
        try Self.decoder.decode(DirectMessage.self, from: await send(
            "chats/\(friend)/messages", method: "POST", token: token,
            json: DirectText(ciphertext: ciphertext, format: E2E.textFormat, clientId: clientId)))
    }

    struct GroupDetail: Decodable, Sendable {
        struct Member: Decodable, Sendable {
            let id: Int64
            let username: String
            let publicKey: String
        }
        let members: [Member]
    }

    func group(_ id: Int64, token: String) async throws -> GroupDetail {
        try Self.decoder.decode(GroupDetail.self, from: await send("groups/\(id)", token: token))
    }

    struct GroupText: Encodable {
        let format: Int
        let content: String
        let clientId: String
        let recipients: [Int64]
        let wraps: [String: String]
    }

    /// Sends a sealed group text; 409 if the members changed since it was sealed.
    func sendGroupText(to group: Int64, _ sealed: E2E.GroupMessage, token: String) async throws -> GroupMessage {
        try Self.decoder.decode(GroupMessage.self, from: await send(
            "groups/\(group)/messages", method: "POST", token: token,
            json: GroupText(format: E2E.groupFormat, content: E2E.toB64(sealed.content), clientId: sealed.clientId,
                            recipients: sealed.recipients, wraps: Dictionary(uniqueKeysWithValues: sealed.wraps.map { (String($0.key), $0.value) }))))
    }

    /// A direct reaction, encrypted; nil takes mine back.
    func react(to message: Int64, friend: Int64, ciphertext: String?, token: String) async throws -> DirectMessage {
        struct Reaction: Encodable {
            let ciphertext: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(ciphertext, forKey: .ciphertext)  // null, not left out: it takes the reaction back
                try c.encode(E2E.textFormat, forKey: .format)
            }
            enum CodingKeys: String, CodingKey { case ciphertext, format }
        }
        return try Self.decoder.decode(DirectMessage.self, from: await send(
            "chats/\(friend)/messages/\(message)/reaction", method: "PUT", token: token, json: Reaction(ciphertext: ciphertext)))
    }

    /// A group reaction, one of the fixed set (not encrypted); nil takes mine back.
    func react(to message: Int64, group: Int64, emoji: String?, token: String) async throws -> GroupMessage {
        struct Reaction: Encodable {
            let emoji: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(emoji, forKey: .emoji)
            }
            enum CodingKeys: String, CodingKey { case emoji }
        }
        return try Self.decoder.decode(GroupMessage.self, from: await send(
            "groups/\(group)/messages/\(message)/reaction", method: "PUT", token: token, json: Reaction(emoji: emoji)))
    }

    /// New words for my text, sealed with the edit's associated data.
    func editText(_ message: Int64, friend: Int64, ciphertext: String, clientId: String, token: String) async throws -> DirectMessage {
        try Self.decoder.decode(DirectMessage.self, from: await send(
            "chats/\(friend)/messages/\(message)/edit", method: "PUT", token: token,
            json: DirectText(ciphertext: ciphertext, format: E2E.textFormat, clientId: clientId)))
    }

    /// New words for my group text, sealed for the text's own member list.
    func editGroupText(_ message: Int64, group: Int64, _ sealed: E2E.GroupMessage, token: String) async throws -> GroupMessage {
        try Self.decoder.decode(GroupMessage.self, from: await send(
            "groups/\(group)/messages/\(message)/edit", method: "PUT", token: token,
            json: GroupText(format: E2E.groupFormat, content: E2E.toB64(sealed.content), clientId: sealed.clientId,
                            recipients: sealed.recipients, wraps: Dictionary(uniqueKeysWithValues: sealed.wraps.map { (String($0.key), $0.value) }))))
    }

    static func page(before: Int64?, limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit))] + (before.map { [URLQueryItem(name: "before", value: String($0))] } ?? [])
    }

    /// `chats/{friend}/read` or `groups/{id}/read`.
    func markRead(path: String, token: String) async throws {
        _ = try await send(path, method: "POST", token: token)
    }

    /// Ends this session on the server (the token stops working).
    func logout(token: String) async throws {
        _ = try await send("auth/logout", method: "POST", token: token)
    }

    /// This iPhone's notification token, for this session (the server's apns.rs).
    func registerAPNs(token deviceToken: String, environment: String, auth: String) async throws {
        _ = try await send("push/apns", method: "POST", token: auth, json: ["token": deviceToken, "environment": environment])
    }
}

/// App versions compared the way the server compares them (server/src/version.rs,
/// `Semver`): numbers, dot by dot (1.10.0 is newer than 1.9.0); a "-pre" or
/// "+build" suffix doesn't count.
enum ClientVersion {
    static func isOlder(_ version: String, than minimum: String) -> Bool {
        let parts = { (v: String) in
            v.split(whereSeparator: { $0 == "+" || $0 == "-" }).first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(version), b = parts(minimum)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}
