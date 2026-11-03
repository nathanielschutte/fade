import SwiftUI
import UserNotifications

/// Notifications on the phone, through Apple's push service (the server's
/// apns.rs). Once signed in, the app asks once to show them; if they're
/// allowed, iOS hands it a device token, which goes to the server for this
/// session (`POST /api/push/apns`) on every launch. A notification says who,
/// never what, as on the web. Tapping one opens its chat, which reads it
/// (once napsack is unlocked, if it's locked); opening the app clears the ones
/// delivered; the icon's badge is the Chats tab's count, and the server keeps
/// it right while the app is away. Signing out takes them all away, and stops
/// them coming until someone signs in again.
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

    /// What iOS does for the app: the phone's own, or a stand-in in tests.
    @ObservationIgnored private let system: any NotificationSystem
    /// Napsack's lock (AppLock): a tapped notification waits until it's unlocked.
    @ObservationIgnored private let lock: AppLock
    /// A notification tapped, until the chat list opens it.
    private var tapped: Destination?
    /// This install's token from Apple, lowercase hex, once iOS has given it.
    private(set) var deviceToken: String?
    /// The signed-in account notifications go to (set by the chat list).
    private var account: Account?
    /// Which token went to the server for which session, so a launch sends it once.
    private var registered: (token: String, session: String)?

    init(system: any NotificationSystem = PhoneNotifications(), lock: AppLock = .shared) {
        self.system = system
        self.lock = lock
    }

    /// Apple's server that knows this build's tokens: Xcode builds are the
    /// sandbox's, TestFlight and the App Store's production's (the
    /// `aps-environment` entitlement, Config/Napsack.entitlements).
    static let environment = Bundle.main.object(forInfoDictionaryKey: "NapsackAPNsEnvironment") as? String == "production"
        ? "production" : "sandbox"

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// The icon's number, the Chats tab's: chats with something unread or
    /// unopened, muted and hidden ones not counted. The server counts the same
    /// way for the badges it sends (apns.rs, `waiting_chats`).
    static func badge(_ rows: [ChatRow]) -> Int {
        rows.filter { $0.waiting != nil && !$0.muted && !$0.hidden }.count
    }

    /// Where a tapped notification goes, once napsack is unlocked: a chat is
    /// opened, and so read, only by someone who can see it. The chat list
    /// sets it to nil as it opens it.
    var opened: Destination? {
        get { lock.locked ? nil : tapped }
        set { tapped = newValue }
    }

    /// A notification was tapped (AppDelegate), with the `url` it carries.
    func tap(url: String) {
        // Back after a minute away, napsack locks first, whichever iOS tells
        // the app first: this tap, or the scene coming back (NapsackApp).
        lock.returned()
        if let destination = Destination(url: url) { tapped = destination }
    }

    /// Signed in (on every launch): ask once, and register if allowed.
    func start(for account: Account) async {
        self.account = account
        switch await system.authorization() {
        case .notDetermined:
            let allowed = await system.askToNotify()
            Reporter.shared.report(.info, "notifications asked", ["allowed": allowed ? "yes" : "no"])
            guard allowed else { return }
        case .denied:
            return
        default:
            break
        }
        // The answer can come after signing out (the question waits on the person).
        guard self.account?.token == account.token else { return }
        system.register()
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
        system.clearDelivered()
    }

    /// The icon's number: chats waiting, as the Chats tab counts them.
    func setBadge(_ count: Int) {
        system.setBadge(count)
    }

    /// Signed out: nothing of the account stays in Notification Center or on
    /// the icon, and this install stops getting notifications until someone
    /// signs in again (Apple's advice when an account signs out). The server
    /// ends the session's too, but only if it heard the sign-out; this way an
    /// offline sign-out still stops them.
    func signedOut() {
        account = nil
        registered = nil
        tapped = nil
        deviceToken = nil  // unregistering ends it; the next sign-in is given one again
        system.clearDelivered()
        system.setBadge(0)
        system.unregister()
    }
}

/// What the app asks of iOS for its notifications. The phone's own in the
/// app; tests give a stand-in, so they never prompt or touch the icon.
@MainActor protocol NotificationSystem: AnyObject {
    func authorization() async -> UNAuthorizationStatus
    /// Asks the person, once; whether they allowed it.
    func askToNotify() async -> Bool
    func register()
    func unregister()
    func clearDelivered()
    func setBadge(_ count: Int)
}

/// The phone's own: Notification Center, the icon, and Apple's push service.
final class PhoneNotifications: NotificationSystem {
    func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func askToNotify() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func register() { UIApplication.shared.registerForRemoteNotifications() }
    func unregister() { UIApplication.shared.unregisterForRemoteNotifications() }
    func clearDelivered() { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
    func setBadge(_ count: Int) { UNUserNotificationCenter.current().setBadgeCount(count) }
}

/// Keeps the icon's number at the Chats tab's while the list is loaded: as it
/// changes, and again as the app goes to the background, so the icon starts
/// out right; from then, notifications and the server's badge updates carry
/// it (apns.rs).
struct AppBadge: ViewModifier {
    let notifications: Notifications
    /// Nil until the list has loaded: before that, nothing is known.
    let count: Int?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: count, initial: true) { _, count in
                if let count { notifications.setBadge(count) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, let count { notifications.setBadge(count) }
            }
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
    /// send then either, but one can cross with the app coming up): no banner,
    /// and the app keeps the badge itself.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let url = response.notification.request.content.userInfo["url"] as? String ?? ""
        await MainActor.run { Notifications.shared.tap(url: url) }
    }
}
