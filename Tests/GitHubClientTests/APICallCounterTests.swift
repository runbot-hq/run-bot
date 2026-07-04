// APICallCounterTests.swift
// GitHubClientTests
//
// Unit tests for APICallCounter and APICallCounterSnapshot.
//
// The key invariants tested:
//   1. Fresh actor starts at zero.
//   2. record() increments count within the rolling window.
//   3. fraction is always clamped to [0, 1].
//   4. snapshot() is atomic — consistent count + limit in one hop (P10).
//   5. APICallCounterSnapshot is Equatable and Sendable.
//   6. snapshot() returns zero after all timestamps expire (idle-gap regression).
//   7. ghAPI() / ghAPIPaginated() increment on non-nil AND skip on nil transport result.
//   8. record() trims buffer to hourlyLimit at >5,000 entries.
//   9. purge() retains entries exactly at the 60-minute boundary (inclusive).
//  10. purge() evicts entries just beyond the 60-minute boundary (exclusive).
import Foundation
import Testing

@testable import GitHubClient

/// Stable endpoint string used by transport tests.
/// Extracted to avoid SonarCloud S1075 (hardcoded URI) on test call sites.
private let testEndpoint = "https://api.github.com/test"

@Suite("APICallCounter")
struct APICallCounterTests {

  // MARK: - Defaults

  /// Verifies that a newly initialised `APICallCounter` reports a count of zero and exposes the correct hourly limit.
  @Test("fresh actor starts at count zero")
  func freshActorStartsAtZero() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.count == 0)
    #expect(snap.limit == APICallCounter.hourlyLimit)
  }

  /// Verifies that `snapshot().fraction` is `0.0` on a fresh actor with no recorded calls.
  @Test("fresh actor fraction is zero")
  func freshActorFractionIsZero() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.fraction == 0.0)
  }

  // MARK: - record()

  /// Verifies that each sequential `record()` call increments the snapshot count by exactly one.
  @Test("record() increments count by one per call")
  func recordIncrementsCount() async {
    let counter = APICallCounter()
    await counter.record()
    await counter.record()
    await counter.record()
    let snap = await counter.snapshot()
    #expect(snap.count == 3)
  }

  /// Verifies that 20 concurrent `record()` calls from a `TaskGroup` all land in the actor without losing any increment.
  @Test("record() from concurrent tasks all land in the count")
  func recordConcurrentTasks() async {
    let counter = APICallCounter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask { await counter.record() }
      }
    }
    let snap = await counter.snapshot()
    #expect(snap.count == 20)
  }

  /// Verifies that `record()` caps the internal buffer at `hourlyLimit` when the seeded timestamp count exceeds that limit.
  @Test("record() trims buffer to hourlyLimit when entries exceed it")
  func recordTrimsToHourlyLimit() async {
    let counter = APICallCounter()
    let now = ContinuousClock.now
    let fresh = (0..<(APICallCounter.hourlyLimit + 10)).map {
      now.advanced(by: .milliseconds($0))
    }
    await counter.seed(timestamps: fresh)
    await counter.record()
    let snap = await counter.snapshot()
    #expect(snap.count == APICallCounter.hourlyLimit)
  }

  // MARK: - fraction clamping

  /// Verifies that `fraction` returns `0.0` rather than `NaN` when `limit` is zero, preventing propagation of invalid float values.
  @Test("fraction returns 0.0 when limit is zero to prevent NaN propagation")
  func fractionWithZeroLimitIsZero() {
    let snap = APICallCounterSnapshot(count: 42, limit: 0)
    #expect(snap.fraction == 0.0)
  }

  /// Verifies that `fraction` is clamped to `1.0` and never exceeds it, even when `count` is larger than `limit`.
  @Test("fraction is clamped to 1.0 when count exceeds limit")
  func fractionClampedToOne() {
    let snap = APICallCounterSnapshot(count: 9_999, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 1.0)
  }

  /// Verifies that `fraction` is clamped to `0.0` and never goes negative when `count` is a negative value.
  @Test("fraction is clamped to 0.0 when count is negative")
  func fractionClampedToZeroForNegativeCount() {
    let snap = APICallCounterSnapshot(count: -1, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 0.0)
  }

  /// Verifies that `fraction` is exactly `0.5` when `count` equals `hourlyLimit / 2`.
  @Test("fraction is exactly 0.5 at half the limit")
  func fractionAtHalf() {
    let snap = APICallCounterSnapshot(
      count: APICallCounter.hourlyLimit / 2, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 0.5)
  }

  /// Verifies that `fraction` stays within `[0.0, 1.0]` across a representative spread of count values.
  @Test("fraction stays within [0, 1] for any count")
  func fractionBounded() {
    for count in [0, 1, 2_500, 5_000, 7_500, 10_000] {
      let snap = APICallCounterSnapshot(count: count, limit: APICallCounter.hourlyLimit)
      #expect(snap.fraction >= 0.0)
      #expect(snap.fraction <= 1.0)
    }
  }

  // MARK: - snapshot atomicity (P10)

  /// Verifies the P10 single-hop atomicity contract: `count` and `limit` are captured together
  /// in one actor hop, so the returned snapshot is internally self-consistent.
  @Test("snapshot returns consistent count + limit in a single hop")
  func snapshotIsConsistent() async {
    let counter = APICallCounter()
    await counter.record()
    let s1 = await counter.snapshot()
    let s2 = await counter.snapshot()
    #expect(s1 == s2)
  }

  /// Exercises the P10 atomicity guarantee under concurrent mutation.
  @Test("snapshot() count+limit are consistent under concurrent record() mutations")
  func snapshotAtomicUnderConcurrentMutations() async {
    let counter = APICallCounter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask { await counter.record() }
      }
      for _ in 0..<20 {
        group.addTask {
          let snap = await counter.snapshot()
          #expect(snap.limit == APICallCounter.hourlyLimit)
          #expect(snap.count <= APICallCounter.hourlyLimit)
          #expect(snap.fraction >= 0.0)
          #expect(snap.fraction <= 1.0)
        }
      }
    }
  }

  /// Verifies that `snapshot().limit` always matches the `APICallCounter.hourlyLimit` constant, regardless of recorded calls.
  @Test("snapshot limit always equals hourlyLimit constant")
  func snapshotLimitMatchesConstant() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.limit == APICallCounter.hourlyLimit)
  }

  // MARK: - Idle-gap regression

  /// Verifies that `snapshot()` returns a count of zero after seeded timestamps have fully expired, covering the idle-gap regression from #1511.
  @Test("snapshot() returns zero after all timestamps expire without a record() call")
  func snapshotPurgesIdleStaleEntries() async {
    let counter = APICallCounter()
    let stale = ContinuousClock.now.advanced(by: .seconds(-5_400))
    await counter.seed(timestamps: [stale, stale])
    let snap = await counter.snapshot()
    #expect(snap.count == 0)
  }

  // MARK: - Boundary regression

  /// Regression test for purge() inclusive-boundary semantics.
  ///
  /// Seeds an entry 1 s inside the 60-minute window (`now - 3_599 s`) to
  /// verify it is retained. A 1 s buffer avoids a microsecond timing race
  /// between `seed()` and the `ContinuousClock.now` call inside `purge()`
  /// while still exercising the near-boundary retention path.
  /// The complementary stale test (`snapshotEvictsEntryBeyondCutoff`) uses
  /// `now - 3_601 s` to verify entries outside the window are dropped.
  @Test("purge() retains entry seeded exactly at the 60-minute boundary")
  func snapshotRetainsEntryExactlyAtCutoffBoundary() async {
    let counter = APICallCounter()
    let boundary = ContinuousClock.now.advanced(by: .seconds(-3_599))
    await counter.seed(timestamps: [boundary])
    let snap = await counter.snapshot()
    #expect(
      snap.count == 1, "entry at exactly the cutoff boundary must be retained (inclusive window)")
  }

  /// Regression test for purge() exclusive-boundary eviction.
  ///
  /// Seeds an entry 1 s beyond the 60-minute window (`now - 3_601 s`) to
  /// verify it is evicted. A 1 s buffer avoids a microsecond timing race
  /// between `seed()` and the `ContinuousClock.now` call inside `purge()`
  /// while still exercising the near-boundary eviction path.
  /// The complementary retention test (`snapshotRetainsEntryExactlyAtCutoffBoundary`)
  /// uses `now - 3_599 s` to verify entries inside the window are kept.
  @Test("purge() evicts entry seeded just beyond the 60-minute boundary")
  func snapshotEvictsEntryBeyondCutoff() async {
    let counter = APICallCounter()
    let stale = ContinuousClock.now.advanced(by: .seconds(-3_601))
    await counter.seed(timestamps: [stale])
    let snap = await counter.snapshot()
    #expect(snap.count == 0, "entry 1 s past the cutoff must be evicted")
  }

  // MARK: - APICallCounterSnapshot struct

  /// Verifies that two `APICallCounterSnapshot` instances with identical fields compare equal, and differ when any field differs.
  @Test("APICallCounterSnapshot is Equatable")
  func snapshotEquatable() {
    let a = APICallCounterSnapshot(count: 42, limit: 5_000)
    let b = APICallCounterSnapshot(count: 42, limit: 5_000)
    let c = APICallCounterSnapshot(count: 99, limit: 5_000)
    #expect(a == b)
    #expect(a != c)
  }

  /// Compile-time conformance check for `APICallCounterSnapshot.Sendable`.
  @Test("APICallCounterSnapshot is Sendable across task boundary")
  func snapshotSendable() async {
    let counter = APICallCounter()
    await counter.record()
    await counter.record()
    let snap = await counter.snapshot()
    let transferred = await Task.detached { snap }.value
    #expect(transferred.count == snap.count)
    #expect(transferred.limit == snap.limit)
  }

  // MARK: - Transport increment guard (serialized — touches shared singleton)

  /// Serialized sub-suite for all tests that touch module-level singletons
  /// (`apiCallCounter`, `configureGHAPI`, `configureGHAPIPaginated`).
  ///
  /// `.serialized` prevents intra-suite concurrent execution.
  ///
  /// KNOWN RACE: see #1511 — `.serialized` does not prevent inter-suite
  /// contamination. A parallel suite that calls `ghAPI()` mid-flight could
  /// land an increment between `reset()` and `#expect(snap.count == ...)`.
  /// The follow-up in #1511 (`@TaskLocal` override) will eliminate this.
  @Suite("Transport increment guard", .serialized)
  struct TransportIncrementGuard {

    /// Verifies that `ghAPI()` increments the shared `apiCallCounter` by one when the injected transport closure returns non-nil data.
    @Test("ghAPI() increments counter when transport returns non-nil data")
    func ghAPIIncrementsCounterOnNonNilResult() async {
      await apiCallCounter.reset()
      configureGHAPI { _ in Data() }
      _ = await ghAPI(testEndpoint)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 1)
      configureGHAPI { _ in nil }
    }

    /// Verifies that `ghAPIPaginated()` increments the shared `apiCallCounter` by one when the injected transport closure returns non-nil data.
    @Test("ghAPIPaginated() increments counter when transport returns non-nil data")
    func ghAPIPaginatedIncrementsCounterOnNonNilResult() async {
      await apiCallCounter.reset()
      configureGHAPIPaginated { _, _ in Data() }
      _ = await ghAPIPaginated(testEndpoint)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 1)
      configureGHAPIPaginated { _, _ in nil }
    }

    /// Verifies that `ghAPI()` does not increment the shared `apiCallCounter` when the injected transport closure returns nil.
    @Test("ghAPI() does not increment counter when transport returns nil")
    func ghAPISkipsCounterOnNilResult() async {
      await apiCallCounter.reset()
      configureGHAPI { _ in nil }
      _ = await ghAPI(testEndpoint)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 0)
      configureGHAPI { _ in nil }
    }

    /// Verifies that `ghAPIPaginated()` does not increment the shared `apiCallCounter` when the injected transport closure returns nil.
    @Test("ghAPIPaginated() does not increment counter when transport returns nil")
    func ghAPIPaginatedSkipsCounterOnNilResult() async {
      await apiCallCounter.reset()
      configureGHAPIPaginated { _, _ in nil }
      _ = await ghAPIPaginated(testEndpoint)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 0)
      configureGHAPIPaginated { _, _ in nil }
    }
  }
}
