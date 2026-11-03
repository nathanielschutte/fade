import SwiftUI
import UserNotifications

/// Notifications on the phone, through Apple's push service (the server's
/// apns.rs). Once signed in, the app asks once to show them; if they're
/// allowed, iOS hands it a device token, which goes to the server for this
/// session (`POST /api/push/apns`) on every launch. A notification says who,
/// never what, as on the web. Tapping one opens its chat, which reads it;
/// opening the app clears the ones delivered; the icon's badge is the Chats
/// tab's count. Signing out takes them all away (Session.endLocally), and the
/// server stops sending with the session.
@MainActor @Observable final class Notifications {
    static let shared = Notifications()

    /// Where tapping a notification goes, from its `url` (the web's, as the
    /// server sends it: `/#chat=7`, `/#group=3`, `/#friends`).
    enum Destination: Equatable {
        case chat(ChatRow.Kind)
        case friends

        init?(url: String) {
            guard let hash = url.split(separator: "#", maxSplits: 1).last, url.contains("#") else { return nil }
            let parts = hash.split(separator: "=", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count > 1 ? Int64(parts[1]) : nil) {
            case ("chat", let id?) where id > 0: self = .chat(.friend(id))
            case ("group", let id?) where id > 0: self = .chat(.group(id))
            case ("friends", _): self = .friends
            default: return nil
            }
        }
    }

    /// A notification tapped, waiting for the chat list to open it.
    var opened: Destination?
    /// This install's token from Apple, lowercase hex, once iOS has given it.
    private(set) var deviceToken: String?
    /// The signed-in account notifications go to (set by the chat list).
    private var account: Account?
    /// Which token went to the server for which session, so a launch sends it once.
    private var registered: (token: String, session: String)?

    /// Apple's server that knows this build's tokens: Xcode builds are the
    /// sandbox's, TestFlight and the App Store's production's (the
    /// `aps-environment` entitlement, Config/Napsack.entitlements).
    static let environment = Bundle.main.object(forInfoDictionaryKey: "NapsackAPNsEnvironment") as? String == "production"
        ? "production" : "sandbox"

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Signed in (on every launch): ask once, and register if allowed.
    func start(for account: Account) async {
        self.account = account
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let allowed = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            Reporter.shared.report(.info, "notifications asked", ["allowed": allowed ? "yes" : "no"])
            guard allowed else { return }
        case .denied:
            return
        default:
            break
        }
        UIApplication.shared.registerForRemoteNotifications()
        await sendToken()
    }

    /// iOS gave the app its token (AppDelegate).
    func received(token: Data) async {
        deviceToken = Self.hex(token)
        await sendToken()
    }

    private func sendToken() async {
        guard let account, let deviceToken,
              registered?.token != deviceToken || registered?.session != account.token else { return }
        do {
            try await Server(account.server).registerAPNs(token: deviceToken, environment: Self.environment, auth: account.token)
            registered = (deviceToken, account.token)
        } catch {
            Reporter.shared.report(.warn, "notifications: registering failed", ["error": String(describing: error)])
        }
    }

    /// The app is on screen: what was delivered has been seen here.
    func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// The icon's number: chats waiting, as the Chats tab counts them.
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// Signed out: nothing of the account stays in Notification Center or on the icon.
    func signedOut() {
        account = nil
        registered = nil
        opened = nil
        clearDelivered()
        setBadge(0)
    }
}

/// Where iOS tells the app about notifications: its token, and a tap.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Notifications.shared.received(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Task { @MainActor in
            Reporter.shared.report(.warn, "notifications: no device token", ["error": String(describing: error)])
        }
    }

    /// While napsack is on screen the chat shows what came (the server doesn't
    /// send then either, but one can cross with the app coming up): no banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let url = response.notification.request.content.userInfo["url"] as? String ?? ""
        await MainActor.run {
            if let destination = Notifications.Destination(url: url) {
                Notifications.shared.opened = destination
            }
        }
    }
}
