import LocalAuthentication
import SwiftUI

/// Lock napsack with Face ID (F24): optional, off until turned on in
/// Settings (after one successful check), and only on this phone. When on,
/// the app is locked when it opens and when it comes back after a minute
/// away, and its screen is covered in the app switcher. Face ID (or Touch
/// ID) with the phone's passcode as the fallback. Signing out turns it off.
@MainActor @Observable final class AppLock {
    static let shared = AppLock()
    static let enabledKey = "napsack.appLock"
    /// Away at least this long, the app locks again.
    nonisolated static let after: TimeInterval = 60

    private(set) var enabled: Bool
    /// Covering the app now: locked, or off screen with the lock on.
    private(set) var locked: Bool
    private(set) var problem: String?
    private var leftAt: Date?
    private var unlocking = false

    /// `enabled` is the saved choice (tests give their own).
    init(enabled: Bool = UserDefaults.standard.bool(forKey: AppLock.enabledKey)) {
        self.enabled = enabled
        locked = enabled  // when the app opens
    }

    /// What this phone has: "Face ID", "Touch ID", or its passcode.
    static var method: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your passcode"
        }
    }

    /// Whether coming back after `away` seconds locks it again.
    nonisolated static func locksAgain(away: TimeInterval) -> Bool { away >= after }

    func left(at time: Date = .now) {
        if leftAt == nil { leftAt = time }
    }

    func returned(at time: Date = .now) {
        defer { leftAt = nil }
        guard enabled, let leftAt, Self.locksAgain(away: time.timeIntervalSince(leftAt)) else { return }
        locked = true
    }

    /// Face ID (or the passcode); unlocks on success.
    func unlock() async {
        guard locked, !unlocking else { return }
        unlocking = true
        defer { unlocking = false }
        if await Self.check("Unlock napsack") {
            locked = false
            problem = nil
        } else {
            problem = "napsack stays locked. Try again."
        }
    }

    /// Turning it on asks once, so it's sure to work; off needs nothing.
    func set(_ on: Bool) async {
        if on, !(await Self.check("Lock napsack with \(Self.method)")) { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
    }

    /// Signed out: off, and nothing covering the sign-in screen.
    func signedOut() {
        enabled = false
        locked = false
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
    }

    private static func check(_ reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// What covers napsack while it's locked, or in the app switcher with the
/// lock on: nothing of the chats shows through.
struct LockCover: View {
    let lock: AppLock
    let active: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("napsack is locked").font(.headline)
                if active {
                    Button("Unlock with \(AppLock.method)") { Task { await lock.unlock() } }
                        .buttonStyle(.borderedProminent)
                    if let problem = lock.problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        // Asks once as it comes up; after that, the button. (Asking again on
        // every return to the foreground would loop: Face ID's own prompt
        // takes the app off the foreground and back.)
        .task { await lock.unlock() }
    }
}
