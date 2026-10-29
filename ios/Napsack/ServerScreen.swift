import SwiftUI

/// The development screen, until the real app has screens: which server this
/// app talks to and what it says about itself, and the encryption's checks
/// run on this phone (VectorScreen).
struct ServerScreen: View {
    @AppStorage("server") private var address = AppInfo.defaultServer
    @State private var config: ServerConfig?
    @State private var problem: String?
    @State private var checking = false

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
                    NavigationLink("Run every encryption check") { VectorScreen() }
                } header: {
                    Text("Encryption")
                } footer: {
                    Text("Every format against the pinned vectors, on this phone, and how long a sign-in's key derivation takes here. Nothing is sent anywhere.")
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
}

#Preview {
    ServerScreen()
}
