import SwiftUI
import UIKit

/// A photo you can look at closely, with the gestures every iPhone photo has
/// (UIScrollView's own zooming): pinch to zoom, drag to look around once
/// zoomed, double-tap to zoom in where you tapped (or back), and it springs
/// back inside its edges. It opens filling the screen when that cuts off only
/// a little of it (ZoomView.opening; Nate, 2026-11-06: no black bars), and
/// zooms out as far as the whole photo, which is all the sender sent: what
/// they saw, and never more (pic-framing.md).
///
/// A single tap at the size it opened at is `tapped` (on to the next pic, or
/// closed). Zoomed in or out, a tap goes back to that size instead: a
/// view-once pic can't be opened again, so a tap while looking closely never
/// throws it away.
struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    /// How much of the picture's width the caption's words take (CaptionLook.span): filling
    /// the screen never cuts them off at the sides. Nil without a caption.
    var captionSpan: CGFloat? = nil
    /// Zoomed in past the size it opened at (the caption hides meanwhile).
    @Binding var zoomed: Bool
    /// Where the whole picture is on screen, as zoomed (the caption sits on it).
    @Binding var picture: CGRect
    let tapped: () -> Void

    func makeUIView(context: Context) -> ZoomView {
        let view = ZoomView(image: image)
        view.captionSpan = captionSpan
        return view
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        view.tapped = tapped
        if view.captionSpan != captionSpan { view.captionSpan = captionSpan }
        let zoomed = $zoomed, picture = $picture
        // After the gesture's own update (and never during SwiftUI's, as a resize can be).
        view.zoomChanged = { now in DispatchQueue.main.async { if zoomed.wrappedValue != now { zoomed.wrappedValue = now } } }
        view.pictureChanged = { now in DispatchQueue.main.async { if picture.wrappedValue != now { picture.wrappedValue = now } } }
        view.notePicture()
    }
}

/// The scroll view under ZoomablePhoto: zoom 1 is the photo at the size that
/// fits, as far out as it goes; it opens at `opening`. Kept in the middle
/// while it's smaller than the screen on a side.
final class ZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView: UIImageView
    /// The closest it zooms, against the size that fits (further when it opens close).
    static let deepest: CGFloat = 4
    /// Where a double tap zooms to, against the size it opened at.
    static let doubleTapZoom: CGFloat = 2.5
    /// How far filling the screen may go, against the size that fits: 1.25 cuts off at most
    /// a fifth of the photo's width or height. Further than that (a wide photo on a tall
    /// screen), it opens whole.
    static let fillLimit: CGFloat = 1.25
    var tapped: () -> Void = {}
    var zoomChanged: (Bool) -> Void = { _ in }
    var pictureChanged: (CGRect) -> Void = { _ in }
    var captionSpan: CGFloat? {
        didSet { if captionSpan != oldValue { fittedTo = .zero; setNeedsLayout() } }
    }
    /// The size it opens at (and a tap goes back to), against the size that fits.
    private(set) var opening: CGFloat = 1
    private var fittedTo: CGSize = .zero
    private var wasZoomed = false

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = Self.deepest
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Zoomed in past the size it opened at.
    var isZoomed: Bool { zoomScale > opening + 0.01 }
    /// At the size it opened at (not zoomed in, nor out).
    var atOpening: Bool { abs(zoomScale - opening) <= 0.01 }

    /// The photo's size at the usual zoom: as large as fits, its shape kept.
    static func fitted(_ image: CGSize, in bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        // The side that limits it fits exactly.
        return bounds.width / image.width <= bounds.height / image.height
            ? CGSize(width: bounds.width, height: image.height * bounds.width / image.width)
            : CGSize(width: image.width * bounds.height / image.height, height: bounds.height)
    }

    /// Where a photo opens, against the size that fits: filling `bounds` (no black at
    /// its sides) when that cuts off no more than `fillLimit` allows, but never so close
    /// that the caption's words (`captionSpan` of the picture's width) leave the screen.
    /// Never closer than filling, and never further out than whole.
    static func opening(_ image: CGSize, in bounds: CGSize, captionSpan: CGFloat? = nil) -> CGFloat {
        let fit = fitted(image, in: bounds)
        guard fit.width > 0, fit.height > 0 else { return 1 }
        var scale = max(bounds.width / fit.width, bounds.height / fit.height)  // filling
        guard scale <= fillLimit + 0.0001 else { return 1 }
        if let span = captionSpan, span > 0 { scale = min(scale, bounds.width / (fit.width * span)) }
        return max(scale, 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedTo { fit() }
    }

    /// As it opens, for the screen as it is now (it changed size): at `opening`, in the middle.
    private func fit() {
        fittedTo = bounds.size
        zoomScale = 1
        let image = imageView.image?.size ?? .zero
        imageView.frame = CGRect(origin: .zero, size: Self.fitted(image, in: bounds.size))
        contentSize = imageView.frame.size
        opening = Self.opening(image, in: bounds.size, captionSpan: captionSpan)
        maximumZoomScale = max(Self.deepest, opening * Self.doubleTapZoom)
        zoomScale = opening
        center()
        contentOffset = middle
        noteZoom()
        notePicture()
    }

    /// The offset that puts the photo's middle in the screen's.
    private var middle: CGPoint {
        CGPoint(x: contentSize.width > bounds.width ? (contentSize.width - bounds.width) / 2 : -contentInset.left,
                y: contentSize.height > bounds.height ? (contentSize.height - bounds.height) / 2 : -contentInset.top)
    }

    /// While the photo is narrower or shorter than the screen, the space is shared on both sides.
    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2), y = max(0, (bounds.height - contentSize.height) / 2)
        let insets = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != insets { contentInset = insets }
    }

    private func noteZoom() {
        let now = isZoomed
        guard now != wasZoomed else { return }
        wasZoomed = now
        zoomChanged(now)
    }

    /// Where the whole photo is on screen now (in this view's own place on it).
    var picture: CGRect { imageView.frame.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y) }

    func notePicture() {
        if imageView.frame.width > 0 { pictureChanged(picture) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        notePicture()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        noteZoom()
        notePicture()
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        doubleTap(at: recognizer.location(in: imageView))
    }

    @objc private func singleTapped() { singleTap() }

    /// A double tap at `point` (in the photo's own coordinates): in, around there, or back to the size it opened at.
    func doubleTap(at point: CGPoint, animated: Bool = true) {
        if !atOpening { return setZoomScale(opening, animated: animated) }
        let deeper = min(opening * Self.doubleTapZoom, maximumZoomScale)
        let size = CGSize(width: bounds.width / deeper, height: bounds.height / deeper)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: animated)
    }

    /// One tap: back to the size it opened at when zoomed in or out, otherwise the viewer's own tap.
    func singleTap(animated: Bool = true) {
        if atOpening { tapped() } else { setZoomScale(opening, animated: animated) }
    }
}
