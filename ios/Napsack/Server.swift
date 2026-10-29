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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ServerConfig.self, from: data)
    }

    /// The oldest iOS app this server still serves, if it has a minimum.
    var minimumIOS: String? { minClientVersions["ios"] }
}

enum ServerError: LocalizedError {
    case badAddress
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badAddress: "That isn't a server address. Try one like https://staging.napsack.io."
        case .status(let code): "The server answered \(code)."
        }
    }
}

struct Server {
    let base: URL

    init(_ address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw ServerError.badAddress
        }
        base = url
    }

    func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: base.appending(path: "api").appending(path: path))
        request.setValue(AppInfo.clientHeader, forHTTPHeaderField: "X-Napsack-Client")
        request.timeoutInterval = 15
        return request
    }

    func config() async throws -> ServerConfig {
        let (data, response) = try await URLSession.shared.data(for: request("config"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ServerError.status(code) }
        return try ServerConfig.decode(data)
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
