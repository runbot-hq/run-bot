// DiskZIPCache.swift
// RunBotCore
import Foundation

/// Persistent disk cache for run-level ZIP file maps.
///
/// Stored in `cachesDirectory/RunBot/ZIPCache/` as JSON files. The OS may purge
/// entries under storage pressure; that is acceptable because a purge merely
/// causes a network re-fetch — no data loss occurs.
///
/// ## Key format
/// `runbot-zip-{runID}-{startedAtSanitised}` — the `startedAt` discriminator
/// prevents stale hits when the same `runID` is re-triggered (e.g. re-run workflow).
///
/// ## Write guard
/// Only completed runs (`isCompleted == true`) are written to disk.
/// In-progress runs stay memory-only to avoid caching a partial ZIP.
///
/// ## Capacity
/// Bounded by `maxCapacity` (10 files). On every `set`, files are sorted by
/// modification date descending and anything past index 9 is deleted.
///
/// ## Corruption
/// `get` silently deletes a file whose JSON cannot be decoded and returns `nil`.
///
/// ## Concurrency
/// `actor`-isolated. All methods are safe to call from any isolation domain.
public actor DiskZIPCache {

    // MARK: - Capacity

    /// Maximum number of JSON cache files kept on disk.
    public static let maxCapacity = 10

    // MARK: - Storage

    /// The filesystem directory where JSON cache files are stored.
    private let cacheDir: URL

    // MARK: - Init

    /// Creates the cache directory if needed and schedules eviction of excess files
    /// from any previous session. Eviction runs asynchronously on the actor after init.
    public init(cacheDir: URL? = nil) {
        if let dir = cacheDir {
            self.cacheDir = dir
        } else {
            let base = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)
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

    /// Returns cached file entries for `key`, or `nil` on miss / decode failure.
    /// Silently deletes the file if JSON decoding fails.
    public func get(key: String) -> [(name: String, text: String)]? {
        let file = cacheDir.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file) else { return nil }
        do {
            let raw = try JSONDecoder().decode([[String: String]].self, from: data)
            return raw.compactMap { dict -> (name: String, text: String)? in
                guard let name = dict["name"], let text = dict["text"] else { return nil }
                return (name: name, text: text)
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    /// Writes `value` for `key` to disk and evicts excess files.
    /// No-op (and no file written) when `isCompleted` is `false`.
    public func set(key: String, value: [(name: String, text: String)], isCompleted: Bool) {
        guard isCompleted else { return }
        let file = cacheDir.appendingPathComponent("\(key).json")
        let raw = value.map { ["name": $0.name, "text": $0.text] }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: file, options: .atomic)
        evictIfNeeded()
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
            .filter { $0.pathExtension == "json" }
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

// MARK: - Cache key helper

/// Builds a stable, filesystem-safe cache key for a run ZIP.
///
/// The `startedAt` component prevents stale hits when the same `runID` is re-triggered.
public func diskZIPCacheKey(runID: Int, startedAt: String?) -> String {
    let sanitised = (startedAt ?? "unknown")
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    return "runbot-zip-\(runID)-\(sanitised)"
}
