import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Looking closely at an opened photo (ZoomablePhoto): it opens filling the
/// screen when that cuts off only a little (whole otherwise), zooms out as
/// far as the whole photo and no further, zooms in and back with a double
/// tap, stays inside its edges, and a tap while zoomed in or out only goes
/// back: it never goes on to the next pic. (The pinch and the drag are
/// UIScrollView's own: these check how it's set up.)
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

    /// A new size (the Duo unfolding) opens it again, for that size: filling it, there.
    @Test func aNewSizeOpensItAgain() {
        let zoom = view()
        zoom.doubleTap(at: CGPoint(x: 187, y: 250), animated: false)
        zoom.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        zoom.layoutIfNeeded()
        let fitted = ZoomView.fitted(CGSize(width: 900, height: 1200), in: zoom.bounds.size)
        #expect(zoom.atOpening && zoom.opening == ZoomView.opening(CGSize(width: 900, height: 1200), in: zoom.bounds.size))
        #expect(abs(zoom.imageView.frame.width - fitted.width * zoom.opening) < 0.5)
        #expect(zoom.picture.contains(zoom.bounds.insetBy(dx: 0.5, dy: 0.5)), "no black: \(zoom.picture)")
    }

    /// Nate (2026-11-06): no black at the sides when filling the screen cuts off only a
    /// little; whole when it would cut off a lot; never so close the caption's words go.
    @Test func itOpensFillingTheScreenWhenThatCutsOffLittle() {
        let small = CGSize(width: 375, height: 667), large = CGSize(width: 440, height: 956)
        // Taken on a 402 x 874 phone (cropped to its screen, Framing), opened on a small one: filling cuts off a little of its top and bottom.
        let taken = CGSize(width: 804, height: 1748)
        #expect(abs(ZoomView.opening(taken, in: small) - 375 / (804 * 667 / 1748)) < 0.001)
        #expect(abs(ZoomView.opening(taken, in: large) - 1) < 0.01, "the same shape as the screen: it fills as it fits")
        // A wide photo from the library, or a 3:4 one: filling would cut off too much, so whole.
        #expect(ZoomView.opening(CGSize(width: 1600, height: 900), in: large) == 1)
        #expect(ZoomView.opening(CGSize(width: 900, height: 1200), in: small) == 1)
        // A 9:16 one on a taller screen: filling cuts off its sides, as far as the caption's words allow.
        let tall = CGSize(width: 1080, height: 1920)
        let filling = ZoomView.opening(tall, in: large)
        #expect(filling > 1.1 && filling <= ZoomView.fillLimit)
        #expect(ZoomView.opening(tall, in: large, captionSpan: CaptionLook.span("hi")) == filling)
        let long = CaptionLook.span(Array(repeating: "Lots of words here", count: 6).joined(separator: " "))
        #expect(long > 0.9 && ZoomView.opening(tall, in: large, captionSpan: long) < filling)
        #expect(ZoomView.opening(tall, in: large, captionSpan: long) >= 1)
    }

    /// Filling the screen, it zooms out as far as the whole photo, which is all that was sent.
    @Test func filledItZoomsOutToTheWholePhotoAndBack() {
        let zoom = view(TestPicture.plain(.white, size: CGSize(width: 804, height: 1748)))
        var tapped = 0
        zoom.tapped = { tapped += 1 }
        #expect(zoom.atOpening && !zoom.isZoomed && zoom.opening > 1.2)
        #expect(zoom.picture.contains(zoom.bounds.insetBy(dx: 0.5, dy: 0.5)), "no black anywhere: \(zoom.picture)")
        #expect(abs(zoom.picture.midX - 187.5) < 0.5 && abs(zoom.picture.midY - 333.5) < 0.5, "its middle in the screen's")
        #expect(zoom.contentInset == .zero)
        expectInsideItsEdges(zoom)
        #expect(zoom.minimumZoomScale == 1, "as far out as the whole photo")
        zoom.setZoomScale(0.5, animated: false)
        #expect(zoom.zoomScale == 1)
        #expect(zoom.imageView.frame.size == ZoomView.fitted(CGSize(width: 804, height: 1748), in: zoom.bounds.size))
        #expect(!zoom.isZoomed && !zoom.atOpening)
        zoom.singleTap(animated: false)  // zoomed out: back, not on to the next
        #expect(tapped == 0 && zoom.atOpening)
        zoom.doubleTap(at: CGPoint(x: 150, y: 333), animated: false)
        #expect(zoom.isZoomed && abs(zoom.zoomScale - zoom.opening * ZoomView.doubleTapZoom) < 0.01)
        zoom.doubleTap(at: .zero, animated: false)
        #expect(zoom.atOpening)
        zoom.singleTap(animated: false)
        #expect(tapped == 1)
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

        /// Filling the screen cuts off a little of the picture's bottom: a caption the sender
        /// put there stays on what shows, above the screen's bottom edge. Zoomed out to the
        /// whole photo, it's back where they put it.
        @Test(arguments: [false, true])
        func aCaptionStaysOnWhatShows(large: Bool) async throws {
            let phone = large ? Phone.large : Phone.small
            // A little wider than the large phone's screen and narrower than the small one's: filling cuts off a little.
            let photo = TestPicture.plain(.white, size: CGSize(width: 780, height: 1560))
            let words = "Down at the very bottom"
            let screen = try Hosted(ZStack { Color.black.ignoresSafeArea(); OpenedPhoto(photo: photo, caption: words, y: 0.96, tapped: {}) },
                                    size: phone.size, insets: phone.insets)
            defer { screen.close() }
            let zoom = try #require(Self.find(ZoomView.self, in: screen.window))
            try await screen.until("laid out") { zoom.imageView.frame.width > 0 }
            let picture = zoom.convert(zoom.imageView.frame, to: screen.window)
            #expect(picture.contains(screen.window.bounds.insetBy(dx: 0.5, dy: 0.5)), "it fills the screen: \(picture)")
            let safe = EdgeInsets(top: phone.insets.top, leading: 0, bottom: phone.insets.bottom, trailing: 0)
            let middle = PlacedCaption.middle(words, y: 0.96, picture: picture, screen: phone.size, safe: safe)
            let h = CaptionLook.height(words, width: picture.width)
            #expect(middle + h / 2 <= phone.size.height - phone.insets.bottom + 0.5, "above the screen's bottom edge")
            let spot = CGPoint(x: 8, y: middle)  // the strip, at the screen's side: dark
            try await screen.until("the caption shows on screen") { (try? screen.color(at: spot))?.first.map { $0 < 160 } == true }
            try screen.save("photo-filled-caption-\(Int(phone.size.width))")
            zoom.setZoomScale(1, animated: false)  // the whole photo
            let whole = zoom.convert(zoom.imageView.frame, to: screen.window)
            let back = PlacedCaption.middle(words, y: 0.96, picture: whole, screen: phone.size, safe: safe)
            #expect(abs(back - (whole.minY + CaptionLook.middle(0.96, text: words, picture: whole.size))) < 0.5, "where they put it")
            try await screen.until("the caption moves with it") {
                (try? screen.color(at: CGPoint(x: whole.minX + 4, y: back)))?.first.map { $0 < 160 } == true
            }
            try screen.save("photo-whole-caption-\(Int(phone.size.width))")
        }

        static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
            if let found = view as? T { return found }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }
    }
}
