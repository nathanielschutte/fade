import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Looking closely at an opened photo (ZoomablePhoto): it fits the screen as
/// before, zooms in and back with a double tap, stays inside its edges, and
/// a tap while zoomed only zooms back out: it never goes on to the next pic.
/// (The pinch and the drag are UIScrollView's own: these check how it's set up.)
@MainActor @Suite struct ZoomTests {
    /// A portrait photo on a small phone, laid out.
    func view(_ image: UIImage = TestPicture.plain(.white), size: CGSize = CGSize(width: 375, height: 667)) -> ZoomView {
        let view = ZoomView(image: image)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    @Test func itFitsTheScreenInTheMiddleAndDoesntMove() {
        let zoom = view()  // 900 x 1200 in 375 x 667
        #expect(zoom.imageView.frame.size == CGSize(width: 375, height: 500))
        #expect(zoom.contentInset.top == 83.5 && zoom.contentInset.left == 0)
        #expect(zoom.contentOffset.x == 0 && abs(zoom.contentOffset.y + 83.5) < 0.5)  // (to the screen's pixels)
        // At its usual size there's nowhere to drag it.
        #expect(zoom.contentSize.width <= zoom.bounds.width && zoom.contentSize.height <= zoom.bounds.height)
        #expect(!zoom.alwaysBounceVertical && !zoom.alwaysBounceHorizontal)
        #expect(zoom.minimumZoomScale == 1 && zoom.maximumZoomScale == ZoomView.deepest && zoom.bouncesZoom)
        #expect(ZoomView.fitted(CGSize(width: 1600, height: 900), in: CGSize(width: 440, height: 956)) == CGSize(width: 440, height: 247.5))
    }

    @Test func aDoubleTapZoomsInWhereItWasAndBackOut() {
        let zoom = view()
        var changes: [Bool] = []
        zoom.zoomChanged = { changes.append($0) }
        zoom.doubleTap(at: CGPoint(x: 300, y: 100), animated: false)
        #expect(zoom.zoomScale == ZoomView.doubleTapZoom && zoom.isZoomed && changes == [true])
        // Around where it was tapped: that spot is near the middle of the screen (as near as the edges allow).
        let spot = zoom.convert(CGPoint(x: 300, y: 100), from: zoom.imageView)
        let onScreen = CGPoint(x: spot.x - zoom.contentOffset.x, y: spot.y - zoom.contentOffset.y)
        #expect(abs(onScreen.x - 187.5) < 120 && abs(onScreen.y - 333.5) < 200)
        expectInsideItsEdges(zoom)
        zoom.doubleTap(at: CGPoint(x: 300, y: 100), animated: false)
        #expect(zoom.zoomScale == 1 && !zoom.isZoomed && changes == [true, false])
    }

    /// Zoomed into a corner, it stops at the photo's edge: no black beyond it.
    @Test func zoomedItStaysInsideItsEdges() {
        let zoom = view()
        zoom.doubleTap(at: .zero, animated: false)
        expectInsideItsEdges(zoom)
        #expect(zoom.contentInset == .zero, "bigger than the screen both ways: no space around it")
        zoom.doubleTap(at: .zero, animated: false)
        zoom.doubleTap(at: CGPoint(x: 375, y: 500), animated: false)  // the far corner
        expectInsideItsEdges(zoom)
    }

    /// The pic's own tap goes on to the next only at its usual size.
    @Test func aTapWhileZoomedOnlyZoomsOut() {
        let zoom = view()
        var tapped = 0
        zoom.tapped = { tapped += 1 }
        zoom.doubleTap(at: CGPoint(x: 187, y: 250), animated: false)
        zoom.singleTap(animated: false)
        #expect(tapped == 0 && !zoom.isZoomed)
        zoom.singleTap(animated: false)
        #expect(tapped == 1)
    }

    /// A new size (the Duo unfolding) fits it again.
    @Test func aNewSizeFitsItAgain() {
        let zoom = view()
        zoom.doubleTap(at: CGPoint(x: 187, y: 250), animated: false)
        zoom.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        zoom.layoutIfNeeded()
        #expect(!zoom.isZoomed && zoom.imageView.frame.size == ZoomView.fitted(CGSize(width: 900, height: 1200), in: zoom.bounds.size))
    }

    func expectInsideItsEdges(_ zoom: ZoomView, sourceLocation: SourceLocation = #_sourceLocation) {
        let offset = zoom.contentOffset, inside = zoom.nearestInside
        #expect(abs(offset.x - inside.x) < 0.5 && abs(offset.y - inside.y) < 0.5, "offset \(offset), inside \(inside)", sourceLocation: sourceLocation)
    }
}

extension ZoomView {
    /// The offset nearest this one that shows only the photo (and the space shared around it while it's smaller than the screen).
    var nearestInside: CGPoint {
        let minX = -contentInset.left, maxX = max(minX, contentSize.width + contentInset.right - bounds.width)
        let minY = -contentInset.top, maxY = max(minY, contentSize.height + contentInset.bottom - bounds.height)
        return CGPoint(x: min(max(contentOffset.x, minX), maxX), y: min(max(contentOffset.y, minY), maxY))
    }
}

// Its windows take turns with the other suites' (Hosting.swift).
extension OnScreen {
    /// An opened photo on screen: zoomed in, its caption hides (and comes back
    /// with the usual size). Pictures in NAPSACK_SHOTS.
    @MainActor @Suite struct OpenedPhotoTests {
        @Test(arguments: [false, true])
        func theCaptionHidesWhileZoomedIn(large: Bool) async throws {
            let phone = large ? Phone.large : Phone.small, size = phone.size
            let screen = try Hosted(OpenedPhoto(photo: TestPicture.plain(.white), caption: "x", y: 0.8, tapped: {}),
                                    size: phone.size, insets: phone.insets)
            defer { screen.close() }
            let zoom = try #require(Self.find(ZoomView.self, in: screen.window))
            try await screen.until("laid out") { zoom.imageView.frame.width > 0 }
            // Just above the caption's words, inside its dark box.
            let picture = zoom.convert(zoom.imageView.frame, to: screen.window)
            let spot = CGPoint(x: picture.midX, y: picture.minY + picture.height * 0.8 - 16)
            try await screen.until("the caption shows") { (try? screen.color(at: spot))?.first.map { $0 < 160 } == true }
            try screen.save("photo-caption-\(Int(size.width))")

            zoom.doubleTap(at: CGPoint(x: zoom.imageView.bounds.midX, y: zoom.imageView.bounds.midY), animated: false)
            try await screen.until("the caption hides") { (try? screen.color(at: spot))?.allSatisfy { $0 >= 250 } == true }
            try screen.save("photo-zoomed-\(Int(size.width))")
            zoom.singleTap(animated: false)
            try await screen.until("it comes back") { (try? screen.color(at: spot))?.first.map { $0 < 160 } == true }
        }

        static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
            if let found = view as? T { return found }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }
    }
}
