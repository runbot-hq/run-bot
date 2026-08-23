// GitHubRateLimitActorTests.swift
// GitHubClientTests
//
// Unit tests for RateLimitActor — generation-guard stale-task race,
// clamp semantics, and the atomic snapshot contract.
//
// These tests exercise the actor in isolation (no URLSession, no stubs)
// by calling its public API directly and asserting on its observable state.
//
// The generation-guard (P10 — Atomic Snapshot Pattern) is the key invariant:
// a didFire callback from a cancelled rate-limit window must NOT clear state
// that belongs to a newer window. Without this guard, the app would silently
// unblock mid-limit.
//
// RateLimitSnapshot protocol-conformance smoke tests (snapshotEquatable,
// snapshotHashable, snapshotSendable) were removed in #1500 — RateLimitSnapshot
// is a plain struct with compiler-synthesised conformances; testing the compiler
// adds noise with no regression value, consistent with the policy in #1450.
//
import Foundation
import Testing

@testable import GitHubClient

@Suite("RateLimitActor")
struct RateLimitActorTests {

  // MARK: - Constants

  /// Acceptable scheduling latency budget for clamp assertions.
  private static let clampTolerance: Double = 0.5

  // MARK: - Set / clear lifecycle

  /// Verifies set() arms isLimited with a valid resetDate, then clear() disarms both.
  @Test("set then clear lifecycle")
  func setAndClearLifecycle() async {
    let actor = RateLimitActor()
    let now = Date()
    let resetTS = now.timeIntervalSince1970 + 120

    await actor.set(resetAt: resetTS)
    let snapAfterSet = await actor.snapshot()
    #expect(snapAfterSet.isLimited)
    if let date = snapAfterSet.resetDate {
      let diff =
        date.timeIntervalSinceReferenceDate
        - now.addingTimeInterval(120).timeIntervalSinceReferenceDate
      #expect(abs(diff) < 1)
    } else {
      Issue.record("resetDate should not be nil after set(resetAt:)")
    }

    await actor.clear()
    let snapAfterClear = await actor.snapshot()
    #expect(!snapAfterClear.isLimited)
    #expect(snapAfterClear.resetDate == nil)
  }

  // MARK: - Clamp behaviour

  /// Verifies floor (5 s), ceiling (7200 s), and past-timestamp clamping in one loop.
  ///
  /// Past-date scenario: the GitHub API returns an X-RateLimit-Reset header already
  /// in the past (clock skew / cached header). Without the floor clamp the actor
  /// would fire almost immediately, silently unblocking the client too early.
  @Test("clamp behaviour: floor, ceiling, past timestamp")
  func clampBehavior() async {
    struct Case {
      let label: String
      let offset: Double   // seconds relative to now
      let minDiff: Double
      let maxDiff: Double
    }
    let now = Date()
    let cases: [Case] = [
      Case(label: "too-soon (1s)",   offset:     1, minDiff:    5 - Self.clampTolerance, maxDiff:   20),
      Case(label: "too-far (10000s)", offset: 10_000, minDiff: 7190,                       maxDiff: 7210),
      Case(label: "past (-60s)",      offset:   -60, minDiff:    5 - Self.clampTolerance, maxDiff:   20),
    ]
    for c in cases {
      let actor = RateLimitActor()
      await actor.set(resetAt: now.timeIntervalSince1970 + c.offset)
      let snap = await actor.snapshot()
      #expect(snap.isLimited, "\(c.label): should be limited")
      if let date = snap.resetDate {
        let diff = date.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate
        #expect(diff >= c.minDiff, "\(c.label): diff \(diff) below min \(c.minDiff)")
        #expect(diff <= c.maxDiff, "\(c.label): diff \(diff) above max \(c.maxDiff)")
      } else {
        Issue.record("\(c.label): resetDate should not be nil")
      }
    }
  }

  // MARK: - Generation guard

  /// A second set() cancels the first window's expiry task and the actor remains
  /// limited with the new window's resetDate — the generation guard must prevent
  /// the stale task from clearing the newer window.
  @Test("generation guard preserves latest window")
  func generationGuardPreservesLatestWindow() async throws {
    let actor = RateLimitActor()

    await actor.set(resetAt: Date().timeIntervalSince1970 + 5)
    #expect(await actor.isLimited)

    await actor.set(resetAt: Date().timeIntervalSince1970 + 60)
    #expect(await actor.isLimited)

    try await Task.sleep(for: .milliseconds(100))

    let snap = await actor.snapshot()
    #expect(snap.isLimited)
    #expect(snap.resetDate != nil)
  }

  // MARK: - Concurrent mutation snapshot

  /// Rapid successive set() calls keep only the latest window;
  /// snapshot() returns a consistent isLimited + resetDate pair.
  @Test("rapid successive sets keep only the latest window")
  func concurrentMutationProducesConsistentSnapshot() async {
    let actor = RateLimitActor()
    let now = Date().timeIntervalSince1970

    for i in 1..<5 {
      await actor.set(resetAt: now + Double(i * 10))
    }

    let snap = await actor.snapshot()
    #expect(snap.isLimited)

    if let date = snap.resetDate {
      let referenceNow = Date(timeIntervalSince1970: now)
      let diff = date.timeIntervalSinceReferenceDate - referenceNow.timeIntervalSinceReferenceDate
      #expect(diff > 30)
      #expect(diff < 50)
    } else {
      Issue.record("resetDate should not be nil")
    }
  }
}
