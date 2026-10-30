import PencilKit
import Testing
import UIKit
@testable import Napsack

/// Drawing on a photo: the stroke ends up in the picture that's sent, at the photo's own size.
@MainActor @Test func aDrawingIsFlattenedIntoThePhoto() throws {
    let photo = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { c in
        UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    // A thick red stroke across the middle of a 400×300 canvas (the photo shown at half size).
    let points = (0...20).map { PKStrokePoint(location: CGPoint(x: Double($0) * 20, y: 150), timeOffset: Double($0) * 0.01,
                                              size: CGSize(width: 30, height: 30), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
    let stroke = PKStroke(ink: PKInk(.marker, color: .red), path: PKStrokePath(controlPoints: points, creationDate: .now))
    let drawn = DrawOnPhoto.flatten(photo, drawing: PKDrawing(strokes: [stroke]), canvas: CGSize(width: 400, height: 300))
    #expect(drawn.size == photo.size)
    // The middle of the photo (canvas y 150 → photo y 300) isn't white any more.
    let cg = try #require(drawn.cgImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    let ctx = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2, width: CGFloat(cg.width), height: CGFloat(cg.height)))
    #expect(pixel[1] < 200 && pixel[0] > 150)  // reddish, not white
    // No strokes: the photo as it was.
    #expect(DrawOnPhoto.flatten(photo, drawing: PKDrawing(), canvas: CGSize(width: 400, height: 300)) === photo)
}
