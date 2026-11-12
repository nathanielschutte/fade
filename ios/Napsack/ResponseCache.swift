import CryptoKit
import Foundation
import Synchronization

/// The server's answers, kept on this phone so napsack opens at once and keeps
/// working on a bad connection (the web app's cache.js): the chat list, groups,
/// and the newest page of each chat. What's kept is exactly what the server
/// sent, so messages stay end-to-end encrypted here and are decrypted only when
/// shown. Friends' and groups' pictures are kept too (`pictures`, Pictures),
/// by their id, so a new picture is a new file. Pics are never kept: they're
/// view-once. The files are readable only
/// while the phone is unlocked (complete file protection), aren't backed up,
/// and signing out deletes all of them (Session). Everything here is optional:
/// if a file can't be read or written, napsack loads from the server as before.
///
/// Writing happens in the background, one file at a time, and only when the
/// bytes changed (a chat opened again usually comes back the same), so the
/// screen never waits on the disk. A write still waiting is what a read gets,
/// and one asked for before a sign-out never lands after it.
struct ResponseCache: Sendable {
    let directory: URL
    /// Where every account's files are (what signing out wipes).
    private let root: URL
    /// Which wipe of the root this was made after: writes from before a sign-out are dropped.
    private let generation: Int
    /// What its files end in: the server's answers are JSON.
    private let fileExtension: String

    /// Where every account's kept answers live.
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "napsack-cache", directoryHint: .isDirectory)
    }

    /// `after`: the root's wipes when the session began (ResponseCache.generation),
    /// so a cache made later for it still keeps nothing after a sign-out.
    init(account: Int64, root: URL = ResponseCache.root, after generation: Int? = nil) {
        self.root = root
        directory = root.appending(path: String(account), directoryHint: .isDirectory)
        self.generation = generation ?? Self.writer.generation(root)
        fileExtension = "json"
    }

    /// How many times `root` has been wiped (signing out).
    static func generation(root: URL = ResponseCache.root) -> Int {
        writer.generation(root)
    }

    private init(_ directory: URL, root: URL, generation: Int, fileExtension: String) {
        self.directory = directory
        self.root = root
        self.generation = generation
        self.fileExtension = fileExtension
    }

    /// The account's unsent texts, sealed (UnsentTexts), beside its answers.
    var unsent: ResponseCache {
        ResponseCache(directory.appending(path: "unsent", directoryHint: .isDirectory), root: root, generation: generation, fileExtension: "bin")
    }

    /// The account's kept pictures (images, as the server sent them), beside its answers.
    var pictures: ResponseCache {
        ResponseCache(directory.appending(path: "pictures", directoryHint: .isDirectory), root: root, generation: generation, fileExtension: "img")
    }

    func file(_ key: String) -> URL {
        directory.appending(path: Self.name(key) + "." + fileExtension)
    }

    private static func name(_ key: String) -> String {
        key.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// What's kept (or about to be), or nil.
    func read(_ key: String) -> Data? {
        let url = file(key)
        if let waiting = Self.writer.waiting(url) { return waiting }
        return try? Data(contentsOf: url)
    }

    /// The same, read off the caller's thread (the screens' code runs on the main thread).
    func load(_ key: String) async -> Data? {
        let cache = self
        return await Task.detached(priority: .userInitiated) { cache.read(key) }.value
    }

    /// When the kept file last changed, and its size: whether what was opened from it is still current.
    func version(_ key: String) -> Version? {
        let url = file(key)
        if let waiting = Self.writer.waiting(url) { return Version(changed: .distantFuture, bytes: waiting.count) }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let changed = values.contentModificationDate else { return nil }
        return Version(changed: changed, bytes: values.fileSize ?? 0)
    }

    struct Version: Equatable, Sendable {
        let changed: Date
        let bytes: Int
    }

    /// Keeps it, in the background; returns at once.
    func write(_ data: Data, _ key: String) {
        Self.writer.write(data, to: file(key), in: directory, root: root, generation: generation)
    }

    /// Keeps it in place of any other kept under a key starting `replacing`
    /// (an older picture of the same person), and keeps at most `limit`
    /// files here, letting the longest unchanged go. In the background.
    func write(_ data: Data, _ key: String, replacing prefix: String, limit: Int) {
        let keep = file(key).lastPathComponent, prefix = Self.name(prefix)
        Self.writer.write(data, to: file(key), in: directory, root: root, generation: generation) { directory in
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard var files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
            let older = { (url: URL) in url.lastPathComponent != keep && url.lastPathComponent.hasPrefix(prefix) }
            for old in files where older(old) { try? FileManager.default.removeItem(at: old) }
            files.removeAll(where: older)
            guard files.count > limit else { return }
            let changed = { (url: URL) in (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast }
            let others = files.filter { $0.lastPathComponent != keep }.sorted { changed($0) < changed($1) }
            for old in others.prefix(files.count - limit) { try? FileManager.default.removeItem(at: old) }
        }
    }

    /// No longer kept (in the background, after any write asked for before).
    func remove(_ key: String) {
        Self.writer.remove(file(key))
    }

    /// Every account's kept answers, gone (signing out). Writes still waiting go too.
    static func wipeAll(root: URL = ResponseCache.root) {
        writer.wipe(root)
    }

    /// Waits for the writes asked for so far (tests).
    static func settle() {
        writer.settle()
    }

    private static let writer = Writer()

    /// One queue for every write, so they land in order and a wipe waits for one under way.
    private final class Writer: Sendable {
        private struct State {
            /// How many times each root has been wiped.
            var generations: [String: Int] = [:]
            /// Writes asked for and not yet on disk, by file.
            var waiting: [URL: Data] = [:]
            /// What each file was last written with (a digest), so the same bytes aren't written again.
            var written: [URL: SHA256.Digest] = [:]
        }
        private let state = Mutex(State())
        private let queue = DispatchQueue(label: "napsack.response-cache", qos: .utility)

        /// The same whether or not the folder is there yet: a URL to one that
        /// is ends in "/" once standardized, which would make a wipe and the
        /// caches made before the folder existed disagree on whose it is.
        private static func name(_ root: URL) -> String {
            var path = root.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }

        func generation(_ root: URL) -> Int {
            state.withLock { $0.generations[Self.name(root)] ?? 0 }
        }

        func waiting(_ url: URL) -> Data? {
            state.withLock { $0.waiting[url] }
        }

        /// `tidy` runs on the queue after the write, given the directory, unless a wipe came between.
        func write(_ data: Data, to url: URL, in directory: URL, root: URL, generation: Int,
                   tidy: (@Sendable (URL) -> Void)? = nil) {
            let name = Self.name(root)
            let current = state.withLock { s -> Bool in
                guard (s.generations[name] ?? 0) == generation else { return false }
                s.waiting[url] = data
                return true
            }
            guard current else { return }  // made before a sign-out: nothing of that account is kept again
            queue.async { [self] in
                let digest = SHA256.hash(data: data)
                // Still the newest asked for, with no wipe since? And not what's there already?
                let (wanted, same) = state.withLock { s in
                    ((s.generations[name] ?? 0) == generation && s.waiting[url] == data, s.written[url] == digest)
                }
                let go = wanted && (!same || !FileManager.default.fileExists(atPath: url.path()))
                if go { Self.save(data, to: url, in: directory, root: root) }
                state.withLock { s in
                    if go { s.written[url] = digest }
                    if s.waiting[url] == data { s.waiting[url] = nil }
                }
                if go, let tidy, state.withLock({ ($0.generations[name] ?? 0) == generation }) { tidy(directory) }
            }
        }

        func remove(_ url: URL) {
            state.withLock { s in
                s.waiting[url] = nil
                s.written[url] = nil
            }
            queue.async { try? FileManager.default.removeItem(at: url) }
        }

        private static func save(_ data: Data, to url: URL, in directory: URL, root: URL) {
            do {
                if !FileManager.default.fileExists(atPath: directory.path()) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                            attributes: [.protectionKey: FileProtectionType.complete])
                    var root = root
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try? root.setResourceValues(values)
                }
                try data.write(to: url, options: [.atomic, .completeFileProtection])
            } catch {
                // Optional: the server's still there.
            }
        }

        func wipe(_ root: URL) {
            let name = Self.name(root)
            state.withLock { s in
                s.generations[name, default: 0] += 1
                s.waiting = s.waiting.filter { !Self.name($0.key).hasPrefix(name + "/") }
                s.written = s.written.filter { !Self.name($0.key).hasPrefix(name + "/") }
            }
            // After any write under way, which then finds nothing of it kept.
            queue.sync { try? FileManager.default.removeItem(at: root) }
        }

        func settle() {
            queue.sync {}
        }
    }
}
