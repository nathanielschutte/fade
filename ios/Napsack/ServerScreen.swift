import NapsackCrypto
import SwiftUI

/// The development screen, until the real app has screens: which server this
/// app talks to and what it says about itself, and how long a sign-in's key
/// derivation takes on this phone (it has to stay near a second; mobile.md).
struct ServerScreen: View {
    @AppStorage("server") private var address = AppInfo.defaultServer
    @State private var config: ServerConfig?
    @State private var problem: String?
    @State private var checking = false
    @State private var derivation: Duration?
    @State private var deriving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://staging.napsack.io", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(checking ? "Checking…" : "Check") { Task { await check() } }
                        .disabled(checking)
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    }
                    if let config {
                        LabeledContent("Version", value: config.serverVersion)
                        LabeledContent("Build", value: config.build)
                        LabeledContent("Copy", value: config.environment ?? "production")
                        LabeledContent("Message formats", value: formats(config.messageFormats))
                        LabeledContent("Group formats", value: config.groupMessageFormats.map(formats) ?? "not listed")
                        if let minimum = config.minimumIOS, ClientVersion.isOlder(AppInfo.version, than: minimum) {
                            Text("This server needs napsack \(minimum) or newer.").foregroundStyle(.red)
                        }
                    }
                }
                Section("This app") {
                    LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                    LabeledContent("Says it is", value: AppInfo.clientHeader)
                }
                Section {
                    Button(deriving ? "Deriving…" : "Time a sign-in's key derivation") { Task { await timeDerivation() } }
                        .disabled(deriving)
                    if let derivation {
                        LabeledContent("600,000 rounds of PBKDF2", value: derivation.formatted(.units(allowed: [.seconds, .milliseconds])))
                    }
                } header: {
                    Text("Encryption")
                } footer: {
                    Text("Made up credentials; nothing is sent anywhere.")
                }
            }
            .navigationTitle("napsack")
        }
    }

    private func formats(_ list: [Int]) -> String {
        list.map(String.init).joined(separator: ", ")
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            config = try await Server(address).config()
            problem = nil
        } catch {
            config = nil
            problem = error.localizedDescription
        }
    }

    private func timeDerivation() async {
        deriving = true
        defer { deriving = false }
        // Off the main thread: it's slow on purpose.
        derivation = await Task.detached(priority: .userInitiated) {
            ContinuousClock().measure {
                _ = try? E2E.deriveFromPassword(username: "timing", password: "correct horse battery")
            }
        }.value
    }
}

#Preview {
    ServerScreen()
}
