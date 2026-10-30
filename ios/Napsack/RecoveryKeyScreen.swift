import SwiftUI
import UIKit

/// A new account's recovery key, shown once (the web app's words). It stays
/// until the person says they've saved it: napsack can't show it again.
struct RecoveryKeyScreen: View {
    let key: String
    let done: () -> Void
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(key)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } footer: {
                    Text("If you forget your password, this key gets you back in with all your messages. Write it down or keep it in a password manager. napsack can't show it again, and nobody can recover it for you.")
                }
                Section {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = key
                        copied = true
                    }
                    Toggle("I've saved it somewhere safe", isOn: $saved)
                }
                Section {
                    Button("Done", action: done).disabled(!saved)
                }
            }
            .navigationTitle("Your recovery key")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}

#Preview {
    RecoveryKeyScreen(key: "7XKQ-2M4P-9TBV-H3C1-ZQ8R-5NWD-A6EG-0JFY") {}
}
