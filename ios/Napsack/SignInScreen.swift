import SwiftUI

/// Signing in, or creating an account. Like the web app's form: one screen,
/// and a button to switch between the two. It signs in to the one server this
/// build talks to (AppInfo.server); outside production it says which.
struct SignInScreen: View {
    @Environment(Session.self) private var session
    private let server = AppInfo.server
    /// Which server, outside production (nothing in production).
    @State private var serverLabel: String?
    @State private var creating = false
    @State private var username = ""
    @State private var password = ""
    @State private var inviteCode = ""
    /// Whether the server asks new accounts for an invite code (its /api/config).
    @State private var inviteRequired = false
    @State private var working = false
    @State private var problem: String?
    @State private var recovering = false

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
                    if !creating {
                        Button("Forgot your password?") { recovering = true }.disabled(working)
                    }
                }
                if let serverLabel {
                    Section {
                        LabeledContent("Server", value: serverLabel)
                    }
                }
            }
            .navigationTitle("napsack")
            .sheet(isPresented: $recovering) { RecoverScreen(username: username) }
            // Whether to ask for an invite code depends on the server.
            .task(id: creating) {
                let config = try? await Server(server).config()
                serverLabel = AppInfo.serverLabel(environment: config?.environment)
                if creating, let config { inviteRequired = config.inviteRequired }
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

/// Back in after a forgotten password: the recovery key saved at sign-up
/// (everything kept), or a reset code from an Admin (a new key; old messages
/// can't be read). The web app's words.
struct RecoverScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var username: String
    @State private var secret = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Recovery key or reset code", text: $secret).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    SecureField("New password", text: $password).textContentType(.newPassword)
                    SecureField("New password again", text: $confirm).textContentType(.newPassword)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Use the recovery key you saved when you signed up, or a reset code from an admin.")
                        if Session.secretKind(secret) == .resetCode {
                            Text("Reset code: you'll get your account and friends back, but messages from before can't be read, and your friends will see a new safety code.")
                        }
                        if let problem { Text(problem).foregroundStyle(.red) }
                    }
                }
                Section {
                    Button(working ? "Unlocking…" : "Get back in", action: submit)
                        .disabled(working || username.isEmpty || secret.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Forgot password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func submit() {
        guard password == confirm else { problem = SignInError.mismatch.errorDescription; return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await session.recover(server: AppInfo.server, username: username, secret: secret, newPassword: password)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

#Preview {
    SignInScreen().environment(Session())
}
