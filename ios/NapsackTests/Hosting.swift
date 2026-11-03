import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// Tests that put a window over the app (`Hosted`), one at a time: two at
/// once would get in each other's way. Each such suite goes inside this one
/// (`extension OnScreen { @Suite struct ... }`).
@MainActor @Suite(.serialized) struct OnScreen {}

/// A SwiftUI view in a real window of the app under test, for what only UIKit
/// shows: presentations (sheets and covers) and how a screen draws. Pictures
/// are saved when `NAPSACK_SHOTS` names a folder in the tests' environment
/// (`TEST_RUNNER_NAPSACK_SHOTS=<folder> xcodebuild test ...`).
@MainActor final class Hosted {
    let window: UIWindow
    var root: UIViewController { window.rootViewController! }

    /// `insets` stand in for a phone's safe area (status bar and home
    /// indicator), added to the Simulator's own where they're larger: its
    /// phone's top (47 points on an iPhone 17e) is the least there can be.
    init(_ view: some View, size: CGSize = CGSize(width: 390, height: 844), insets: UIEdgeInsets? = nil) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        if let insets {
            window.layoutIfNeeded()
            let own = window.safeAreaInsets
            host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, insets.top - own.top), left: 0,
                                                         bottom: max(0, insets.bottom - own.bottom), right: 0)
        }
    }

    /// Waits for `condition`, a little at a time; fails the test if it never comes.
    func until(_ what: String, within seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("never happened: \(what) (presented: \(describe(presented)))")
                try? save("never-\(what.replacingOccurrences(of: " ", with: "-"))")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func describe(_ controller: UIViewController?) -> String {
        guard let controller else { return "nothing" }
        return "\(type(of: controller)) style=\(controller.modalPresentationStyle.rawValue) presenting=\(controller.isBeingPresented) "
            + "dismissing=\(controller.isBeingDismissed) transition=\(controller.transitionCoordinator != nil); "
            + "over it: \(describe(controller.presentedViewController))"
    }

    /// The window as it's drawn (sheets and covers included).
    func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The color at a point of the window, as red, green, and blue (0 to 255).
    func color(at point: CGPoint) throws -> [UInt8] {
        let cg = try #require(image().cgImage)
        let scale = CGFloat(cg.width) / window.bounds.width
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return Array(pixel.prefix(3))
    }

    /// Saves a picture of the window as `<name>.png` in `NAPSACK_SHOTS`, if it's set.
    func save(_ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["NAPSACK_SHOTS"], let png = image().pngData() else { return }
        try png.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
    }

    /// What's presented over the window, if anything (a sheet or a cover).
    var presented: UIViewController? { root.presentedViewController }

    func close() {
        root.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// Phones to look at, by their size in points and safe area.
enum Phone {
    /// The smallest still supported (an iPhone SE): a home button, no notch.
    static let small = (size: CGSize(width: 375, height: 667), insets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))
    /// The largest (a Pro Max): the Dynamic Island and the home indicator.
    static let large = (size: CGSize(width: 440, height: 956), insets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
}

/// Pictures to put on the screen in tests.
enum TestPicture {
    /// One color, edge to edge.
    static func plain(_ color: UIColor, size: CGSize = CGSize(width: 900, height: 1200)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            color.setFill()
            c.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Something like a photo (sky, sun, hills, a bright patch), to judge how
    /// buttons sit on one.
    static func photo(size: CGSize = CGSize(width: 1200, height: 1600)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            let g = c.cgContext
            let top = UIColor(red: 0.45, green: 0.7, blue: 0.95, alpha: 1), bottom = UIColor(red: 0.95, green: 0.85, blue: 0.7, alpha: 1)
            let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height * 0.7), options: [.drawsAfterEndLocation])
            UIColor(red: 1, green: 0.95, blue: 0.75, alpha: 1).setFill()
            g.fillEllipse(in: CGRect(x: size.width * 0.62, y: size.height * 0.08, width: size.width * 0.3, height: size.width * 0.3))
            UIColor(red: 0.3, green: 0.55, blue: 0.3, alpha: 1).setFill()
            g.fillEllipse(in: CGRect(x: -size.width * 0.3, y: size.height * 0.62, width: size.width * 1.1, height: size.height * 0.7))
            UIColor(red: 0.2, green: 0.42, blue: 0.25, alpha: 1).setFill()
            g.fillEllipse(in: CGRect(x: size.width * 0.3, y: size.height * 0.68, width: size.width, height: size.height * 0.6))
            UIColor.white.withAlphaComponent(0.9).setFill()
            g.fill(CGRect(x: size.width * 0.7, y: size.height * 0.3, width: size.width * 0.3, height: size.height * 0.12))
        }
    }
}
