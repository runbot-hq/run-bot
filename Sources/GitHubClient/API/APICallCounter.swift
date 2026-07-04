// APICallCounter.swift
// GitHubClient
//
// Tracks GitHub REST call timestamps in a rolling 60-minute window.
// Mirrors the RateLimitActor pattern (P16 — Actor-Per-Concern Isolation).
//
// Actor chosen over Mutex: record() performs an append + slice on an array
// that can reach 5,000 entries under load — non-trivial work that must not
// block a cooperative thread pool worker under a lock.
//
// ContinuousClock is used instead of Date() for timestamps so that purge()
// is unaffected by macOS sleep/wake NTP corrections or user time-zone
// changes. ContinuousClock advances monotonically from system boot.
import Foundation

// MARK: - APICallCounterSnapshot

/// Atomic snapshot of API call-counter state returned by `APICallCounterProtocol.snapshot()`.
public struct APICallCounterSnapshot: Sendable, Equatable {
    /// Number of GitHub REST calls made in the last rolling 60-minute window.
    public let count: Int
    /// GitHub authenticated REST rate limit per rolling hour.
    public let limit: Int
    /// Fraction of the hourly limit consumed, clamped to `[0, 1]`.
    ///
    /// - Returns `0.0` when `limit == 0` to avoid `NaN` propagation.
    /// - Lower-bounded at `0.0` so a negative `count` cannot produce a
    ///   negative fraction.
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

/// Injectable abstraction over `APICallCounter` for deterministic testing (P7).
public protocol APICallCounterProtocol: Actor {
    /// Record one GitHub REST API call.
    func record()
    /// Returns `count` and `limit` in a single actor hop (P10).
    func snapshot() -> APICallCounterSnapshot
}

// MARK: - APICallCounter

/// Actor-isolated rolling buffer of GitHub REST call timestamps.
///
/// Timestamps are stored as `ContinuousClock.Instant` rather than `Date` so
/// that `purge()` is unaffected by macOS sleep/wake NTP corrections or user
/// clock adjustments. `ContinuousClock` advances monotonically from system
/// boot — a wake-from-sleep event does not cause the clock to jump backward.
///
/// `record()` is called via a direct `await` in `GitHubTransportShim` (not
/// fire-and-forget) so that task cancellation propagates correctly and
/// cancelled/timed-out fetches do not increment the counter.
///
/// No persistence — the counter resets on app launch by design.
/// Memory is bounded: `purge()` evicts entries older than 3,600 s, and
/// `record()` trims to `hourlyLimit` via a suffix slice.
public actor APICallCounter: APICallCounterProtocol {
    /// Shared instance wired at module level.
    public static let shared = APICallCounter()

    /// GitHub authenticated REST rate limit per rolling hour.
    public static let hourlyLimit = 5_000

    /// Rolling buffer of call instants, always in ascending order.
    ///
    /// Stored as `ContinuousClock.Instant` to avoid wall-clock skew.
    /// Entries are appended in call order; `purge()` drops the front.
    ///
    /// Declared `internal` (not `private`) so that the test-target seam
    /// `APICallCounter+TestSeam.swift` can inject pre-built timestamps
    /// via `@testable import GitHubClient` without needing a public API.
    var timestamps: [ContinuousClock.Instant] = []

    /// Creates a new `APICallCounter` instance.
    public init() {
        // Default property initializers fully define state.
    }

    // MARK: - Protocol

    /// Records one GitHub REST API call at the current `ContinuousClock` instant.
    ///
    /// Purges stale entries first, appends the current instant, then caps
    /// the buffer at `hourlyLimit` via a suffix slice (avoids the O(n)
    /// element-shift cost of `removeFirst(n)`).
    public func record() {
        purge()
        timestamps.append(.now)
        if timestamps.count > Self.hourlyLimit {
            timestamps = Array(timestamps.suffix(Self.hourlyLimit))
        }
    }

    /// Returns `count` and `limit` in a single actor hop (P10).
    public func snapshot() -> APICallCounterSnapshot {
        purge()
        return APICallCounterSnapshot(count: timestamps.count, limit: Self.hourlyLimit)
    }

    // MARK: - Private

    /// Evicts timestamps older than the rolling 60-minute window.
    ///
    /// Because timestamps are always appended in ascending order, stale
    /// entries are always at the front. Uses `firstIndex(where:)` (O(k)
    /// scan — stops at the first fresh entry) + `removeFirst(_:)` (O(n−k)
    /// shift) — total O(n), but avoids the full-array predicate evaluation
    /// of `removeAll(where:)` when most entries are fresh.
    ///
    /// **Boundary semantics:** the cutoff predicate is `>= cutoff`, so an
    /// instant exactly 3,600 s old (idx == 0) is treated as *within* the
    /// rolling window and retained. The `if idx > 0` guard is correct and
    /// intentional — do not change `>=` to `>` without updating this comment
    /// and the boundary regression test.
    ///
    /// `ContinuousClock` is monotonic, so the cutoff calculation is not
    /// susceptible to sleep/wake NTP corrections or user clock changes.
    private func purge() {
        let cutoff = ContinuousClock.now - .seconds(3_600)
        if let idx = timestamps.firstIndex(where: { $0 >= cutoff }) {
            if idx > 0 { timestamps.removeFirst(idx) }
        } else {
            timestamps.removeAll()
        }
    }
}

// MARK: - Module-level accessor

/// The module-wide `APICallCounter` instance shared by `GitHubTransportShim`.
/// See issue #1511 for the follow-up to make this overridable via `@TaskLocal`.
public let apiCallCounter = APICallCounter.shared
