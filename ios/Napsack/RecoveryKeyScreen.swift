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
                    // To Files, a password manager, or Notes: wherever they keep such things (F23).
                    ShareLink(item: Self.keepsake(key), preview: SharePreview("napsack recovery key")) {
                        Label("Save or share", systemImage: "square.and.arrow.up")
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

    /// The key and what it's for, as the web app's download says it.
    static func keepsake(_ key: String) -> String {
        "napsack recovery key\n\n\(key)\n\nIf you forget your password, choose \"Forgot your password?\" when you sign in and enter this key: you get back in with all your messages. Keep it somewhere safe and private.\n"
    }
}

/// How strong a new password is (F23), as the web app says it: a hint while
/// it's chosen, never a rule beyond the server's 8 characters. Length counts
/// most; a few unrelated words is the advice.
enum PasswordStrength: Equatable {
    case short, weak(String), good, strong

    static let common: Set<String> = ["password", "password1", "12345678", "123456789", "1234567890", "qwertyuiop",
                                      "qwerty123", "iloveyou", "11111111", "abc12345", "letmein1", "napsack1",
                                      "baseball", "football", "sunshine"]

    static func of(_ password: String) -> PasswordStrength {
        guard password.count >= 8 else { return .short }
        let kinds = [password.contains(where: \.isLowercase), password.contains(where: \.isUppercase),
                     password.contains(where: \.isNumber), password.contains(where: { !$0.isLetter && !$0.isNumber })]
            .filter { $0 }.count
        if common.contains(password.lowercased()) || Set(password).count <= 3 {
            return .weak("Easy to guess. A few unrelated words make a strong one.")
        }
        if password.count >= 16 || (password.count >= 12 && kinds >= 3) { return .strong }
        if password.count >= 12 || (password.count >= 10 && kinds >= 3) { return .good }
        return .weak("Weak. Longer is stronger: try a few unrelated words.")
    }

    var words: String {
        switch self {
        case .short: "Too short: at least 8 characters."
        case .weak(let words): words
        case .good: "Good. Longer is even better."
        case .strong: "Strong."
        }
    }

    var color: Color {
        switch self {
        case .short, .weak: .red
        case .good: .secondary
        case .strong: .green
        }
    }
}

/// The hint under a new password's field, once something's typed.
struct StrengthHint: View {
    let password: String

    var body: some View {
        if !password.isEmpty {
            let strength = PasswordStrength.of(password)
            Text(strength.words).font(.footnote).foregroundStyle(strength.color)
        }
    }
}

#Preview {
    RecoveryKeyScreen(key: "7XKQ-2M4P-9TBV-H3C1-ZQ8R-5NWD-A6EG-0JFY") {}
}
