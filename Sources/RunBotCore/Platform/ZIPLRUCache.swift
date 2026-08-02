// ZIPLRUCache.swift
// RunBotCore

/// Thread-safe LRU cache for run-level ZIP archives, keyed by `runID`.
///
/// Values are raw ZIP `Data` bytes. Unzipping is deferred to the read path
/// (`LogFetcher.fetchStepLog`) so prefetch never pays the extraction cost for
/// runs the user never opens.
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
