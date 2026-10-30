import Testing
import UIKit
@testable import Napsack

/// The pen: a stroke drawn on screen lands in the photo where it was drawn,
/// at the photo's own size; no strokes, the photo as it was.
@MainActor @Test func aStrokeIsFlattenedIntoThePhoto() throws {
    let photo = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { c in
        UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    // The photo filling a 400×400 screen: scaled by 2/3 (600 → 400 high), 800 → 533 wide, cropped at the sides.
    let box = CGSize(width: 400, height: 400)
    let across = stride(from: 100.0, through: 300.0, by: 10).map { Pen.toImage(CGPoint(x: $0, y: 200), image: photo.size, box: box) }
    let drawn = Pen.flatten(photo, strokes: [Stroke(points: across, width: 30)])
    #expect(drawn.size == photo.size)
    // The middle of the screen is the middle of the photo, and it isn't white any more.
    let cg = try #require(drawn.cgImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    let ctx = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2, width: CGFloat(cg.width), height: CGFloat(cg.height)))
    #expect(pixel[1] < 120 && pixel[0] > 200)  // red, not white
    #expect(Pen.flatten(photo, strokes: []) === photo)
}

/// Screen and photo points map back and forth, with the crop of aspect fill.
@Test func screenAndPhotoPointsMatch() {
    let image = CGSize(width: 1000, height: 500), box = CGSize(width: 100, height: 100)
    let p = Pen.toImage(CGPoint(x: 50, y: 50), image: image, box: box)
    #expect(abs(p.x - 500) < 0.001 && abs(p.y - 250) < 0.001)  // the middle is the middle
    let corner = Pen.toImage(.zero, image: image, box: box)
    #expect(abs(corner.x - 250) < 0.001 && abs(corner.y) < 0.001)  // the sides are cropped
    let back = Pen.toScreen(p, image: image, box: box)
    #expect(abs(back.x - 50) < 0.001 && abs(back.y - 50) < 0.001)
}
