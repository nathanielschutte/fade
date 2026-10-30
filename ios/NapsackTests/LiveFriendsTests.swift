import Foundation
import Testing
@testable import Napsack

/// Friends against a real napsack server (a local one; it makes accounts):
/// requests both ways, your link, and invite links. Runs only with
/// NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil))
struct LiveFriendsTests {
    let live = LiveChatListTests()

    @Test func requestsLinksAndInvites() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben"), cal = try await live.newAccount("cal")
        let anas = FriendsModel(account: ana), bens = FriendsModel(account: ben), cals = FriendsModel(account: cal)

        // Ana asks Ben; Ben sees it (and the chat list's badge counts it), and accepts.
        #expect(try await anas.add(" \(ben.user.username) ") == "Request sent to \(ben.user.username).")
        #expect(anas.requests.outgoing.map(\.username) == [ben.user.username])
        try await bens.load()
        #expect(bens.requests.incoming.map(\.username) == [ana.user.username])
        let list = ChatList(pinStore: MemoryPinStore())
        try await list.load(ben)
        #expect(list.incoming == 1)
        try await bens.accept(try #require(bens.requests.incoming.first))
        #expect(bens.requests.incoming.isEmpty)
        try await list.load(ben)
        #expect(list.incoming == 0 && list.rows.contains { $0.kind == .friend(ana.user.id) })

        // Asking someone who'd already asked you: friends at once.
        _ = try await cals.add(ana.user.username)
        #expect(try await anas.add(cal.user.username) == "You and \(cal.user.username) are now friends.")

        // Declined, and cancelled.
        _ = try await cals.add(ben.user.username)
        try await bens.loadRequests()
        try await bens.dismiss(try #require(bens.requests.incoming.first))
        try await cals.loadRequests()
        #expect(cals.requests.outgoing.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await anas.add(ana.user.username) }  // "That's you."

        // Your link: the same until reset; reset makes a new one.
        try await anas.load()
        let link = try #require(anas.link).path
        #expect(link.hasPrefix("/i/") && anas.address(link).hasPrefix(live.address))
        try await anas.resetLink()
        #expect(anas.link?.path != link)

        // A one-time invite link: made, listed, turned off.
        try await anas.makeInvite()
        #expect(anas.madeInvite?.contains("/i/") == true)
        let invite = try #require(anas.invites.first)
        #expect(invite.live && invite.maxUses == 10 && invite.joined.isEmpty)
        try await anas.revoke(invite)
        #expect(anas.invites.first?.live == false && anas.invites.first?.revokedAt != nil)
    }

    @Test func aQRCodeIsMadeOnThePhone() {
        let image = QRCode.image("https://napsack.test/i/abc123")
        #expect(image != nil && (image?.size.width ?? 0) > 20)
    }
}
