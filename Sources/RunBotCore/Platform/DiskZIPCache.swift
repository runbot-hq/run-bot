// DiskZIPCache.swift
// RunBotCore
import Foundation

/// Persistent disk cache for run-level ZIP archives.
///
/// Stored in `applicationSupportDirectory/RunBot/ZIPCache/` as raw `.zip` files
/// named `{runID}.zip`. The OS may purge entries under storage pressure; that is
/// acceptable because a purge merely causes a network re-fetch — no data loss occurs.
///
/// Unzipping is **not** performed here. The raw bytes are stored and returned as-is;
/// callers (e.g. `LogFetcher.fetchStepLog`) unzip lazily on the read path.
///
/// ## Key format
/// Plain `runID` integer — filename is `{runID}.zip`. No `startedAt` discriminator
/// is needed because `RunnerPoller.prefetchedRunIDs` ensures each runID is only
/// ever written once per session.
///
/// ## Write guard
/// Only completed runs (`isCompleted == true`) are written to disk.
/// In-progress runs stay memory-only to avoid persisting a partial ZIP.
///
/// ## Capacity
/// Bounded by `maxCapacity` (10 files). On every `set`, files are sorted by
/// modification date descending and anything past index 9 is deleted.
///
/// ## Concurrency
/// `actor`-isolated. All methods are safe to call from any isolation domain.
public actor DiskZIPCache {

    // MARK: - Capacity

    /// Maximum number of `.zip` cache files kept on disk.
    public static let maxCapacity = 10

    // MARK: - Storage

    /// The filesystem directory where `.zip` cache files are stored.
    private let cacheDir: URL

    // MARK: - Init

    /// Creates the cache directory if needed and schedules eviction of excess files
    /// from any previous session. Eviction runs asynchronously on the actor after init.
    public init(cacheDir: URL? = nil) {
        if let dir = cacheDir {
            self.cacheDir = dir
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.cacheDir = base
                .appendingPathComponent("RunBot", isDirectory: true)
                .appendingPathComponent("ZIPCache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.cacheDir,
            withIntermediateDirectories: true
        )
        // Cannot call actor-isolated evictIfNeeded() synchronously during init.
        // Schedule it on the actor executor immediately after init returns.
        Task { await self.evictIfNeeded() }
    }

    // MARK: - Public API

    /// Returns the raw ZIP `Data` for `runID`, or `nil` on miss.
    /// Silently deletes the file if it exists but cannot be read.
    public func get(runID: Int) -> Data? {
        let file = cacheDir.appendingPathComponent("\(runID).zip")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        if let data = try? Data(contentsOf: file) {
            return data
        } else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    /// Writes raw ZIP `Data` for `runID` to disk and evicts excess files.
    /// No-op (and no file written) when `isCompleted` is `false`.
    public func set(runID: Int, zip: Data, isCompleted: Bool) {
        guard isCompleted else { return }
        let file = cacheDir.appendingPathComponent("\(runID).zip")
        try? zip.write(to: file, options: .atomic)
        evictIfNeeded()
    }

    /// Removes the `.zip` file for `runID` from disk if it exists.
    /// No-op if the file is not present.
    public func evict(runID: Int) {
        let file = cacheDir.appendingPathComponent("\(runID).zip")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Private helpers

    /// Sorts cache files by modification date (newest first) and removes anything past `maxCapacity`.
    func evictIfNeeded() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let sorted = contents
            .filter { $0.pathExtension == "zip" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return d0 > d1
            }
        for file in sorted.dropFirst(Self.maxCapacity) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
