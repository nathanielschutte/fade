import Foundation
import Security
import Testing
@testable import Napsack

/// The Keychain wrapper keeps, replaces, and forgets items, and keeps them the
/// way the keys must be kept: this phone only, only while it's unlocked.
@Suite struct KeychainTests {
    let item = "test-\(UUID().uuidString)"

    @Test func keepsReplacesAndForgets() throws {
        defer { try? Keychain.delete(account: item) }
        #expect(try Keychain.read(account: item) == nil)
        try Keychain.save(Data("first".utf8), account: item)
        try Keychain.save(Data("second".utf8), account: item)
        #expect(try Keychain.read(account: item) == Data("second".utf8))
        try Keychain.delete(account: item)
        #expect(try Keychain.read(account: item) == nil)
        try Keychain.delete(account: item)  // forgetting twice is fine
    }

    @Test func onlyOnThisPhoneAndOnlyWhileUnlocked() throws {
        defer { try? Keychain.delete(account: item) }
        try Keychain.save(Data("secret".utf8), account: item)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: item,
            kSecReturnAttributes as String: true,
        ]
        var found: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess)
        let attributes = try #require(found as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect((attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
    }
}
