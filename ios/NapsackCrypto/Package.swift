// swift-tools-version: 6.0
// napsack's end-to-end encryption in Swift: the same formats as
// shared/crypto/crypto.js, held to the pinned vectors in tests/vectors/.
// The app (ios/Napsack.xcodeproj) uses it; `swift test` checks it on a Mac.
import PackageDescription

let package = Package(
    name: "NapsackCrypto",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NapsackCrypto", targets: ["NapsackCrypto"]),
    ],
    targets: [
        .target(name: "NapsackCrypto"),
        .testTarget(name: "NapsackCryptoTests", dependencies: ["NapsackCrypto"]),
    ]
)
