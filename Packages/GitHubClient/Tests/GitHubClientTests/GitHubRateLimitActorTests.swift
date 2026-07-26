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
  /// Covers actor-hop overhead on loaded CI hosts; increase if tests
  /// flake on a particularly slow runner.
  private static let clampTolerance: Double = 0.5

  // MARK: - Basic set / clear

  /// Verifies that `set(resetAt:)` arms `isLimited` and populates `resetDate` within 1 second of the requested reset timestamp.
  @Test("set arms the flag and schedules a reset date")
  func setArmsFlag() async {
    let actor = RateLimitActor()
    let now = Date()
    let resetTS = now.timeIntervalSince1970 + 120

    await actor.set(resetAt: resetTS)
    let snap = await actor.snapshot()

    #expect(snap.isLimited)
    if let date = snap.resetDate {
      let diff =
        date.timeIntervalSinceReferenceDate
        - now.addingTimeInterval(120).timeIntervalSinceReferenceDate
      #expect(abs(diff) < 1)
    } else {
      Issue.record("resetDate should not be nil after set(resetAt:)")
    }
  }

  /// Verifies that `clear()` sets `isLimited` to `false` and nils out `resetDate` after a prior `set(resetAt:)` call.
  @Test("clear disarms the flag and removes the reset date")
  func clearDisarms() async {
    let actor = RateLimitActor()
    await actor.set(resetAt: Date().timeIntervalSince1970 + 120)
    await actor.clear()
    let snap = await actor.snapshot()

    #expect(!snap.isLimited)
    #expect(snap.resetDate == nil)
  }

  /// Verifies that a newly initialised `RateLimitActor` starts with `isLimited == false` and `resetDate == nil`.
  @Test("fresh actor starts with isLimited = false and nil resetDate")
  func freshActorDefaults() async {
    let actor = RateLimitActor()
    let snap = await actor.snapshot()

    #expect(!snap.isLimited)
    #expect(snap.resetDate == nil)
  }

  /// Verifies that passing `nil` to `set(resetAt:)` still arms `isLimited` and produces a non-nil `resetDate` via the default delay fallback.
  @Test("set with nil resetAt uses a default delay and still arms")
  func setWithNilResetAt() async {
    let actor = RateLimitActor()
    await actor.set(resetAt: nil)
    let snap = await actor.snapshot()

    #expect(snap.isLimited)
    #expect(snap.resetDate != nil)
  }

  // MARK: - Clamping

  /// Verifies that a `resetAt` timestamp fewer than 5 seconds in the future is clamped up to the 5 s minimum delay floor.
  @Test("set clamps delay to 5 s minimum")
  func clampMinimum() async {
    let actor = RateLimitActor()
    let now = Date()
    let tooSoon = now.timeIntervalSince1970 + 1

    await actor.set(resetAt: tooSoon)
    let snap = await actor.snapshot()

    #expect(snap.isLimited)
    if let date = snap.resetDate {
      let diff = date.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate
      #expect(diff >= 5.0 - Self.clampTolerance)
    } else {
      Issue.record("resetDate should not be nil")
    }
  }

  /// Verifies that a `resetAt` timestamp more than 7200 seconds in the future is clamped down to the 7200 s maximum delay ceiling.
  @Test("set clamps delay to 7200 s maximum")
  func clampMaximum() async {
    let actor = RateLimitActor()
    let now = Date()
    let tooFar = now.timeIntervalSince1970 + 10_000

    await actor.set(resetAt: tooFar)
    let snap = await actor.snapshot()

    #expect(snap.isLimited)
    if let date = snap.resetDate {
      let diff = date.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate
      #expect(diff <= 7201)
    } else {
      Issue.record("resetDate should not be nil")
    }
  }

  /// A `resetAt` timestamp in the past produces a negative `secondsUntilReset`,
  /// which must be clamped up to the 5 s floor rather than scheduling a
  /// zero-delay or immediate-fire reset.
  ///
  /// Real-world scenario: the GitHub API returns an `X-RateLimit-Reset` header
  /// that was already in the past by the time the response is processed (clock
  /// skew, slow response, or cached header). Without the floor clamp the actor
  /// would arm with a ≤0 delay and fire almost immediately, silently unblocking
  /// the client before the actual rate-limit window closes.
  ///
  /// `set(resetAt:)` computes `secondsUntilReset = ts - now` then applies
  /// `min(max(secondsUntilReset, 5), 7200)`. A timestamp 60 s in the past
  /// produces `secondsUntilReset ≈ -60`, which `max(..., 5)` raises to exactly 5.
  ///
  /// Three assertions:
  /// - `isLimited == true` — a past timestamp still arms the flag
  /// - `resetDate != nil` — the floor-clamped date is stored
  /// - `resetDate ≈ now + 5s` — the 5 s floor was applied (within clampTolerance)
  @Test("set with past timestamp clamps to the 5 s floor")
  func setWithPastTimestamp_clampsToFloor() async {
    let actor = RateLimitActor()
    let now = Date()
    // 60 seconds in the past — well below the 5 s floor.
    let pastTimestamp = now.timeIntervalSince1970 - 60

    await actor.set(resetAt: pastTimestamp)
    let snap = await actor.snapshot()

    // A past timestamp must still arm the flag.
    #expect(snap.isLimited)
    // A floor-clamped resetDate must be produced.
    if let date = snap.resetDate {
      let diff = date.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate
      // Must be at least the 5 s floor (minus scheduling tolerance).
      #expect(diff >= 5.0 - Self.clampTolerance)
      // Must not be unreasonably far in the future (e.g. ceiling was applied instead).
      // Uses clampTolerance on the upper bound for consistency with all other timing
      // assertions in this file and to account for CI scheduling jitter.
      #expect(diff < 10.0 + Self.clampTolerance)
    } else {
      Issue.record("resetDate must not be nil for a past timestamp")
    }
  }

  /// Calling `clear()` twice in a row must be idempotent: the second call must
  /// not crash, and the actor must remain in the cleared state.
  ///
  /// `clear()` unconditionally cancels `resetTask` and sets it to `nil`. A second
  /// call therefore calls `nil?.cancel()` (a no-op in Swift) and re-sets already-nil
  /// / already-false state. This test confirms that no force-unwrap or guard is
  /// lurking in the implementation.
  ///
  /// Regression guard: a future refactor that replaces `resetTask?.cancel()` with
  /// `resetTask!.cancel()` would crash here, making the regression immediately visible.
  ///
  /// Three assertions (after the second clear()):
  /// - `isLimited == false` — flag remains cleared
  /// - `resetDate == nil` — date remains nil
  /// - no crash (implicit: the test completes)
  @Test("clear() called twice is idempotent")
  func clearTwice_isIdempotent() async {
    let actor = RateLimitActor()
    // Arm the actor first so the first clear() has real work to do.
    await actor.set(resetAt: Date().timeIntervalSince1970 + 120)
    #expect(await actor.isLimited)

    // First clear — disarms.
    await actor.clear()
    // Second clear — must be a no-op, not a crash.
    await actor.clear()

    let snap = await actor.snapshot()
    #expect(!snap.isLimited)
    #expect(snap.resetDate == nil)
  }

  // MARK: - Generation-guard (stale-task race)

  @Test("set after set cancels prior window and preserves new window state")
  func set_after_set_cancels_prior_window() async throws {
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

  @Test("rapid successive sets keep only the latest window")
  func rapidSuccessiveSets() async {
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

  // MARK: - Snapshot atomicity

  @Test("snapshot returns consistent isLimited + resetDate pair")
  func snapshotConsistency() async {
    let actor = RateLimitActor()
    let resetAt = Date().timeIntervalSince1970 + 300

    await actor.set(resetAt: resetAt)
    let snap = await actor.snapshot()
    #expect(snap.isLimited)
    #expect(snap.resetDate != nil)

    await actor.clear()
    let afterClear = await actor.snapshot()
    #expect(!afterClear.isLimited)
    #expect(afterClear.resetDate == nil)
  }

  // MARK: - Multiple set calls without intermediate clear

  @Test("set after set without clear overwrites gracefully")
  func setAfterSetWithoutClear() async {
    let actor = RateLimitActor()
    let now = Date().timeIntervalSince1970

    await actor.set(resetAt: now + 10)
    await actor.set(resetAt: now + 20)

    let snap = await actor.snapshot()
    #expect(snap.isLimited)

    if let date = snap.resetDate {
      let referenceNow = Date(timeIntervalSince1970: now)
      let diff = date.timeIntervalSinceReferenceDate - referenceNow.timeIntervalSinceReferenceDate
      #expect(diff > 10)
      #expect(diff < 30)
    } else {
      Issue.record("resetDate should not be nil")
    }
  }
}
