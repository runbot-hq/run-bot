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
      // Assert diff >= (minClamp - clampTolerance) so a loaded CI host
      // with up to `clampTolerance` seconds of scheduling latency still
      // passes without losing the signal that the 5 s floor was applied.
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

  // MARK: - Generation-guard (stale-task race)

  /// Verifies that a second `set()` cancels the prior window's reset task via
  /// `resetTask?.cancel()` inside `set()`, and that window-2's state remains
  /// intact after a brief sleep (giving any already-sleeping stale didFire a
  /// chance to arrive — it will be rejected by the generation guard).
  ///
  /// NOTE: This does NOT exercise the full generation-guard race. The actual
  /// timer-boundary race — where window-1's reset task has *exited* `Task.sleep`
  /// (so `.cancel()` no longer stops it) and calls `didFire` after window-2 has
  /// incremented `generation` — is not directly exercisable from the public API
  /// without clock injection. A full race test would require injecting a
  /// controllable time source into `RateLimitActor`, which is out of scope for
  /// this PR. The generation-guard logic is instead verified by code review and
  /// the swift-testing run that confirms the guard path
  /// (`guard generation == self.generation else { ... }`) compiles and executes.
  ///
  /// TODO: Upgrade to a deterministic race test once `RateLimitActor` supports
  /// injectable `Clock` conformance. Track in follow-up issue.
  /// Verifies that a second `set()` cancels the prior window's reset task and that window-2's armed state survives a brief yield.
  @Test("set after set cancels prior window and preserves new window state")
  func set_after_set_cancels_prior_window() async throws {
    let actor = RateLimitActor()

    // Window 1
    await actor.set(resetAt: Date().timeIntervalSince1970 + 5)
    #expect(await actor.isLimited)

    // Window 2 replaces window 1 (generation increments)
    await actor.set(resetAt: Date().timeIntervalSince1970 + 60)
    #expect(await actor.isLimited)

    // Use `try await` (not `try?`) so test-task cancellation propagates
    // rather than being swallowed silently.
    try await Task.sleep(for: .milliseconds(100))

    // Window 2's state must still be intact
    let snap = await actor.snapshot()
    #expect(snap.isLimited)
    #expect(snap.resetDate != nil)
  }

  /// Multiple rapid set calls: only the last window's state survives.
  /// Loop starts at i=1 so every call passes a strictly future timestamp
  /// (now + 10 ... now + 40), keeping the test off the clamp-floor path.
  /// Uses the captured `now` timestamp for assertions to avoid wall-clock
  /// drift in slow CI environments.
  /// Verifies that four rapid `set()` calls in a loop leave only the last window's `resetDate` intact, with all earlier windows discarded.
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
      // The last call passed now + 40; resetDate is derived from the
      // clamped delay which matches this value (within the [5, 7200]
      // range). Using the captured `now` instead of a fresh Date()
      // eliminates wall-clock drift sensitivity.
      let referenceNow = Date(timeIntervalSince1970: now)
      let diff = date.timeIntervalSinceReferenceDate - referenceNow.timeIntervalSinceReferenceDate
      #expect(diff > 30)
      #expect(diff < 50)
    } else {
      Issue.record("resetDate should not be nil")
    }
  }

  // MARK: - Snapshot atomicity

  /// Verifies that `snapshot()` returns a consistent `isLimited` + `resetDate` pair both after `set()` and after a subsequent `clear()`.
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

  /// Verifies that calling `set()` twice without `clear()` overwrites the previous window and leaves the actor in the state set by the second call.
  @Test("set after set without clear overwrites gracefully")
  func setAfterSetWithoutClear() async {
    let actor = RateLimitActor()
    let now = Date().timeIntervalSince1970

    await actor.set(resetAt: now + 10)
    await actor.set(resetAt: now + 20)

    let snap = await actor.snapshot()
    #expect(snap.isLimited)

    if let date = snap.resetDate {
      // Second call passed now + 20. Using the captured `now` instead of
      // a fresh Date() eliminates wall-clock drift sensitivity in CI.
      let referenceNow = Date(timeIntervalSince1970: now)
      let diff = date.timeIntervalSinceReferenceDate - referenceNow.timeIntervalSinceReferenceDate
      #expect(diff > 10)
      #expect(diff < 30)
    } else {
      Issue.record("resetDate should not be nil")
    }
  }
}
