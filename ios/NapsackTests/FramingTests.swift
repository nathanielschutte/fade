import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// What's on screen before sending is what's sent (pic-framing.md; X52): a
/// photo just taken is cropped to the screen it filled; one from the library
/// starts whole and is cropped to the part zoomed in on.
struct FramingTests {
    let screen = CGSize(width: 390, height: 844)
    let tall = CGSize(width: 1200, height: 1600)
    let wide = CGSize(width: 1600, height: 900)

    @Test func aPhotoJustTakenIsSentAsTheScreenShowedIt() {
        let f = Framing(whole: false)
        // Filling a 390 × 844 screen: the full height, the middle of the width.
        let crop = f.crop(image: tall, screen: screen)
        #expect(crop.height == 1600)
        #expect(abs(crop.width - 1600 * 390 / 844) <= 1)
        #expect(abs(crop.midX - 600) <= 1)
        // It can't be zoomed or moved.
        var moved = f
        moved.zoom = 2
        moved.offset = CGSize(width: 50, height: 0)
        #expect(moved.kept(image: tall, screen: screen) == f)
    }

    @Test func aPhotoFromTheLibraryStartsWhole() {
        let f = Framing(whole: true)
        #expect(f.crop(image: wide, screen: screen) == CGRect(origin: .zero, size: wide))
        #expect(f.shown(image: wide, screen: screen).size.width == 390)
        #expect(abs(f.shown(image: wide, screen: screen).height - 219.375) < 0.01)
    }

    @Test func zoomedInOnlyThePartOnScreenIsSent() {
        var f = Framing(whole: true)
        f.zoom = 2
        // A wide photo twice as large: twice the screen's width, so the middle half of its width, all its height.
        let crop = f.kept(image: wide, screen: screen).crop(image: wide, screen: screen)
        #expect(crop == CGRect(x: 400, y: 0, width: 800, height: 900))
        // Moved to its left edge, and no further.
        f.offset = CGSize(width: 10_000, height: 300)
        let left = f.kept(image: wide, screen: screen)
        #expect(left.offset == CGSize(width: 195, height: 0))  // taller than the photo, the screen keeps it centered
        #expect(left.crop(image: wide, screen: screen) == CGRect(x: 0, y: 0, width: 800, height: 900))
    }

    @Test func zoomStaysBetweenOneAndFour() {
        var f = Framing(whole: true)
        f.zoom = 9
        #expect(f.kept(image: wide, screen: screen).zoom == Framing.maxZoom)
        f.zoom = 0.3
        #expect(f.kept(image: wide, screen: screen).zoom == 1)
    }

    @Test func aPinchKeepsWhatsUnderTheFingers() {
        let start = Framing(whole: true)
        let at = CGPoint(x: 300, y: 422)
        let rect = start.photoRect(image: wide, screen: screen)
        let under = CGPoint(x: (at.x - rect.minX) / rect.width, y: (at.y - rect.minY) / rect.height)
        let f = start.pinched(from: start, by: 2, at: at, moved: .zero, screen: screen)
        let after = f.photoRect(image: wide, screen: screen)
        #expect(abs(after.minX + under.x * after.width - at.x) < 0.01)
        #expect(abs(after.minY + under.y * after.height - at.y) < 0.01)
    }

    /// A drawn line stays where it was drawn on the photo, cropped with it.
    @Test func aCropTakesTheDrawingWithIt() throws {
        let photo = TestPicture.photo(size: wide)
        let line = Stroke(points: [CGPoint(x: 700, y: 450), CGPoint(x: 900, y: 450)], width: 40)
        let flat = Framing.cropped(Pen.flatten(photo, strokes: [line]), to: CGRect(x: 400, y: 0, width: 800, height: 900))
        #expect(flat.size == CGSize(width: 800, height: 900))
        let red = try #require(flat.pixel(at: CGPoint(x: 400, y: 450)))  // 800 in the photo
        #expect(red.r > 0.9 && red.g < 0.4)
    }

    @Test func whatsSentIsTheCrop() async throws {
        var f = Framing(whole: true)
        f.zoom = 2
        let crop = f.kept(image: wide, screen: screen).crop(image: wide, screen: screen)
        let ready = try await ReadyToSend.prepare(.photo(TestPicture.photo(size: wide)), strokes: [], crop: crop, caption: "", y: 0.75)
        guard case .photo(let jpeg) = ready.media else { Issue.record("not a photo"); return }
        let sent = try #require(UIImage(data: jpeg))
        #expect(sent.size == CGSize(width: 800, height: 900))  // never scaled up
    }

    @Test func aCaptionIsAtMostFiveLinesAndHasNoLineBreaks() {
        let width: CGFloat = 390
        #expect(CaptionLook.typed("hi\n", was: "hi", width: width) == nil)  // Return: done
        let five = Array(repeating: "Lots of words here", count: 10).joined(separator: " ")
        #expect(CaptionLook.lines(five, width: width) <= 5)
        let more = five + " and then quite a few more words to go past the fifth line"
        #expect(CaptionLook.lines(more, width: width) > 5)
        #expect(CaptionLook.typed(more, was: five, width: width) == five)
        #expect(CaptionLook.typed(String(repeating: "i", count: 201), was: "i", width: width) == "i")
        // The size goes with the picture's width: the same lines on any screen.
        #expect(CaptionLook.size(390) == 390 * 0.044)
        #expect(CaptionLook.lines(five, width: 390) == CaptionLook.lines(five, width: 780))
    }
}

private extension UIImage {
    /// The color at `p` (in pixels from the top left), 0 to 1.
    func pixel(at p: CGPoint) -> (r: Double, g: Double, b: Double)? {
        guard let cg = cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: -p.x, y: -(CGFloat(cg.height) - 1 - p.y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }
}
