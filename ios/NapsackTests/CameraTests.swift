@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing
import UIKit
@testable import Napsack

/// The camera's rules that don't need a camera (the Simulator has none).
@MainActor @Suite struct CameraTests {
    /// The lens buttons, from what a phone's camera reports.
    @Test func lensButtonsFollowThePhonesCameras() {
        // Three cameras (an iPhone 16 Pro): factor 1 is the ultra wide; switches at 2 (main) and 10 (5× telephoto).
        let pro = CameraSession.Lenses.of(multiplier: 0.5, switchOvers: [2, 10], minFactor: 1, maxFactor: 30)
        #expect(pro.presets == [0.5, 1, 2, 5] && pro.min == 0.5 && pro.max == 15)
        // Ultra wide and main (an iPhone 16).
        #expect(CameraSession.Lenses.of(multiplier: 0.5, switchOvers: [2], minFactor: 1, maxFactor: 20).presets == [0.5, 1, 2])
        // Main and a 2× telephoto: 2× is the telephoto, shown once.
        #expect(CameraSession.Lenses.of(multiplier: 1, switchOvers: [2], minFactor: 1, maxFactor: 16).presets == [1, 2])
        // One camera (the front): no buttons beyond 1× unless it zooms to 2×.
        #expect(CameraSession.Lenses.of(multiplier: 1, switchOvers: [], minFactor: 1, maxFactor: 1.5).presets == [1])
    }

    @Test func zoomIsWrittenAsTheCameraAppDoes() {
        #expect(CameraScreen.zoomWords(0.5) == ".5")
        #expect(CameraScreen.zoomWords(1) == "1")
        #expect(CameraScreen.zoomWords(2.43) == "2.4")
        #expect(CameraScreen.zoomWords(5) == "5")
    }

    /// A press shorter than a hold is a photo, by the touch's own times (D11).
    @Test func aShortPressIsAPhoto() {
        let down = Date()
        #expect(CameraScreen.isTap(from: down, to: down.addingTimeInterval(0.2)))
        #expect(!CameraScreen.isTap(from: down, to: down.addingTimeInterval(0.5)))
    }

    /// Nate (2026-11-03): the front camera first after a launch; then
    /// whichever was used last, until the app is quit. Each camera screen
    /// has a new session, so this is what each new one opens on.
    @Test func theFrontCameraFirstThenTheLastOneUsed() async {
        let launch = CameraChoice()  // what a fresh launch has
        let first = CameraSession(choice: launch)
        #expect(await first.opensOn == .front)
        first.face(.back)  // switched to the back camera (flip, or a double tap)...
        #expect(await first.opensOn == .back)
        #expect(await CameraSession(choice: launch).opensOn == .back)  // ...so the next camera screen opens on it
        CameraSession(choice: launch).face(.front)
        #expect(await CameraSession(choice: launch).opensOn == .front)
        first.face(.back)
        #expect(await CameraSession(choice: CameraChoice()).opensOn == .front)  // quit and opened again: the front
        #expect(await CameraSession().opensOn == CameraChoice.shared.current)  // the app's screens share one choice
    }

    /// A photo picked from the library opens only if nothing's taken its
    /// place while it loaded: the camera opened (in a chat), a capture taken
    /// (in the camera), or another photo picked. Otherwise a slow iCloud
    /// photo would replace a live camera, or a video being recorded.
    @Test func aLatePickedPhotoNeverReplacesWhatsOnScreen() {
        var picks = PhotoPicks()
        let a = picks.began()
        #expect(picks.stillWanted(a, busy: false))  // nothing happened meanwhile: it opens
        #expect(!picks.stillWanted(a, busy: true))  // the camera opened, or a capture's on screen
        let b = picks.began()  // picked again before the first loaded
        #expect(!picks.stillWanted(a, busy: false))  // the first, late: dropped
        #expect(picks.stillWanted(b, busy: false))
    }

    /// Nate (2026-11-03): writing a caption, a tap anywhere off it puts the
    /// keyboard away, and does nothing else: no new caption, no pen stroke.
    @Test func aTapWhileWritingACaptionOnlyPutsTheKeyboardAway() {
        #expect(CameraScreen.tap(writing: true, drawing: false, captioned: false) == .putKeyboardAway)
        #expect(CameraScreen.tap(writing: true, drawing: false, captioned: true) == .putKeyboardAway)
        // Not writing: a tap starts a caption there (as on the web), unless there's one or the pen's on.
        #expect(CameraScreen.tap(writing: false, drawing: false, captioned: false) == .startCaption)
        #expect(CameraScreen.tap(writing: false, drawing: false, captioned: true) == .nothing)
        #expect(CameraScreen.tap(writing: false, drawing: true, captioned: false) == .nothing)
    }

    /// A photo's file, as JPEG, turned as `orientation` says (EXIF: 6 is a phone held upright).
    func jpegFile(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let image = try #require(TestPicture.plain(.orange, size: CGSize(width: width, height: height)).cgImage)
        let data = NSMutableData()
        let file = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(file, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(file))
        return data as Data
    }

    /// A photo on the camera screen is upright, and at most 2880 on its
    /// longest side (a 48-megapixel one isn't kept whole), never made bigger.
    @Test func aPhotoIsKeptUprightAndNoBiggerThanNeeded() async throws {
        let big = try #require(await Captured.photo(try jpegFile(width: 8064, height: 6048)))
        #expect(big.size == CGSize(width: 2880, height: 2160) && big.scale == 1)
        let held = try #require(await Captured.photo(try jpegFile(width: 400, height: 300, orientation: 6)))
        #expect(held.size == CGSize(width: 300, height: 400) && held.imageOrientation == .up)  // turned upright
        let small = try #require(await Captured.photo(try jpegFile(width: 200, height: 100)))
        #expect(small.size == CGSize(width: 200, height: 100))
        #expect(await Captured.photo(Data("not a photo".utf8)) == nil)
    }
}
