import Foundation
import Security
import Synchronization

/// The Keychain, for what has to stay secret on this phone: the session token
/// and the private key (Session.swift), and friends' pinned keys (Pins.swift).
/// Items are readable only while the phone is unlocked, and only on this
/// phone: never synced to other devices, never restored from a backup onto
/// another (docs/design/mobile.md, Keys on the phone). Every item is under one
/// service, the app's, and signing out deletes them all (PhoneData). Tests
/// use a service of their own, so they never touch the app's items.
enum Keychain {
    static let service = Bundle.main.bundleIdentifier ?? "napsack"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    static func save(_ data: Data, account: String, service: String = Keychain.service) throws {
        try delete(account: account, service: service)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// The item's bytes, or nil if there's none.
    static func read(account: String, service: String = Keychain.service) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    static func delete(account: String, service: String = Keychain.service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    /// Every item under `service`, gone (signing out, PhoneData). Anything
    /// asked to be kept from before is refused from then on (`wipes`).
    static func deleteAll(service: String = Keychain.service) {
        wiped.withLock { $0[service, default: 0] += 1 }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    /// The names of the items under `service` (what's left, for tests).
    static func accounts(service: String = Keychain.service) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// How many times `service`'s items have all been deleted: something made
    /// before a sign-out (a pin book) checks it hasn't changed before saving,
    /// so nothing of that account is kept again after (Pins.swift).
    static func wipes(service: String = Keychain.service) -> Int {
        wiped.withLock { $0[service] ?? 0 }
    }

    private static let wiped = Mutex<[String: Int]>([:])
}
