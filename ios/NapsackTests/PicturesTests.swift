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

    @Test func aPictureThatWontLoadLeavesTheInitial() async {
        let server = StubServer { _ in (404, json(["error": "Not found."])) }
        let pictures = Pictures(account: account, transport: server)
        let path = Pictures.path(.friend(7), avatar: 1)
        await pictures.load(path, pixels: 96)
        #expect(pictures.picture(path).image(96) == nil)
    }
}
