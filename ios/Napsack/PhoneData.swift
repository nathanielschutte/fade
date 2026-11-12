import Foundation

/// Everything napsack keeps on this phone, and where. Signing out, a session
/// the server ended, and deleting the account forget all of it (Session,
/// `endLocally`; CLAUDE.md, Security: nothing of the account stays on the
/// device), as the web app does in the browser (app.js, `forgetEverything`):
///
/// - **The Keychain**: the session (its token, who you are, the private key)
///   and every account's pinned keys (Pins.swift). Every item of the app's
///   goes: pins too (Nate, 2026-11-06), so a new sign-in pins afresh.
/// - **Settings** (UserDefaults): the Face ID lock, the announcement you
///   closed. The app's whole domain goes.
/// - **Kept answers and pictures** (ResponseCache), in Application Support,
///   and beside them texts not yet sent, sealed under a key in the Keychain
///   (UnsentTexts).
/// - **Temporary files**: videos opened (Conversation.temporaryVideo),
///   recorded, or made smaller to send. Each is deleted once it's used; this
///   catches any an interruption left.
/// - **The system's shared URL cache and cookies**: napsack's own requests
///   never use them (NetworkTransport), so nothing of the account is there.
///   Emptied anyway, as a backstop.
///
/// Nothing is kept: which server a build talks to is in its Info.plist, not
/// here. Notifications and the badge go too (Notifications.signedOut), and
/// what's in memory goes with the signed-in screens (NapsackApp: a new
/// session is a new screen). Tests make one with places of their own, so
/// they never touch the app's.
struct PhoneData: Sendable, Equatable {
    /// The Keychain service every item is under.
    var keychainService: String
    /// The settings' domain (a UserDefaults suite name).
    var defaults: String
    /// Where the server's answers are kept (ResponseCache.root).
    var cache: URL
    /// Where files are written for a moment.
    var temporary: URL
    /// Whether to empty the system's shared URL cache and cookies too (the app's own; tests leave them).
    var systemCaches: Bool

    /// The app's own places.
    static let phone = PhoneData(keychainService: Keychain.service, defaults: Bundle.main.bundleIdentifier ?? "napsack",
                                 cache: ResponseCache.root, temporary: FileManager.default.temporaryDirectory,
                                 systemCaches: true)

    /// Everything, gone.
    func forget() {
        Keychain.deleteAll(service: keychainService)
        ResponseCache.wipeAll(root: cache)
        settings.removePersistentDomain(forName: defaults)
        for file in (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        if systemCaches {
            URLCache.shared.removeAllCachedResponses()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        }
    }

    /// What's there now, one line per Keychain item, setting, and file (tests).
    func kept() -> [String] {
        let keychain = Keychain.accounts(service: keychainService).map { "keychain: \($0)" }
        let settings = (settings.persistentDomain(forName: defaults) ?? [:]).keys.map { "setting: \($0)" }
        let files = [cache, temporary].flatMap { folder in
            (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map { "file: \($0.path(percentEncoded: false))" }
        }
        return (keychain + settings + files).sorted()
    }

    /// The app's own settings are the standard ones; a suite of its own otherwise (tests).
    private var settings: UserDefaults {
        defaults == Bundle.main.bundleIdentifier ? .standard : UserDefaults(suiteName: defaults) ?? .standard
    }
}
