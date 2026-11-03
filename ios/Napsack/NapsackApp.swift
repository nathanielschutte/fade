import SwiftUI

@main
struct NapsackApp: App {
    /// For notifications: the device token, and a tapped one (Notifications.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = Session()
    /// Lock napsack with Face ID, if it's on (AppLock.swift).
    @State private var lock = AppLock.shared
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
                            .overlay {
                                // Locked, or in the app switcher with the lock on: nothing shows through.
                                if lock.locked || (lock.enabled && scenePhase != .active) {
                                    LockCover(lock: lock, active: scenePhase == .active)
                                }
                            }
                            .sheet(isPresented: .constant(session.recoveryKeyToShow != nil || session.passkeyOffer != nil)) {
                                // A new account's recovery key, then the passkey napsack recommends (Passkeys.swift).
                                if let key = session.recoveryKeyToShow {
                                    RecoveryKeyScreen(key: key) { session.recoveryKeyToShow = nil }
                                } else {
                                    PasskeyOfferScreen()
                                }
                            }
                    }
                }
            }
            .environment(session)
            .task { await session.restore(server: AppInfo.server) }
            // An add-a-friend link opened on the phone (Universal Links, Links.swift).
            .onOpenURL { url in Task { await FriendLinks.shared.open(url) } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    Task { await Reporter.shared.flush() }  // before iOS suspends the app
                    lock.left()
                } else if phase == .active {
                    lock.returned()
                }
            }
        }
    }
}
