import Foundation
import Testing
import UIKit
@testable import Napsack

/// Profile and group pictures (Pictures): fetched once however many ask,
/// decoded off the main thread at the size shown, and each avatar watching
/// only its own picture.
@MainActor @Suite struct PicturesTests {
    let account = Account(server: "https://napsack.test", token: "t",
                          user: Me(id: 3, username: "bob", displayName: nil, role: "user", hasRecoveryKey: true),
                          publicKey: "", privateKey: Data())

    @Test func sizesBucketedSoNearOnesShare() {
        #expect(Pictures.pixels(28, scale: 3) == 96 && Pictures.pixels(32, scale: 3) == 96)  // the chat's header, Send to…
        #expect(Pictures.pixels(44, scale: 3) == 192 && Pictures.pixels(64, scale: 3) == 192)  // the list, your own
        #expect(Pictures.pixels(96, scale: 3) == 384 && Pictures.pixels(44, scale: 2) == 96)
        #expect(Pictures.pixels(400, scale: 3) == 512)
    }

    @Test func fetchedOnceMadeAtEachSizeAndWatchedAlone() async throws {
        // A 512-pixel picture, as profile pictures are.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        let jpeg = try #require(drawn.jpegData(compressionQuality: 0.8))
        let server = StubServer { _ in (200, jpeg) }
        let pictures = Pictures(account: account, transport: server)
        let path = Pictures.path(.friend(7), avatar: 1)

        // Three avatars at two sizes, all at once: one fetch.
        async let a: Void = pictures.load(path, pixels: 96)
        async let b: Void = pictures.load(path, pixels: 192)
        async let c: Void = pictures.load(path, pixels: 192)
        _ = await (a, b, c)
        #expect(await server.requests.count == 1)
        let picture = pictures.picture(path)
        let small = try #require(picture.sizes[96]), large = try #require(picture.sizes[192])
        #expect(small.size.width * small.scale == 96 && large.size.width * large.scale == 192)
        #expect(picture.image(384) === large)  // while a bigger one is made, the nearest shows

        // Another picture arriving doesn't touch this one's avatars.
        final class Flag: @unchecked Sendable { var raised = false }
        let touched = Flag()
        withObservationTracking { _ = picture.image(96) } onChange: { touched.raised = true }
        let other = Pictures.path(.group(12), avatar: 2)
        await pictures.load(other, pixels: 96)
        #expect(pictures.picture(other).image(96) != nil)
        #expect(!touched.raised)

        // Tapped to see it big: the whole picture, from what was fetched.
        let full = try #require(await pictures.full(path))
        #expect(full.size.width * full.scale == 512)
        #expect(await server.requests.count == 2)  // the other picture's, and no more
    }

    // ---------- kept between launches ----------

    static func jpeg(_ color: UIColor) throws -> Data {
        try #require(TestPicture.plain(color, size: CGSize(width: 512, height: 512)).jpegData(compressionQuality: 0.8))
    }

    /// Fetched once, then on the next launch shown from the phone with nothing
    /// fetched; a friend's new picture (a new id) is fetched and takes the old
    /// one's place on the phone.
    @Test func keptBetweenLaunchesUntilThePictureChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "napsack-pictures-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let teal = try Self.jpeg(.systemTeal), orange = try Self.jpeg(.systemOrange)
        let first = StubServer { request in (200, request.url!.path.hasSuffix("/1") ? teal : orange) }
        let old = Pictures.path(.friend(7), avatar: 1), new = Pictures.path(.friend(7), avatar: 2)
        let launch = Pictures(account: account, transport: first, kept: ResponseCache(account: 3, root: root).pictures)
        await launch.load(old, pixels: 96)
        #expect(launch.picture(old).image(96) != nil)
        #expect(await first.requests.count == 1)
        ResponseCache.settle()

        // The next launch, offline: there at once, from the phone.
        let offline = StubServer { _ in throw URLError(.notConnectedToInternet) }
        let next = Pictures(account: account, transport: offline, kept: ResponseCache(account: 3, root: root).pictures)
        await next.load(old, pixels: 96)
        #expect(next.picture(old).image(96) != nil)
        #expect(await offline.requests.isEmpty, "nothing fetched")

        // They changed it: the list says a new id, which is fetched, and only the new one stays kept.
        let online = Pictures(account: account, transport: first, kept: ResponseCache(account: 3, root: root).pictures)
        await online.load(new, pixels: 96)
        #expect(online.picture(new).image(96) != nil)
        #expect(await first.requests.map(\.url!.path) == ["/api/users/7/avatar/1", "/api/users/7/avatar/2"])
        ResponseCache.settle()
        let kept = ResponseCache(account: 3, root: root).pictures
        #expect(kept.read("users-7-avatar-2") == orange && kept.read("users-7-avatar-1") == nil)
        // Someone else's are left alone.
        await online.load(Pictures.path(.group(12), avatar: 1), pixels: 96)
        ResponseCache.settle()
        #expect(kept.read("groups-12-avatar-1") != nil && kept.read("users-7-avatar-2") != nil)
    }

    /// Only so many are kept: past the limit, the longest unchanged go.
    @Test func keptOnlySoMany() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "napsack-pictures-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = ResponseCache(account: 3, root: root).pictures
        for id in 1...4 {
            kept.write(Data([UInt8(id)]), "users-\(id)-avatar-1", replacing: "users-\(id)-avatar-", limit: 3)
            ResponseCache.settle()
            // (file times are to the moment: let each be later than the last)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(id))], ofItemAtPath: kept.file("users-\(id)-avatar-1").path())
        }
        #expect(kept.read("users-1-avatar-1") == nil)
        #expect((2...4).allSatisfy { kept.read("users-\($0)-avatar-1") != nil })
        let protection = try FileManager.default.attributesOfItem(atPath: kept.file("users-4-avatar-1").path())[.protectionKey] as? FileProtectionType
        #expect(protection == nil || protection == .complete)  // (the Simulator may not report it)
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// Signing out deletes them with the kept chats (the same wipe: Session,
    /// CacheTests), and one arriving after it isn't kept.
    @Test func signingOutForgetsThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "napsack-pictures-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Where the app keeps them is inside what signing out wipes.
        #expect(ResponseCache(account: 3).pictures.directory.path().hasPrefix(ResponseCache.root.path()))
        let jpeg = try Self.jpeg(.systemTeal)
        let pictures = Pictures(account: account, transport: StubServer { _ in (200, jpeg) }, kept: ResponseCache(account: 3, root: root).pictures)
        await pictures.load(Pictures.path(.friend(7), avatar: 1), pixels: 96)
        ResponseCache.settle()
        #expect(ResponseCache(account: 3, root: root).pictures.read("users-7-avatar-1") == jpeg)

        // One on its way when they sign out.
        let gate = PageGate(holds: { _ in true }) { _, _ in jpeg }
        let late = Pictures(account: account, transport: gate, kept: ResponseCache(account: 3, root: root).pictures)
        async let loading: Void = late.load(Pictures.path(.friend(8), avatar: 1), pixels: 96)
        await gate.someoneWaiting()
        ResponseCache.wipeAll(root: root)  // signed out meanwhile
        await gate.open()
        await loading
        ResponseCache.settle()
        let left = FileManager.default.enumerator(atPath: root.path())?.allObjects as? [String]
        #expect(left == nil, "nothing of theirs is left, nor kept after: \(left ?? [])")
    }

    @Test func aPictureThatWontLoadLeavesTheInitial() async {
        let server = StubServer { _ in (404, json(["error": "Not found."])) }
        let pictures = Pictures(account: account, transport: server)
        let path = Pictures.path(.friend(7), avatar: 1)
        await pictures.load(path, pixels: 96)
        #expect(pictures.picture(path).image(96) == nil)
    }
}
