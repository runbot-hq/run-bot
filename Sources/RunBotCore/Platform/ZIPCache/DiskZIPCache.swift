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
///
/// Each `(runID, runAttempt)` pair is stored as an independent ZIP archive.
/// StepLogView requests the attempt attached to its current `ActiveJob`, so an
/// older attempt cannot satisfy a newer attempt's cache lookup. All attempts
/// remain until the containing workflow-group directory is evicted.
///
/// ## Eviction
/// Up to `maxGroupCapacity` group directories are kept on disk. When a new group
/// directory would exceed that limit the oldest directory (by modification date) is
/// removed. Files within a group are not individually evicted; the whole group goes.
///
/// ## Thread safety
/// `DiskZIPCache` is actor-isolated. Reads, writes, group eviction, and capacity
/// enforcement are serialized through the same actor instance shared by
/// `LogFetcher` and `ZIPPrefetchQueue`.
public actor DiskZIPCache {

    // MARK: - Configuration

    /// Maximum number of group directories to keep. When exceeded, the oldest is removed.
    public static let maxGroupCapacity = 10

    // MARK: - Storage

    /// Root cache directory — all group sub-directories live here.
    let cacheDir: URL

    // MARK: - Init

    /// Creates a new cache instance.
    /// - Parameter cacheDir: Root directory for cached ZIP files. Defaults to
    ///   `ApplicationSupport/RunBot/ZIPCache` when `nil`.
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
        try? FileManager.default.createDirectory(
            at: self.cacheDir, withIntermediateDirectories: true
        )
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

    /// Returns the full file URL for a given entry key.
    private func entryURL(for key: ZIPCacheEntryKey) -> URL {
        groupDirURL(for: key.group).appendingPathComponent(key.fileName)
    }

    /// Returns the group directory URL for a given group key.
    private func groupDirURL(for group: ZIPCacheGroupKey) -> URL {
        cacheDir.appendingPathComponent(group.folderName, isDirectory: true)
    }

    /// Creates the root cache directory if it does not yet exist.
    private func prepareCacheDir() {
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true
        )
    }

    /// Sorts group directories by modification date (oldest last) and removes any
    /// beyond `maxGroupCapacity`.
    func evictGroupsIfNeeded() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }
        let dirs = contents.filter { item in
            (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let sorted = dirs.sorted { lhs, rhs in
            let d0 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 > d1  // newest first
        }
        for dir in sorted.dropFirst(Self.maxGroupCapacity) {
            try? FileManager.default.removeItem(at: dir)
            log("DiskZIPCache › evicted group dir \(dir.lastPathComponent)", category: .services)
        }
    }
}
