import SwiftUI

@main
struct NapsackApp: App {
    @State private var session = Session()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let message = session.updateNeeded {
                    UpdateScreen(message: message)
                } else {
                    switch session.state {
                    case .starting:
                        ProgressView()
                    case .signedOut:
                        SignInScreen()
                    case .signedIn(let account):
                        ChatListScreen(account: account)
                            // A new session is a new screen: nothing of the last one carries over.
                            .id(account.token)
                            .sheet(isPresented: .constant(session.recoveryKeyToShow != nil)) {
                                RecoveryKeyScreen(key: session.recoveryKeyToShow ?? "") { session.recoveryKeyToShow = nil }
                            }
                    }
                }
            }
            .environment(session)
            .task { await session.restore(server: AppInfo.server) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Task { await Reporter.shared.flush() } }  // before iOS suspends the app
            }
        }
    }
}
