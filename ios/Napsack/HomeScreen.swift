import SwiftUI

/// Where a signed-in person lands, until the chat list takes its place
/// (plan-ios.md): who's signed in, where, and signing out.
struct HomeScreen: View {
    @Environment(Session.self) private var session
    let account: Account
    @State private var signingOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Signed in as", value: "@\(account.user.username)")
                    if let name = account.user.displayName, !name.isEmpty {
                        LabeledContent("Shown to friends as", value: name)
                    }
                    LabeledContent("Server", value: URL(string: account.server)?.host() ?? account.server)
                } footer: {
                    Text("Your chats come next.")
                }
                Section {
                    NavigationLink("Developer") { DeveloperScreen() }
                }
                Section {
                    Button(signingOut ? "Signing out…" : "Sign out", role: .destructive) {
                        signingOut = true
                        Task { await session.signOut() }
                    }
                    .disabled(signingOut)
                } footer: {
                    Text("Signing out removes your keys from this phone. Your messages stay on the server, and your password brings them back.")
                }
            }
            .navigationTitle(account.user.displayName ?? account.user.username)
        }
    }
}
