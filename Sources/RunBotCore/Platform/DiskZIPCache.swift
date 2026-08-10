// DiskZIPCache.swift
// RunBotCore
import Foundation

/// Persistent disk cache for run-level ZIP archives.
///
/// ## Layout on disk
/// ```
/// applicationSupportDirectory/RunBot/ZIPCache/
///   <ZIPCacheGroupKey.folderName>/
///     <runID>-<runAttempt>.zip   (e.g. "123456789-2.zip")
///   …
/// ```
/// One sub-directory per `ZIPCacheGroupKey`, one file per `(runID, runAttempt)` pair.
/// Using a group-scoped directory means a rerun (new `runAttempt`) naturally
/// replaces the previous attempt's file *within the same group folder* — the group
/// folder remains the LRU eviction unit.
///
/// ## Eviction
/// Up to `maxGroupCapacity` group directories are kept on disk. When a new group
/// directory would exceed that limit the oldest directory (by modification date) is
/// removed. Files within a group are not individually evicted; the whole group goes.
///
/// ## Thread safety
/// All public entry points are `async` and marked `nonisolated` so callers on any
/// actor may `await` them without a hop. Filesystem I/O is synchronous but cheap
/// enough that no extra threading is needed at this cache size.
///
/// ## Legacy migration
/// On first access this type removes any flat `*.zip` files that may exist at the
/// *root* of the cache directory — they were written by the old single-level scheme.
/// This is a one-time silent migration; no data is lost because the prefetch queue
/// will re-download them on the next completed-run transition.
public final class DiskZIPCache: Sendable {

    // MARK: - Configuration

    /// Maximum number of group directories to keep. When exceeded, the oldest is removed.
    static let maxGroupCapacity = 10

    // MARK: - Storage

    /// Root cache directory — all group sub-directories live here.
    let cacheDir: URL

    // MARK: - Init

    public init(cacheDir: URL? = nil) {
        if let dir = cacheDir {
            self.cacheDir = dir
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.cacheDir = support
                .appendingPathComponent("RunBot", isDirectory: true)
                .appendingPathComponent("ZIPCache", isDirectory: true)
        }
        prepareCacheDir()
        purgeLegacyFlatFiles()
    }

    // MARK: - Public API

    /// Returns cached ZIP data for the given entry, or `nil` on a cache miss.
    public func get(key: ZIPCacheEntryKey) -> Data? {
        let file = entryURL(for: key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        log(
            "DiskZIPCache › HIT key=\(key.group.folderName)/\(key.fileName) bytes=\(data.count)",
            category: .services
        )
        return data
    }

    /// Writes `zip` to disk under the group sub-directory.
    ///
    /// - No-op when `isCompleted` is `false` (partial ZIPs must not be cached).
    /// - On success, evicts the oldest group directories beyond `maxGroupCapacity`.
    /// - On write failure, skips eviction so no valid entry is removed for a file
    ///   that was never successfully stored.
    public func set(key: ZIPCacheEntryKey, zip: Data, isCompleted: Bool) {
        guard isCompleted else {
            log(
                "DiskZIPCache › write skipped — key=\(key.group.folderName)/\(key.fileName) reason=run-not-completed",
                category: .services
            )
            return
        }
        let groupDir = groupDirURL(for: key.group)
        do {
            try FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
        } catch {
            log(
                "DiskZIPCache › group dir creation failed — key=\(key.group.folderName) error=\(error)",
                category: .services
            )
            return
        }
        let file = groupDir.appendingPathComponent(key.fileName)
        do {
            try zip.write(to: file, options: .atomic)
            log(
                "DiskZIPCache › write succeeded — key=\(key.group.folderName)/\(key.fileName) bytes=\(zip.count)",
                category: .services
            )
        } catch {
            log(
                "DiskZIPCache › write failed — key=\(key.group.folderName)/\(key.fileName) error=\(error)",
                category: .services
            )
            return
        }
        evictGroupsIfNeeded()
    }

    /// Removes the group directory for `group` (and all ZIP files inside it).
    /// No-op if the directory does not exist.
    public func evictGroup(key: ZIPCacheGroupKey) {
        let dir = groupDirURL(for: key)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Private helpers

    private func entryURL(for key: ZIPCacheEntryKey) -> URL {
        groupDirURL(for: key.group).appendingPathComponent(key.fileName)
    }

    private func groupDirURL(for group: ZIPCacheGroupKey) -> URL {
        cacheDir.appendingPathComponent(group.folderName, isDirectory: true)
    }

    private func prepareCacheDir() {
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true
        )
    }

    /// Removes flat `*.zip` files at the cache root that were written by the old
    /// single-level scheme (runID.zip). Group sub-directories are left untouched.
    private func purgeLegacyFlatFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }
        for url in contents where url.pathExtension == "zip" {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                try? FileManager.default.removeItem(at: url)
                log("DiskZIPCache › purged legacy flat file \(url.lastPathComponent)", category: .services)
            }
        }
    }

    /// Sorts group directories by modification date (oldest last) and removes any
    /// beyond `maxGroupCapacity`.
    func evictGroupsIfNeeded() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }
        let dirs = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let sorted = dirs.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 > d1  // newest first
        }
        for dir in sorted.dropFirst(Self.maxGroupCapacity) {
            try? FileManager.default.removeItem(at: dir)
            log("DiskZIPCache › evicted group dir \(dir.lastPathComponent)", category: .services)
        }
    }
}
