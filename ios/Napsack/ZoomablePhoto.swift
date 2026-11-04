import SwiftUI
import UIKit

/// A photo you can look at closely, with the gestures every iPhone photo has
/// (UIScrollView's own zooming): pinch to zoom, drag to look around once
/// zoomed, double-tap to zoom in where you tapped (or back out), and it
/// springs back inside its edges. At its usual size it fits the screen, as a
/// pic always has, and a drag does nothing.
///
/// A single tap at the usual size is `tapped` (on to the next pic, or
/// closed). Zoomed in, a tap zooms back out instead: a view-once pic can't
/// be opened again, so a tap while looking closely never throws it away.
struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    /// Zoomed in past the usual size (the caption hides meanwhile).
    @Binding var zoomed: Bool
    let tapped: () -> Void

    func makeUIView(context: Context) -> ZoomView {
        ZoomView(image: image)
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        view.tapped = tapped
        let zoomed = $zoomed
        // After the gesture's own update (and never during SwiftUI's, as a resize can be).
        view.zoomChanged = { now in DispatchQueue.main.async { if zoomed.wrappedValue != now { zoomed.wrappedValue = now } } }
    }
}

/// The scroll view under ZoomablePhoto: the photo at the size that fits,
/// kept in the middle while it's smaller than the screen on a side.
final class ZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView: UIImageView
    /// The closest it zooms, against the size that fits.
    static let deepest: CGFloat = 4
    /// Where a double tap zooms to.
    static let doubleTapZoom: CGFloat = 2.5
    var tapped: () -> Void = {}
    var zoomChanged: (Bool) -> Void = { _ in }
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

    var isZoomed: Bool { zoomScale > minimumZoomScale + 0.01 }

    /// The photo's size at the usual zoom: as large as fits, its shape kept.
    static func fitted(_ image: CGSize, in bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        // The side that limits it fits exactly.
        return bounds.width / image.width <= bounds.height / image.height
            ? CGSize(width: bounds.width, height: image.height * bounds.width / image.width)
            : CGSize(width: image.width * bounds.height / image.height, height: bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedTo { fit() }
    }

    /// Back to the usual size, fitted to the screen as it is now (it changed size).
    private func fit() {
        fittedTo = bounds.size
        zoomScale = minimumZoomScale
        imageView.frame = CGRect(origin: .zero, size: Self.fitted(imageView.image?.size ?? .zero, in: bounds.size))
        contentSize = imageView.frame.size
        center()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        noteZoom()
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

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        noteZoom()
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        doubleTap(at: recognizer.location(in: imageView))
    }

    @objc private func singleTapped() { singleTap() }

    /// A double tap at `point` (in the photo's own coordinates): in, around there, or back out.
    func doubleTap(at point: CGPoint, animated: Bool = true) {
        if isZoomed { return setZoomScale(minimumZoomScale, animated: animated) }
        let size = CGSize(width: bounds.width / Self.doubleTapZoom, height: bounds.height / Self.doubleTapZoom)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: animated)
    }

    /// One tap: back out when zoomed, otherwise the viewer's own tap.
    func singleTap(animated: Bool = true) {
        if isZoomed { setZoomScale(minimumZoomScale, animated: animated) } else { tapped() }
    }
}
