// ZIPLRUCache.swift
// RunBotCore
import Foundation

/// Thread-safe LRU cache for run-level ZIP archives, keyed by `runID`.
///
/// Values are raw ZIP `Data` bytes. Unzipping is deferred to the read path
/// (`LogFetcher.fetchStepLog`) so prefetch never pays the extraction cost for
/// runs the user never opens.
///
/// ## Key format — why `startedAt` is not included
///
/// The cache key is a plain `runID` (Int) — notably **without** the `startedAt`
/// discriminator that the disk cache uses. This is safe because:
/// - GitHub `runID` values are globally unique monotonically increasing integers.
///   The same `runID` is never reused across different runs, so a stale LRU hit
///   cannot occur in production.
/// - The LRU cache is in-memory only and scoped to a single session. Even if a
///   `runID` were somehow recycled (impossible with current GitHub API semantics),
///   the eviction policy (`maxCapacity = 10`) bounds the window to the last 10
///   unique runIDs the user interacted with in this session.
/// - The disk cache (`DiskZIPCache`) does include `startedAt` in its key format,
///   providing the defence-in-depth for the persistent layer. The LRU layer
///   benefits from the simpler key without adding risk.
///
/// Capacity is bounded by `maxCapacity`. When a new entry is inserted and the cache
/// is already at capacity, the least-recently-accessed entry is evicted.
///
/// ## Access semantics
/// - `get` promotes the entry to most-recently-used.
/// - `contains` does **not** promote — it is a pure existence check.
/// - `set` promotes on update; evicts LRU on overflow.
///
/// ## Concurrency
/// `actor`-isolated. All methods are safe to call from any isolation domain.
public actor ZIPLRUCache {

    // MARK: - Capacity

    /// Maximum number of entries retained. One-line change to increase.
    public static let maxCapacity = 10

    // MARK: - Storage

    /// Ordered by recency: index 0 = least-recently-used, last index = most-recently-used.
    private var order: [Int] = []
    /// Raw ZIP byte storage keyed by runID.
    private var store: [Int: Data] = [:]

    // MARK: - Init

    /// Creates an empty LRU cache with `maxCapacity` (10) slots.
    public init() {}

    // MARK: - Public API

    /// Returns the raw ZIP `Data` for `runID` and promotes it to most-recently-used.
    /// Returns `nil` on a cache miss.
    public func get(_ runID: Int) -> Data? {
        guard let zip = store[runID] else { return nil }
        promote(runID)
        return zip
    }

    /// Inserts or updates raw ZIP `Data` for `runID`.
    /// Promotes `runID` to most-recently-used. Evicts the LRU entry if over capacity.
    public func set(_ runID: Int, zip: Data) {
        if store[runID] != nil {
            promote(runID)
        } else {
            order.append(runID)
        }
        store[runID] = zip
        evictIfNeeded()
    }

    /// Returns `true` if `runID` is currently cached.
    /// Does **not** change the recency order.
    public func contains(_ runID: Int) -> Bool {
        store[runID] != nil
    }

    /// Removes the entry for `runID` from both the store and the LRU order.
    /// No-op if `runID` is not present.
    public func evict(_ runID: Int) {
        store.removeValue(forKey: runID)
        order.removeAll { $0 == runID }
    }

    // MARK: - Private helpers

    /// Moves `runID` to the most-recently-used position in `order`.
    private func promote(_ runID: Int) {
        order.removeAll { $0 == runID }
        order.append(runID)
    }

    /// Evicts the least-recently-used entry if the cache exceeds `maxCapacity`.
    private func evictIfNeeded() {
        while order.count > Self.maxCapacity {
            let lru = order.removeFirst()
            store.removeValue(forKey: lru)
        }
    }
}
