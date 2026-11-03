import Foundation
import Testing
@testable import Napsack

/// Add-a-friend links: what counts as one.
struct LinksTests {
    @Test func onlyNapsackLinksHaveAToken() {
        let token = "AbCdEfGhIjKlMnOpQr_-12"
        #expect(FriendLinks.token(in: URL(string: "https://napsack.io/i/\(token)")!) == token)
        #expect(FriendLinks.token(in: URL(string: "http://nates-laptop.local:8080/i/\(token)")!) == token)
        for other in [
            "https://napsack.io/i/short",
            "https://napsack.io/i/\(token)x",
            "https://napsack.io/x/\(token)",
            "https://napsack.io/i/\(token)/more",
            "https://napsack.io/",
            "napsack://i/\(token)",
            "https://napsack.io/i/AbCdEfGhIjKlMnOpQr%2F12",
        ] {
            #expect(FriendLinks.token(in: URL(string: other)!) == nil, "\(other)")
        }
    }
}

/// Against a real server (a local one; it makes accounts): a link says whose
/// it is, signs someone new up as their friend, and adds someone signed in.
/// Runs only with NAPSACK_TEST_SERVER set.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveLinksTests {
    let live = LiveChatListTests()
    let password = "correct horse battery"

    func newSession(_ prefix: String) async throws -> Session {
        let session = Session(store: MemoryStore(), reporter: Reporter())
        try await session.signUp(server: live.address, username: "\(prefix)_\(UUID().uuidString.prefix(6).lowercased())",
                                 password: password, inviteCode: live.invite)
        session.recoveryKeyToShow = nil
        return session
    }

    func friendIds(_ session: Session) async throws -> [Int64] {
        let account = try #require(session.account)
        struct Friend: Decodable { let id: Int64 }
        return try Server.decoder.decode([Friend].self, from: await Server(account.server).send("friends", token: account.token)).map(\.id)
    }

    @Test func aLinkSignsUpAndAdds() async throws {
        let ana = try await newSession("lnka")
        let anaAccount = try #require(ana.account)
        struct Link: Decodable { let path: String }
        let path = try Server.decoder.decode(Link.self, from: await Server(live.address).send("friend-link", token: anaAccount.token)).path
        let url = try #require(URL(string: live.address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path))

        // Signed out: whose it is, then a new account that starts out as her friend, with no invite code.
        let links = FriendLinks()
        #expect(await links.open(url, server: live.address))
        let invite = try #require(links.pending)
        #expect(invite.inviter?.id == anaAccount.user.id && invite.problem == nil)
        let ben = Session(store: MemoryStore(), reporter: Reporter())
        try await ben.signUp(server: live.address, username: "lnkb_\(UUID().uuidString.prefix(6).lowercased())",
                             password: password, inviteCode: nil, inviteToken: invite.token)
        #expect(try await friendIds(ben) == [anaAccount.user.id])

        // Signed in: someone with an account adds her by it.
        let cat = try await newSession("lnkc")
        let friend = try await FriendLinks.accept(invite.token, account: try #require(cat.account))
        #expect(friend.id == anaAccount.user.id)
        #expect(try await friendIds(cat) == [anaAccount.user.id])

        // A link that isn't one says so, in the server's words.
        let broken = try #require(URL(string: live.address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/i/" + String(repeating: "a", count: 22)))
        #expect(await links.open(broken, server: live.address))
        #expect(links.pending?.inviter == nil && links.pending?.problem != nil)
        #expect(await links.open(URL(string: "https://example.com/elsewhere")!, server: live.address) == false)
    }
}
