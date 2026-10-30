import Foundation
import Testing
@testable import Napsack

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
