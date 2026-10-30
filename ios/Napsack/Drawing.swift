import SwiftUI
import UIKit

/// Drawing on a photo, our own and kept very simple on purpose (Nate,
/// 2026-10-30: not PencilKit; one pen to build on). One color, one width,
/// undo. Strokes are kept in the photo's own pixels, so they land where they
/// were drawn whatever the screen, and they're flattened into the photo
/// before it's sealed (as the web's draw.js does).
struct Stroke: Equatable {
    /// Points in the photo's pixels.
    var points: [CGPoint]
    /// Width in the photo's pixels (the pen's on-screen width, at the scale it was drawn).
    var width: CGFloat
}

enum Pen {
    static let color = UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    /// On screen, in points.
    static let width: CGFloat = 6

    /// How much the photo is scaled to fill `box` (aspect fill, centered, as the camera shows it).
    static func scale(image: CGSize, box: CGSize) -> CGFloat {
        max(box.width / max(image.width, 1), box.height / max(image.height, 1))
    }

    /// A point on screen to the photo's pixels.
    static func toImage(_ p: CGPoint, image: CGSize, box: CGSize) -> CGPoint {
        let s = scale(image: image, box: box)
        return CGPoint(x: (p.x - (box.width - image.width * s) / 2) / s, y: (p.y - (box.height - image.height * s) / 2) / s)
    }

    /// The photo's pixels to a point on screen.
    static func toScreen(_ p: CGPoint, image: CGSize, box: CGSize) -> CGPoint {
        let s = scale(image: image, box: box)
        return CGPoint(x: p.x * s + (box.width - image.width * s) / 2, y: p.y * s + (box.height - image.height * s) / 2)
    }

    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: first) }  // a dot
        for p in points.dropFirst() { path.addLine(to: p) }
        return path
    }

    /// The photo with the strokes drawn in, at its own size; the photo itself if there are none.
    static func flatten(_ image: UIImage, strokes: [Stroke]) -> UIImage {
        guard !strokes.isEmpty else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let g = context.cgContext
            g.setStrokeColor(color.cgColor)
            g.setLineCap(.round)
            g.setLineJoin(.round)
            for stroke in strokes {
                g.setLineWidth(stroke.width)
                g.addPath(path(stroke.points).cgPath)
                g.strokePath()
            }
        }
    }
}

/// The strokes over the photo, and, while the pen is on, a finger drawing more.
struct PenLayer: View {
    let image: CGSize
    let box: CGSize
    @Binding var strokes: [Stroke]
    let drawing: Bool
    @State private var current: [CGPoint] = []

    var body: some View {
        let s = Pen.scale(image: image, box: box)
        Canvas { context, _ in
            for stroke in strokes + (current.isEmpty ? [] : [Stroke(points: current, width: Pen.width / s)]) {
                let shown = stroke.points.map { Pen.toScreen($0, image: image, box: box) }
                context.stroke(Pen.path(shown), with: .color(Color(Pen.color)),
                               style: StrokeStyle(lineWidth: stroke.width * s, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: box.width, height: box.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            current.append(Pen.toImage(drag.location, image: image, box: box))
        }.onEnded { _ in
            if !current.isEmpty { strokes.append(Stroke(points: current, width: Pen.width / s)) }
            current = []
        }, including: drawing ? .all : .none)
        .allowsHitTesting(drawing)
        .accessibilityHidden(true)
    }
}
