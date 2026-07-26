// GitHubAPICallCounter.swift
// GitHubClient
//
// Tracks GitHub REST call timestamps in a rolling 60-minute window.
import Foundation

// MARK: - APICallCounterSnapshot

/// Atomic snapshot of API call-counter state returned by `APICallCounterProtocol.snapshot()`.
public struct APICallCounterSnapshot: Sendable, Equatable {
    /// Number of GitHub REST calls made in the last rolling 60-minute window.
    public let count: Int
    /// GitHub authenticated REST rate limit per rolling hour.
    public let limit: Int
    /// Fraction of the hourly limit consumed, clamped to `[0, 1]`.
    public var fraction: Double {
        guard limit > 0 else { return 0.0 }
        return max(0.0, min(Double(count) / Double(limit), 1.0))
    }
    /// Creates a new snapshot.
    public init(count: Int, limit: Int) {
        self.count = count
        self.limit = limit
    }
}

// MARK: - APICallCounterProtocol

/// Injectable abstraction over `APICallCounter` for deterministic testing.
public protocol APICallCounterProtocol: Actor {
    /// Record one GitHub REST API call.
    func record()
    /// Returns `count` and `limit` in a single actor hop.
    func snapshot() -> APICallCounterSnapshot
}

// MARK: - APICallCounter

/// Actor-isolated rolling buffer of GitHub REST call timestamps.
public actor APICallCounter: APICallCounterProtocol {
    /// Shared instance wired at module level.
    public static let shared = APICallCounter()
    /// GitHub authenticated REST rate limit per rolling hour.
    public static let hourlyLimit = 5_000
    /// Rolling buffer of call instants in ascending order.
    ///
    /// - Invariant: Elements are always sorted ascending. `record()` only ever
    ///   appends `.now` to the tail, preserving this order. `purge()` relies on
    ///   this invariant — it uses `drop(while:)` which is a prefix-drop, not a
    ///   filter, and produces incorrect results if the buffer is unsorted.
    var timestamps: [ContinuousClock.Instant] = []
    /// Creates a new `APICallCounter` instance.
    public init() {}

    // MARK: - Protocol

    /// Records one GitHub REST API call at the current `ContinuousClock` instant.
    public func record() {
        purge()
        timestamps.append(.now)
        // Defence-in-depth safety ceiling — not the primary eviction mechanism.
        // purge() (called above) handles time-based eviction and should keep the
        // buffer well below hourlyLimit under normal operation. This cap exists
        // solely to bound memory in the degenerate case where purge() is somehow
        // bypassed or the clock stalls. It is count-based by design: a time-based
        // check here would duplicate purge() logic for no benefit.
        if timestamps.count > Self.hourlyLimit {
            timestamps = Array(timestamps.suffix(Self.hourlyLimit))
        }
    }

    /// Returns `count` and `limit` in a single actor hop.
    public func snapshot() -> APICallCounterSnapshot {
        purge()
        return APICallCounterSnapshot(count: timestamps.count, limit: Self.hourlyLimit)
    }

    // MARK: - Private

    /// Evicts timestamps outside the rolling 60-minute window.
    ///
    /// Relies on the ascending-order invariant of `timestamps` — see its declaration.
    ///
    /// Boundary: elements at exactly `cutoff` are retained. `drop(while: { $0 < cutoff })`
    /// stops at the first element where `$0 >= cutoff`, which is identical to the
    /// previous `firstIndex(where: { $0 >= cutoff })` inclusive boundary.
    private func purge() {
        let cutoff = ContinuousClock.now - .seconds(3_600)
        timestamps = Array(timestamps.drop(while: { $0 < cutoff }))
    }
}

// MARK: - Module-level accessor

/// The module-wide `APICallCounter` instance shared by `GitHubTransportShim`.
public let apiCallCounter = APICallCounter.shared
