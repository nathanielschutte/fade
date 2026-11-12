import CryptoKit
import Foundation

/// Texts not yet sent, kept on this phone through quitting napsack (Nate,
/// 2026-11-12; X57): every chat's outbox (on its way, held, or not sent),
/// written in the background whenever one changes and read back as the chat
/// list opens, so each goes again as the same message (its `client_id`: one
/// the server had already isn't stored twice). The words are the person's
/// own, so they're sealed with AES-GCM under a key made on this phone and
/// kept in the Keychain (this device only, readable while unlocked), in one
/// file beside the kept answers (ResponseCache: complete file protection, not
/// backed up). Signing out, a session the server ended, and deleting the
/// account delete both, with everything else (PhoneData). Pics stay in memory
/// (they're large), as do edits and reactions.
@MainActor final class UnsentTexts {
    /// One text, as kept.
    struct Text: Codable, Equatable, Sendable {
        /// Its `client_id`.
        let id: String
        let text: String
        let replyTo: Int64?
    }

    private let files: ResponseCache
    private let keyName: String
    private let keychainService: String
    /// The Keychain's wipes when this was made: a key isn't made after a sign-out.
    private let wipes: Int
    /// Every chat's, by chat (`Conversation.unsentKey`), oldest first.
    private(set) var chats: [String: [Text]] = [:]
    /// What's on the phone has been read (or there was nothing): only then is
    /// it written, so what can't be read now is never written over with nothing.
    private(set) var loaded = false

    static let file = "texts"

    /// The Keychain item an account's key is kept under (opening the app keeps the signed-in account's: Session).
    nonisolated static func keyName(_ account: Int64) -> String { "unsent-\(account)" }

    init(account: Int64, cache: ResponseCache? = nil, keychainService: String = Keychain.service) {
        files = (cache ?? ResponseCache(account: account)).unsent
        keyName = Self.keyName(account)
        self.keychainService = keychainService
        wipes = Keychain.wipes(service: keychainService)
    }

    /// What's kept, read, with what's been kept here since it couldn't be (a
    /// text in both is one text: its id). False if it can't be read now: the
    /// phone locked. A file whose key is gone can never be opened, so it
    /// counts as nothing.
    @discardableResult func load() -> Bool {
        if loaded { return true }
        guard let kept = readKept() else { return false }
        chats = kept.merging(chats) { there, here in
            let ids = Set(here.map(\.id))
            return there.filter { !ids.contains($0.id) } + here
        }
        loaded = true
        return true
    }

    /// A chat's texts now, kept in place of what was (nothing changes if they're the same).
    func keep(_ texts: [Text], for chat: String) {
        guard chats[chat] ?? [] != texts else { return }
        chats[chat] = texts.isEmpty ? nil : texts
        guard load() else { return }  // written once it can be read: nothing's lost meanwhile
        write()
    }

    /// The file's contents, or nil if it can't be read now. Nothing there (or nothing that can be opened) is empty.
    private func readKept() -> [String: [Text]]? {
        guard let sealed = files.read(Self.file) else {
            // There, but locked (complete file protection), or not there at all.
            return FileManager.default.fileExists(atPath: files.file(Self.file).path(percentEncoded: false)) ? nil : [:]
        }
        let key: Data?
        do { key = try Keychain.read(account: keyName, service: keychainService) } catch { return nil }
        guard let key, let box = try? AES.GCM.SealedBox(combined: sealed),
              let json = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
              let kept = try? JSONDecoder().decode([String: [Text]].self, from: json) else { return [:] }
        return kept
    }

    private func write() {
        guard let key = sealingKey(), let json = try? JSONEncoder().encode(chats),
              let sealed = try? AES.GCM.seal(json, using: key).combined else { return }
        files.write(sealed, Self.file)
    }

    /// The key, made the first time it's needed; nil after a sign-out, or if the Keychain won't have it.
    private func sealingKey() -> SymmetricKey? {
        guard Keychain.wipes(service: keychainService) == wipes else { return nil }
        if let kept = try? Keychain.read(account: keyName, service: keychainService) { return SymmetricKey(data: kept) }
        let key = SymmetricKey(size: .bits256)
        do { try Keychain.save(key.withUnsafeBytes { Data($0) }, account: keyName, service: keychainService) } catch { return nil }
        return key
    }
}
