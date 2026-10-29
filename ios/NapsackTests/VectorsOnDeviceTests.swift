import NapsackCryptoChecks
import Testing
@testable import Napsack

/// Every encryption check, against the vectors copied into the app, wherever
/// the tests run: the Simulator, or the iPhone itself (⌘U with it selected).
/// The package's own tests (`swift test`) run the same checks on the Mac.
@Suite struct VectorsOnDeviceTests {
    @MainActor @Test func everyCheckPassesHere() throws {
        let results = VectorChecks.run(try VectorRun.bundled())
        let failed = results.filter { !$0.ok }.map { "\($0.name): \($0.error ?? "false")" }
        #expect(results.count == 64)
        #expect(failed.isEmpty, "\(failed.joined(separator: "; "))")
        if let derivation = results.first(where: { $0.name == VectorRun.derivation }) {
            print("PBKDF2 (600,000 rounds) took \(derivation.duration) here")
        }
    }
}
