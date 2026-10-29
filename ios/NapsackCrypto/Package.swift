// swift-tools-version: 6.0
// napsack's end-to-end encryption in Swift: the same formats as
// shared/crypto/crypto.js, held to the pinned vectors in tests/vectors/.
// NapsackCryptoChecks is shared/crypto/vector-checks.js in Swift: the tests run
// it on a Mac (`swift test`), and the app runs it on a phone.
import PackageDescription

let package = Package(
    name: "NapsackCrypto",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NapsackCrypto", targets: ["NapsackCrypto"]),
        .library(name: "NapsackCryptoChecks", targets: ["NapsackCryptoChecks"]),
    ],
    targets: [
        .target(name: "NapsackCrypto"),
        .target(name: "NapsackCryptoChecks", dependencies: ["NapsackCrypto"]),
        .testTarget(name: "NapsackCryptoTests", dependencies: ["NapsackCrypto", "NapsackCryptoChecks"]),
    ]
)
