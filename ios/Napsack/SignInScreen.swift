import SwiftUI

/// Signing in with a napsack username and password, to the server below them.
/// Creating an account comes next (plan-ios.md).
struct SignInScreen: View {
    @Environment(Session.self) private var session
    @AppStorage("server") private var server = AppInfo.defaultServer
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(signIn)
                } footer: {
                    if let message = problem ?? session.notice {
                        Text(message).foregroundStyle(.red)
                    }
                }
                Section {
                    Button(working ? "Unlocking…" : "Sign in", action: signIn)
                        .disabled(working || username.isEmpty || password.isEmpty)
                }
                Section {
                    TextField("https://staging.napsack.io", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Your password stays on this phone; the server gets a key made from it.")
                }
            }
            .navigationTitle("napsack")
            .toolbar {
                NavigationLink("Developer") { DeveloperScreen() }
            }
        }
    }

    private func signIn() {
        guard !working, !username.isEmpty, !password.isEmpty else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await session.signIn(server: server, username: username, password: password)
                password = ""
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

#Preview {
    SignInScreen().environment(Session())
}
