// ZIPLRUCache.swift
// RunBotCore

/// Thread-safe LRU cache for run-level ZIP file maps, keyed by `runID`.
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
    /// The actual file map storage.
    private var store: [Int: [(name: String, text: String)]] = [:]

    // MARK: - Init

    /// Creates an empty LRU cache with `maxCapacity` (10) slots.
    public init() {}

    // MARK: - Public API

    /// Returns cached files for `runID` and promotes it to most-recently-used.
    /// Returns `nil` on a cache miss.
    public func get(_ runID: Int) -> [(name: String, text: String)]? {
        guard let files = store[runID] else { return nil }
        promote(runID)
        return files
    }

    /// Inserts or updates `files` for `runID`.
    /// Promotes `runID` to most-recently-used. Evicts the LRU entry if over capacity.
    public func set(_ runID: Int, files: [(name: String, text: String)]) {
        if store[runID] != nil {
            promote(runID)
        } else {
            order.append(runID)
        }
        store[runID] = files
        evictIfNeeded()
    }

    /// Returns `true` if `runID` is currently cached.
    /// Does **not** change the recency order.
    public func contains(_ runID: Int) -> Bool {
        store[runID] != nil
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
