import Testing
@testable import Napsack

/// How long a pic shows before it moves on by itself (X58), as the web's
/// viewer: a photo 10 seconds, a video its own length, never longer than the
/// longest a video can be.
@Suite struct PicTimeTests {
    @Test func howLongEachShows() {
        #expect(PicPage.showFor(video: nil, longest: 10) == 10, "a photo (app.js, VIEW_MS)")
        #expect(PicPage.showFor(video: 4.2, longest: 10) == 4.2, "a video, its length")
        #expect(PicPage.showFor(video: 30, longest: 10) == 10, "never longer than a video can be")
        #expect(PicPage.showFor(video: .nan, longest: 15) == 15, "one that doesn't say how long: the longest")
        #expect(PicPage.showFor(video: 0, longest: 10) == 10)
    }
}
