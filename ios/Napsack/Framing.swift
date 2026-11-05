import SwiftUI
import UIKit

/// How a photo sits on the camera screen before it's sent, and so what's
/// sent: exactly the part of it on screen (docs/implementation/pic-framing.md).
/// A photo just taken fills the screen, as the camera showed it, and can't be
/// moved; one from the library starts whole, and a pinch zooms it (X52).
struct Framing: Equatable {
    /// Shown whole (a photo from the library), or filling the screen (just taken).
    var whole: Bool
    var zoom: CGFloat = 1
    /// The photo's middle from the screen's middle, in points.
    var offset: CGSize = .zero

    static let maxZoom: CGFloat = 4

    /// Zooming and moving: only a photo shown whole.
    var movable: Bool { whole }

    /// How much the photo is scaled on a `screen`-sized box.
    func scale(image: CGSize, screen: CGSize) -> CGFloat {
        let w = screen.width / max(image.width, 1), h = screen.height / max(image.height, 1)
        return (whole ? min(w, h) : max(w, h)) * zoom
    }

    /// The whole photo's place, in the screen's points (larger than it, zoomed in or filling).
    func photoRect(image: CGSize, screen: CGSize) -> CGRect {
        let s = scale(image: image, screen: screen)
        let size = CGSize(width: image.width * s, height: image.height * s)
        return CGRect(x: (screen.width - size.width) / 2 + offset.width, y: (screen.height - size.height) / 2 + offset.height,
                      width: size.width, height: size.height)
    }

    /// The picture: the part of the photo on screen, which is what's sent, and what the caption sits on.
    func shown(image: CGSize, screen: CGSize) -> CGRect {
        photoRect(image: image, screen: screen).intersection(CGRect(origin: .zero, size: screen))
    }

    /// That part in the photo's own pixels, whole pixels inside the photo.
    func crop(image: CGSize, screen: CGSize) -> CGRect {
        let rect = photoRect(image: image, screen: screen), part = shown(image: image, screen: screen)
        let s = scale(image: image, screen: screen)
        guard s > 0, !part.isNull else { return CGRect(origin: .zero, size: image) }
        let x = ((part.minX - rect.minX) / s).rounded(), y = ((part.minY - rect.minY) / s).rounded()
        let w = (part.width / s).rounded(), h = (part.height / s).rounded()
        return CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(origin: .zero, size: image))
    }

    /// Zoom kept between 1× and 4×, and the photo kept so no gap opens on a
    /// side where it's larger than the screen (centered where it's smaller).
    func kept(image: CGSize, screen: CGSize) -> Framing {
        guard movable else { return Framing(whole: whole) }
        var f = self
        f.zoom = min(max(zoom, 1), Self.maxZoom)
        let s = f.scale(image: image, screen: screen)
        let room = CGSize(width: max(image.width * s - screen.width, 0) / 2, height: max(image.height * s - screen.height, 0) / 2)
        f.offset = CGSize(width: min(max(offset.width, -room.width), room.width), height: min(max(offset.height, -room.height), room.height))
        return f
    }

    /// Pinched from `start` by `by`, around `at` (a point on screen), and moved by `moved`.
    func pinched(from start: Framing, by: CGFloat, at: CGPoint, moved: CGSize, screen: CGSize) -> Framing {
        var f = start
        f.zoom = min(max(start.zoom * by, 1), Self.maxZoom)
        let k = f.zoom / start.zoom
        // The point under the fingers stays under them.
        let from = CGPoint(x: at.x - screen.width / 2 - start.offset.width, y: at.y - screen.height / 2 - start.offset.height)
        f.offset = CGSize(width: at.x - screen.width / 2 - from.x * k + moved.width,
                          height: at.y - screen.height / 2 - from.y * k + moved.height)
        return f
    }

    /// The photo cropped to `crop` (its pixels), or itself when that's all of it.
    static func cropped(_ image: UIImage, to crop: CGRect) -> UIImage {
        let whole = CGRect(origin: .zero, size: image.size)
        guard crop.width >= 1, crop.height >= 1, crop != whole, let cg = image.cgImage?.cropping(to: crop) else { return image }
        return UIImage(cgImage: cg)
    }
}

/// A pic's caption, the same on every client (pic-framing.md): a strip
/// across the picture, its words sized by the picture's width so it covers
/// the same part of it on any screen.
enum CaptionLook {
    static let maxLines = 5
    static let maxCharacters = 200
    /// Where a new caption goes, and an old one with no place.
    static let unplaced = 0.8

    /// The words' size on a picture `width` points wide.
    static func size(_ width: CGFloat) -> CGFloat { width * 0.044 }

    static func font(_ width: CGFloat) -> UIFont { .systemFont(ofSize: size(width)) }

    /// Added between lines so they're 1.25 × the size apart.
    static func lineSpacing(_ width: CGFloat) -> CGFloat { max(size(width) * 1.25 - font(width).lineHeight, 0) }

    /// How many lines `text` takes on a picture `width` points wide.
    static func lines(_ text: String, width: CGFloat) -> Int {
        guard !text.isEmpty, width > 0 else { return 0 }
        let font = font(width)
        let inside = width - 2 * size(width)
        let height = (text as NSString).boundingRect(with: CGSize(width: inside, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil).height
        return max(1, Int((height / font.lineHeight).rounded()))
    }

    /// What's typed, as it may be: no line breaks, 200 characters, 5 lines;
    /// past that, what was there before. Nil when Return was typed (it's done).
    static func typed(_ new: String, was old: String, width: CGFloat) -> String? {
        if new.contains("\n") { return nil }
        if new.count > maxCharacters || lines(new, width: width) > maxLines { return old }
        return new
    }
}

extension View {
    /// The caption's strip on a picture `width` points wide (CaptionLook).
    func captionStrip(width: CGFloat) -> some View {
        let size = CaptionLook.size(width)
        return self
            .font(.system(size: size)).foregroundStyle(.white).tint(.white)
            .multilineTextAlignment(.center).lineSpacing(CaptionLook.lineSpacing(width))
            .padding(.vertical, size * 0.5).padding(.horizontal, size)
            .frame(width: width)
            .background(Color.black.opacity(0.55))
    }
}
