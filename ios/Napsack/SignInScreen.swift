import SwiftUI

/// Signing in, or creating an account. Like the web app's form: one screen,
/// and a button to switch between the two. It signs in to napsack's server
/// unless an Admin pointed this phone at another (DeveloperScreen); then it
/// says which, with a way back.
struct SignInScreen: View {
    @Environment(Session.self) private var session
    @AppStorage("server") private var server = AppInfo.defaultServer
    @State private var creating = false
    @State private var username = ""
    @State private var password = ""
    @State private var inviteCode = ""
    /// Whether the server asks new accounts for an invite code (its /api/config).
    @State private var inviteRequired = false
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
                        .textContentType(creating ? .newPassword : .password)
                        .onSubmit(submit)
                    if creating && inviteRequired {
                        TextField("Invite code", text: $inviteCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your password stays on this phone; the server gets a key made from it.")
                        if creating {
                            Text("Your password also unlocks your messages. If you forget it, they can't be recovered.")
                        }
                        if let message = problem ?? session.notice {
                            Text(message).foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    Button(working ? (creating ? "Creating your keys…" : "Unlocking…") : (creating ? "Create account" : "Sign in"), action: submit)
                        .disabled(working || username.isEmpty || password.isEmpty)
                    Button(creating ? "Have an account? Sign in" : "New here? Create an account") {
                        creating.toggle()
                        problem = nil
                    }
                    .disabled(working)
                }
                if server != AppInfo.defaultServer {
                    Section {
                        LabeledContent("Server", value: server)
                        Button("Use napsack's server") { server = AppInfo.defaultServer }
                    } footer: {
                        Text("An Admin pointed this phone at another server.")
                    }
                }
            }
            .navigationTitle("napsack")
            // Whether to ask for an invite code depends on the server.
            .task(id: "\(creating) \(server)") {
                guard creating, let config = try? await Server(server).config() else { return }
                inviteRequired = config.inviteRequired
            }
        }
    }

    private func submit() {
        guard !working, !username.isEmpty, !password.isEmpty else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                if creating {
                    try await session.signUp(server: server, username: username, password: password, inviteCode: inviteRequired ? inviteCode : nil)
                } else {
                    try await session.signIn(server: server, username: username, password: password)
                }
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
