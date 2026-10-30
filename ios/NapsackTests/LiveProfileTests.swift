import Foundation
import Testing
import UIKit
@testable import Napsack

/// Profiles against a real napsack server (a local one; it makes accounts):
/// your name, birthday, and picture as a friend sees them; a nickname only you
/// see; unfriending. Runs only with NAPSACK_TEST_SERVER set (LiveSignInTests says how).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPSACK_TEST_SERVER"] != nil), .timeLimit(.minutes(1)))
struct LiveProfileTests {
    let live = LiveChatListTests()

    static func photo(_ color: UIColor, width: CGFloat = 1600, height: CGFloat = 900) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: width / 2 - 100, y: height / 2 - 100, width: 200, height: 200))
        }
    }

    @Test func whatFriendsSeeAndUnfriending() async throws {
        let ana = try await live.newAccount("ana"), ben = try await live.newAccount("ben")
        let anas = FriendsModel(account: ana), bens = FriendsModel(account: ben)
        _ = try await anas.add(ben.user.username)
        try await bens.loadRequests()
        try await bens.accept(try #require(bens.requests.incoming.first))

        // Ana's own profile: a name, a birthday without the year, a picture.
        let mine = ProfileModel(account: ana)
        try await mine.setName("Ana Banana")
        try await mine.setBirthday(month: 3, day: 14, year: nil)
        try await mine.setPicture(Self.photo(.systemTeal))
        let avatar = try #require(mine.profile?.avatarId)
        #expect(mine.profile?.kind == "me" && mine.profile?.displayName == "Ana Banana")

        // Ben sees all of it, and her picture loads.
        let seen = ProfileModel(account: ben)
        try await seen.load(ana.user.id)
        #expect(seen.profile?.kind == "friend" && seen.profile?.displayName == "Ana Banana")
        #expect(seen.profile?.birthday == Profile.Birthday(month: 3, day: 14, year: nil) && seen.profile?.birthday?.words == "March 14")
        #expect(seen.profile?.avatarId == avatar)
        let pictures = Pictures(account: ben)
        let path = Pictures.path(.friend(ana.user.id), avatar: avatar)
        async let one: Void = pictures.load(path)
        async let two: Void = pictures.load(path)  // asked twice at once: fetched once
        _ = await (one, two)
        #expect(pictures.images[path] != nil)

        // A nickname only Ben sees.
        try await seen.setNickname("Banana", for: ana.user.id)
        #expect(seen.profile?.nickname == "Banana")
        try await mine.load(ana.user.id)
        #expect(mine.profile?.nickname == nil)

        // Picture removed, then unfriended: she's no longer in his list.
        try await mine.removePicture()
        #expect(mine.profile?.avatarId == nil)
        try await seen.unfriend(ana.user.id)
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        try await list.load(ben)
        #expect(!list.rows.contains { $0.kind == .friend(ana.user.id) })
    }

    @Test func aPictureIsSquaredAndSmall() throws {
        let data = try #require(ProfileModel.avatarJPEG(Self.photo(.systemOrange, width: 4000, height: 3000)))
        let image = try #require(UIImage(data: data))
        #expect(data.count <= 120_000 && image.size == CGSize(width: 512, height: 512))
    }
}
