import Foundation

/// Who this app is to a server. Every request says `X-Napsack-Client:
/// ios/<version>+<build>`, so the server can turn away an app older than it
/// supports (docs/operations/releasing.md, rule 4).
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    static var clientHeader: String { "ios/\(version)+\(build)" }
    /// The server this build starts on (Config/Base.xcconfig); the app can be pointed elsewhere.
    static let defaultServer = Bundle.main.object(forInfoDictionaryKey: "NapsackServerURL") as? String ?? ""
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
    let role: String
    let hasRecoveryKey: Bool
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
}

/// How requests go out: URLSession in the app, a stand-in in tests.
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct NetworkTransport: Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerError.unreachable }
        return (data, http)
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

    func request(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: base.appending(path: "api").appending(path: path))
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
    func send(_ path: String, method: String = "GET", token: String? = nil, json: (any Encodable)? = nil) async throws -> Data {
        let body = try json.map { try Self.encoder.encode($0) }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request(path, method: method, token: token, body: body))
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

    /// Ends this session on the server (the token stops working).
    func logout(token: String) async throws {
        _ = try await send("auth/logout", method: "POST", token: token)
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
