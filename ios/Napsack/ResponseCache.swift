import Foundation

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

    /// Where every account's kept answers live.
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "napsack-cache", directoryHint: .isDirectory)
    }

    init(account: Int64, root: URL = ResponseCache.root) {
        directory = root.appending(path: String(account), directoryHint: .isDirectory)
    }

    private func file(_ key: String) -> URL {
        directory.appending(path: key.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".json")
    }

    func read(_ key: String) -> Data? {
        try? Data(contentsOf: file(key))
    }

    func write(_ data: Data, _ key: String) {
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
        try? FileManager.default.removeItem(at: root)
    }
}
