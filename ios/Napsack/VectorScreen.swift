import NapsackCryptoChecks
import SwiftUI

/// Runs every encryption check against the pinned vectors on this phone: the
/// same checks `swift test` runs on a Mac (NapsackCryptoChecks), with the same
/// vectors, copied into the app when it's built. Also shows how long the
/// password's key derivation takes here, which has to stay near a second.
@MainActor @Observable final class VectorRun {
    private(set) var results: [CheckResult] = []
    private(set) var running = false
    private(set) var problem: String?
    private(set) var total: Duration?

    /// The check that derives keys from the vector's password: one 600,000-round PBKDF2.
    static let derivation = "password derives the vector's auth key"

    var passed: Int { results.filter(\.ok).count }
    var derivationTime: Duration? { results.first { $0.name == Self.derivation }?.duration }

    /// The vectors Xcode copied into the app (the project's `vectors` folder reference).
    static func bundled() throws -> Vectors {
        guard let folder = Bundle.main.url(forResource: "vectors", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Vectors.load(from: folder)
    }

    func start() {
        guard !running else { return }
        running = true
        results = []
        problem = nil
        total = nil
        Task {
            defer { running = false }
            let clock = ContinuousClock()
            let began = clock.now
            do {
                let vectors = try Self.bundled()
                // The checks are slow on purpose in places, so off the main thread,
                // each result shown as it comes.
                let stream = AsyncStream<CheckResult> { continuation in
                    Task.detached(priority: .userInitiated) {
                        _ = VectorChecks.run(vectors) { continuation.yield($0) }
                        continuation.finish()
                    }
                }
                for await result in stream { results.append(result) }
                total = clock.now - began
            } catch {
                problem = "The vectors aren't in this build: \(error.localizedDescription)"
            }
        }
    }
}

struct VectorScreen: View {
    @State private var run = VectorRun()

    var body: some View {
        List {
            Section {
                if let problem = run.problem {
                    Text(problem).foregroundStyle(.red)
                } else if run.results.isEmpty {
                    Text("Running…").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Passed", value: "\(run.passed) of \(run.results.count)")
                        .foregroundStyle(run.passed == run.results.count ? Color.primary : .red)
                    if let time = run.derivationTime {
                        LabeledContent("Key derivation (PBKDF2)", value: ms(time))
                    }
                    if let total = run.total {
                        LabeledContent("All of them", value: ms(total))
                    }
                }
            } footer: {
                Text("The same checks as the web app's and `swift test`'s, against the pinned vectors. Any failure means this phone would disagree with the other apps about the bytes.")
            }
            Section("Checks") {
                ForEach(run.results) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.ok ? Color.accentColor : .red)
                            Text(result.name)
                            Spacer()
                            Text(ms(result.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let error = result.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Encryption checks")
        .toolbar {
            Button("Run again") { run.start() }.disabled(run.running)
        }
        .onAppear { run.start() }
    }

    private func ms(_ d: Duration) -> String {
        d.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, fractionalPart: .hide))
    }
}

#Preview {
    NavigationStack { VectorScreen() }
}
