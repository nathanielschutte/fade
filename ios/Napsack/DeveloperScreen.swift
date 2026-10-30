import SwiftUI

/// Debugging tools, for Admins only (from the account menu): what a server
/// says about itself, what this app says it is, the encryption's checks run on
/// this phone (VectorScreen), and which server the next sign-in uses.
struct DeveloperScreen: View {
    /// The server this account is on.
    let signedInTo: String
    @AppStorage("server") private var address = AppInfo.defaultServer
    @State private var config: ServerConfig?
    @State private var problem: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Signed in to", value: signedInTo)
                TextField("https://staging.napsack.io", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(checking ? "Checking…" : "Check") { Task { await check() } }
                    .disabled(checking)
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
                if address != AppInfo.defaultServer {
                    Button("Use napsack's server") { address = AppInfo.defaultServer }
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
                Text("The address is the server the next sign-in uses; sign out to go there. Check shows what it says about itself.")
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
    NavigationStack { DeveloperScreen(signedInTo: AppInfo.defaultServer) }
}
