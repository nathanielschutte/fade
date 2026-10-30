import SwiftUI

@main
struct NapsackApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup {
            Group {
                switch session.state {
                case .starting:
                    ProgressView()
                case .signedOut:
                    SignInScreen()
                case .signedIn(let account):
                    HomeScreen(account: account)
                }
            }
            .environment(session)
            .task { await session.restore() }
        }
    }
}
