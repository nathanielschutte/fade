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

/// Links in texts to the app's own chats (ChatLink): only the app's own site's
/// routes count, and only they become tappable.
struct ChatLinkTests {
    let site = "https://napsack.io"

    func link(_ text: String, site: String? = "https://napsack.io") -> ChatLink? {
        URL(string: text).flatMap { ChatLink($0, site: site) }
    }

    @Test func theOwnSitesRoutesOpen() {
        #expect(link("https://napsack.io/#group=3&message=12") == ChatLink(kind: .group(3), message: 12))
        #expect(link("https://napsack.io/#chat=7") == ChatLink(kind: .friend(7), message: nil))
        #expect(link("https://napsack.io#chat=7&message=1") == ChatLink(kind: .friend(7), message: 1))
        #expect(link("HTTPS://NapSack.IO/#group=3") == ChatLink(kind: .group(3), message: nil))
        #expect(link("https://napsack.io/#chat=7", site: "https://napsack.io/") == ChatLink(kind: .friend(7), message: nil))
        // Development: the server's own address, port and all.
        #expect(link("http://127.0.0.1:8097/#group=2&message=5", site: "http://127.0.0.1:8097") == ChatLink(kind: .group(2), message: 5))
    }

    @Test func anythingElseDoesnt() {
        for other in [
            "https://evil.example/#group=1",
            "https://napsack.io.evil.example/#group=1",
            "https://evilnapsack.io/#group=1",
            "https://napsack.io@evil.example/#group=1",
            "https://user@napsack.io/#group=1",
            "https://xn--npsack-3ve.io/#group=1",  // a lookalike, spelled for DNS
            "http://napsack.io/#group=1",  // not the site's scheme
            "https://napsack.io:8443/#group=1",
            "https://napsack.io/admin#group=1",
            "https://napsack.io/i/#group=1",
            "https://napsack.io/?next=evil#group=1",
            "javascript:alert(1)//napsack.io/#group=1",
            "napsack://napsack.io/#group=1",
            "https://napsack.io/#group=0",
            "https://napsack.io/#group=-3",
            "https://napsack.io/#group=3a",
            "https://napsack.io/#group=",
            "https://napsack.io/#group=99999999999999999999",
            "https://napsack.io/#group=3&message=",
            "https://napsack.io/#group=3&message=1&more=2",
            "https://napsack.io/#group=3&reply=1",
            "https://napsack.io/#friends",
            "https://napsack.io/#admin=1",
            "https://napsack.io/#group%3D3",
            "https://napsack.io/",
        ] {
            #expect(link(other) == nil, "\(other)")
        }
        #expect(link("https://napsack.io/#group=3", site: nil) == nil)
        #expect(link("https://napsack.io/#group=3", site: "javascript:alert(1)") == nil)
    }

    /// Only the own site's routes get a link, where they're written; every other link stays words.
    @Test func onlyOwnLinksAreTappable() {
        let text = "An Admin reviewed a report.\n\nOpen it: https://napsack.io/#group=3&message=12. Or https://evil.example/#group=3 or https://napsack.io.evil.example/#chat=1, javascript:alert(1)"
        let linked = ChatLink.linked(text, site: site)
        let links = linked.runs.compactMap { run in run.link.map { ($0, String(linked[run.range].characters)) } }
        #expect(links.count == 1)
        #expect(links.first?.0 == URL(string: "https://napsack.io/#group=3&message=12"))
        #expect(links.first?.1 == "https://napsack.io/#group=3&message=12")  // the words shown are where it goes
        #expect(String(linked.characters) == text)
        #expect(ChatLink.linked(text, site: nil).runs.allSatisfy { $0.link == nil })
        #expect(ChatLink.linked("(https://napsack.io/#chat=4)", site: site).runs.compactMap(\.link) == [URL(string: "https://napsack.io/#chat=4")!])
        #expect(ChatLink.linked("see https://napsack.io/privacy and www.napsack.io", site: site).runs.allSatisfy { $0.link == nil })
    }
}

/// Against a real server (a local one; it makes accounts): a link says whose
/// it is, signs someone new up as their friend, and adds someone signed in.
/// Runs only with NAPSACK_TEST_SERVER set.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveLinksTests {
    let live = LiveChatListTests()
    let password = testPassword

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
