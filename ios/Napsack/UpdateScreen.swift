import SwiftUI

/// The server needs a newer app (a 426, or its `/api/config` says so at
/// launch): nothing else works until it's updated, so this is all that shows.
/// The App Store link comes with the App Store (plan-ios.md).
struct UpdateScreen: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("napsack needs an update", systemImage: "arrow.down.app")
        } description: {
            Text(message)
        }
    }
}

#Preview {
    UpdateScreen(message: "This version of napsack is too old. Update to 1.2.0 or newer to keep using it.").environment(Session())
}
