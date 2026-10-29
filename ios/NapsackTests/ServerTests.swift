import Foundation
import Testing
@testable import Napsack

@Suite struct ServerTests {
    /// A real answer from GET /api/config (staging, 0.42.0).
    static let staging = """
    {"api_version":1,"build":"aa3aa6a","environment":"staging","group_message_formats":[0,3,5,7],"invite_required":true,\
    "message_formats":[1,2,4,6],"min_client_versions":{},"server_version":"0.42.0","snap_max_bytes":524288,\
    "snap_ttl_hours":720,"started_at":1793304049,"vapid_public_key":"BCTu","video_max_bytes":4194304,"video_max_seconds":10}
    """

    @Test func readsTheServersConfig() throws {
        let config = try ServerConfig.decode(Data(Self.staging.utf8))
        #expect(config.serverVersion == "0.42.0")
        #expect(config.environment == "staging")
        #expect(config.messageFormats == [1, 2, 4, 6])
        #expect(config.groupMessageFormats == [0, 3, 5, 7])
        #expect(config.minimumIOS == nil)
    }

    @Test func readsAnOlderServerAndProduction() throws {
        // Before 0.42.0 there were no group formats; production's environment is null.
        let json = Self.staging
            .replacingOccurrences(of: "\"group_message_formats\":[0,3,5,7],", with: "")
            .replacingOccurrences(of: "\"staging\"", with: "null")
            .replacingOccurrences(of: "{}", with: "{\"ios\":\"1.2.0\"}")
        let config = try ServerConfig.decode(Data(json.utf8))
        #expect(config.groupMessageFormats == nil)
        #expect(config.environment == nil)
        #expect(config.minimumIOS == "1.2.0")
    }

    @Test func comparesVersionsLikeTheServer() {
        #expect(ClientVersion.isOlder("1.1.99", than: "1.2.0"))
        #expect(!ClientVersion.isOlder("1.2.0", than: "1.2.0"))
        #expect(!ClientVersion.isOlder("1.10.0", than: "1.9.0"))
        #expect(ClientVersion.isOlder("0.1.0+7", than: "1"))
        #expect(!ClientVersion.isOlder("1.2.0-beta", than: "1.2"))
    }

    @Test func acceptsOnlyWebAddresses() throws {
        #expect(try Server("https://staging.napsack.io").request("config").url?.absoluteString == "https://staging.napsack.io/api/config")
        #expect(try Server(" http://192.168.1.20:8080 ").request("config").url?.absoluteString == "http://192.168.1.20:8080/api/config")
        #expect(throws: ServerError.self) { try Server("staging.napsack.io") }
        #expect(throws: ServerError.self) { try Server("ftp://example.com") }
    }

    @Test func saysWhichAppItIs() throws {
        let request = try Server("https://staging.napsack.io").request("config")
        #expect(request.value(forHTTPHeaderField: "X-Napsack-Client")?.hasPrefix("ios/") == true)
    }
}
