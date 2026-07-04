// SpyRateLimitActor.swift
// GitHubClientTests
// Shared test double — extracted from RunBotCoreTests/TestSupport/TestDoubles.swift
// alongside the GitHubClient extraction so transport tests can inject controllable
// rate-limit state without depending on RunBotCore.
import Foundation
import GitHubClient

// MARK: - SpyRateLimitActor

/// Test double conforming to `RateLimitActorProtocol`.
/// Injects controllable rate-limit state into transport functions under test.
actor SpyRateLimitActor: RateLimitActorProtocol {
    /// Seed this to simulate a pre-armed rate-limit state.
    /// Must be called via `await` from outside the actor.
    /// Read-only access from tests is through `snapshot().isLimited`.
    var isLimited = false
    /// The reset date set by the most recent `set(resetAt:)` call, or `nil` if never set.
    ///
    /// - Note: `resetDate` is not part of `RateLimitActorProtocol` by design — the
    ///   protocol exposes reset-time only through `snapshot()`. Read this via
    ///   `await spy.snapshot().resetDate` in tests that need to assert on the value.
    private(set) var resetDate: Date?
    /// Whether `set(resetAt:)` was ever called on this instance.
    ///
    /// - Note: `setCalled` is sticky — it records whether `set()` was ever called,
    ///   not whether the actor is *currently* limited. If `set()` is called and then
    ///   `clear()` is called, `setCalled == true` but `isLimited == false`. Do not
    ///   use `setCalled` as a proxy for the current rate-limit state; read `isLimited`
    ///   or `snapshot().isLimited` for that.
    private(set) var setCalled = false
    private(set) var clearCalled = false

    func setUp(isLimited: Bool) {
        self.isLimited = isLimited
    }

    func set(resetAt: TimeInterval?) {
        setCalled = true
        isLimited = true
        resetDate = resetAt.map { Date(timeIntervalSince1970: $0) }
    }

    func clear() {
        clearCalled = true
        isLimited = false
        resetDate = nil
    }

    /// Clears the rate-limit flag only when not currently limited.
    ///
    /// Mirrors `RateLimitActor.clearIfNotLimited()` semantics exactly:
    /// - When `isLimited == false`: calls `clear()`, so `clearCalled` becomes `true`.
    /// - When `isLimited == true`: no-op; `clearCalled` remains unchanged.
    ///
    /// This means tests that seed `spy.isLimited = true` before the call under test
    /// will correctly see `clearCalled == false` after a 2xx response, confirming
    /// that the pre-armed rate-limit window was not disturbed.
    func clearIfNotLimited() {
        guard !isLimited else { return }
        clear()
    }

    func snapshot() -> RateLimitSnapshot {
        RateLimitSnapshot(isLimited: isLimited, resetDate: resetDate)
    }

    /// Resets all spy observation and stub state to their default configurations.
    func reset() {
        isLimited = false
        resetDate = nil
        setCalled = false
        clearCalled = false
    }
}
