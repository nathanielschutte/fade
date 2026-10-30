import SwiftUI

@main
struct NapsackApp: App {
    @State private var session = Session()
    @AppStorage("server") private var server = AppInfo.defaultServer

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
                        HomeScreen(account: account)
                            .sheet(isPresented: .constant(session.recoveryKeyToShow != nil)) {
                                RecoveryKeyScreen(key: session.recoveryKeyToShow ?? "") { session.recoveryKeyToShow = nil }
                            }
                    }
                }
            }
            .environment(session)
            .task { await session.restore(defaultServer: server) }
        }
    }
}
