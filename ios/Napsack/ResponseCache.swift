import Foundation
import Synchronization

/// The server's answers, kept on this phone so napsack opens at once and keeps
/// working on a bad connection (the web app's cache.js): the chat list, groups,
/// and the newest page of each chat. What's kept is exactly what the server
/// sent, so messages stay end-to-end encrypted here and are decrypted only when
/// shown. Pics are never kept: they're view-once. The files are readable only
/// while the phone is unlocked (complete file protection), aren't backed up,
/// and signing out deletes all of them (Session). Everything here is optional:
/// if a file can't be read or written, napsack loads from the server as before.
struct ResponseCache: Sendable {
    let directory: URL
    private let root: String
    /// How many times the root had been wiped when this was made. Writes stop
    /// once it's wiped again: an answer that comes back as you sign out (a
    /// page fetched just before) never puts any of the account back.
    private let wipesBefore: Int

    /// Each root's wipes so far. Writes and wipes take turns on it, so no
    /// write lands between a wipe and its count.
    private static let wipes = Mutex<[String: Int]>([:])

    /// Where every account's kept answers live.
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "napsack-cache", directoryHint: .isDirectory)
    }

    init(account: Int64, root: URL = ResponseCache.root) {
        directory = root.appending(path: String(account), directoryHint: .isDirectory)
        let root = root.standardizedFileURL.path(percentEncoded: false)
        self.root = root
        wipesBefore = Self.wipes.withLock { $0[root, default: 0] }
    }

    private func file(_ key: String) -> URL {
        directory.appending(path: key.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".json")
    }

    func read(_ key: String) -> Data? {
        try? Data(contentsOf: file(key))
    }

    func write(_ data: Data, _ key: String) {
        Self.wipes.withLock { wipes in
            guard wipes[root, default: 0] == wipesBefore else { return }  // signed out since
            save(data, key)
        }
    }

    private func save(_ data: Data, _ key: String) {
        do {
            if !FileManager.default.fileExists(atPath: directory.path()) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.complete])
                var root = directory.deletingLastPathComponent()
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? root.setResourceValues(values)
            }
            try data.write(to: file(key), options: [.atomic, .completeFileProtection])
        } catch {
            // Optional: the server's still there.
        }
    }

    /// Every account's kept answers, gone (signing out).
    static func wipeAll(root: URL = ResponseCache.root) {
        wipes.withLock { wipes in
            wipes[root.standardizedFileURL.path(percentEncoded: false), default: 0] += 1
            try? FileManager.default.removeItem(at: root)
        }
    }
}
