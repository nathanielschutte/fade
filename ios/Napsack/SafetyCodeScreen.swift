import SwiftUI

/// A direct chat's encryption, in the web app's words, and the code to compare
/// with the friend. When their key changed, comparing is how you trust it.
struct SafetyCodeScreen: View {
    @Environment(\.dismiss) private var dismiss
    let username: String
    let code: String
    let keyChanged: Bool
    let trust: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Messages and pics with \(username) are encrypted on your device. Only the two of you can read them, not even the napsack server.")
                    Text("To be sure no one is in the middle, check that \(username) sees the same code:")
                    Text(Self.rows(code))
                        .font(.title2.monospacedDigit()).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("safety-code")
                    if keyChanged {
                        Text("This is the code for their new key. If it matches what \(username) sees, the new key is really theirs.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("The codes match: trust the new key") {
                            trust()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .navigationTitle("End-to-end encrypted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// Six groups of five digits, as two rows of three.
    static func rows(_ code: String) -> String {
        let groups = code.split(separator: " ")
        guard groups.count == 6 else { return code }
        return groups[..<3].joined(separator: " ") + "\n" + groups[3...].joined(separator: " ")
    }
}

/// Shown at the top of a direct chat whose key changed: what it may mean, and
/// the two ways forward. Accepting unchecked takes two taps, as on the web.
struct KeyWarning: View {
    let friend: Friend
    let compare: () -> Void
    let accept: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text("\(friend.username)'s safety code changed. ").bold() + Text(why + " Sending is blocked until you decide."))
                .font(.callout)
            HStack {
                Button("Compare safety codes", action: compare).buttonStyle(.borderedProminent)
                Button(confirming ? "Tap again to accept the new key" : "Accept without checking") {
                    if confirming { accept() } else { confirming = true }
                }
                .buttonStyle(.bordered)
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("key-warning")
    }

    private var why: String {
        guard let reset = friend.keyResetAt else {
            return "Keys only change when an admin resets an account, and napsack doesn't say this one was. Someone may be trying to read this chat."
        }
        let date = Date(timeIntervalSince1970: TimeInterval(reset)).formatted(date: .long, time: .omitted)
        return "napsack says an admin reset \(friend.username)'s account on \(date), which gives them a new key. Compare safety codes to be sure it's really them."
    }
}
