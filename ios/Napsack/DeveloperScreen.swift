import SwiftUI

/// Debugging tools, for Admins only (from Settings): what the server says
/// about itself, what this app says it is, and the encryption's checks run on
/// this phone (VectorScreen). The server is the build's own (AppInfo.server).
struct DeveloperScreen: View {
    private let address = AppInfo.server
    @State private var config: ServerConfig?
    @State private var problem: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: address)
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
            } header: {
                Text("Server")
            } footer: {
                Text("Set by the build (NAPSACK_SERVER_URL in Config/Local.xcconfig). Check shows what the server says about itself.")
            }
            Section("This app") {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                LabeledContent("Says it is", value: AppInfo.clientHeader)
            }
            Section {
                NavigationLink("Run every encryption check") { VectorScreen() }
            } header: {
                Text("Encryption")
            } footer: {
                Text("Every format against the pinned vectors, on this phone, and how long a sign-in's key derivation takes here. Nothing is sent anywhere.")
            }
        }
        .navigationTitle("Developer")
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
}

#Preview {
    NavigationStack { DeveloperScreen() }
}
