// PollIntervalStrategy.swift
// RunBotCore
import Foundation

/// Pure, actor-free strategy for computing the next poll interval.
/// All inputs are value types — fully testable with `swift test` without any actor.
public struct PollIntervalStrategy: Sendable {

    // MARK: — Active ladder (live-data, aggressive)

    /// ≤ 5 busy runners → 1 s poll cadence.
    public static let activeIntervalFast: TimeInterval = 1
    /// 6–9 busy runners → 3 s poll cadence.
    public static let activeIntervalMid: TimeInterval = 3
    /// ≥ 10 busy runners → 5 s poll cadence.
    public static let activeIntervalSlow: TimeInterval = 5

    // MARK: — Idle backoff

    /// Formula seed for idle backoff: `idleBase * 2^(consecutiveIdleTicks - 1)`, capped at `idleMax`.
    /// Tick 1 (the first idle interval in normal operation) equals `idleBase` exactly:
    ///   tick 1 →  15 s
    ///   tick 2 →  30 s
    ///   tick 3 →  60 s
    ///   tick 4 → 120 s
    ///   tick 5 → 240 s
    ///   tick 6+ → 300 s (capped)
    /// Tick 0 (pre-subtraction underflow → 2^-1 = 0.5 → 7.5 s) is only reachable on a
    /// first-fetch error; `applyError` keeps counters at 0. In normal operation the first
    /// idle fetch increments `consecutiveIdleTicks` to 1 via `updateAdaptiveCounters`
    /// before `nextPollInterval()` is called, so the minimum observable production idle
    /// sleep is 15 s (tick 1).
    public static let idleBase: TimeInterval = 15
    /// Maximum idle poll interval cap (5 minutes).
    public static let idleMax: TimeInterval = 300

    // MARK: — Rate-limit headroom

    /// Sentinel value for `rateLimitRemaining` when `X-RateLimit-Remaining` has not
    /// yet been wired (Step 9 of #2069). Using a named constant makes every call site
    /// grep-able and lets Step 9 replace them all from a single definition.
    public static let rateLimitUnavailable: Int = Int.max

    /// Proactive cooldown threshold. Pass `rateLimitUnavailable` when
    /// `X-RateLimit-Remaining` is unavailable — the headroom branch becomes a no-op.
    public static let rateLimitHeadroomThreshold: Int = 50

    // MARK: — Entry point

    /// Returns the interval (in seconds) to wait before the next poll.
    ///
    /// - Parameters:
    ///   - hasActiveWork: `true` when jobs or actions are in-progress / queued.
    ///   - consecutiveIdleTicks: number of consecutive successful idle cycles.
    ///   - busyRunnerCount: number of runners currently marked busy.
    ///   - isRateLimited: hard rate-limit flag (actor-local on `RunnerPoller`).
    ///   - rateLimitResetDate: when the rate-limit window resets (actor-local).
    ///   - rateLimitRemaining: remaining API calls in the current window.
    ///     Pass `Int.max` until `X-RateLimit-Remaining` is wired (Step 9 of #2069).
    public static func next(
        hasActiveWork: Bool,
        consecutiveIdleTicks: Int,
        busyRunnerCount: Int,
        isRateLimited: Bool,
        rateLimitResetDate: Date?,
        rateLimitRemaining: Int
    ) -> TimeInterval {

        // --- Cooldown: hard rate-limit hit ---
        if isRateLimited {
            if let reset = rateLimitResetDate {
                return max(30, reset.timeIntervalSinceNow + 5)
            }
            return 60
        }

        // --- Headroom cooldown: approaching the rate-limit wall proactively ---
        // No-op while rateLimitRemaining == rateLimitUnavailable (sentinel for "unavailable").
        if rateLimitRemaining < rateLimitHeadroomThreshold {
            if let reset = rateLimitResetDate {
                return max(60, reset.timeIntervalSinceNow)
            }
            return 300
        }

        // --- Active: live data, aggressive ---
        // Branch order matters — > 9 must be checked before > 5.
        if hasActiveWork {
            if busyRunnerCount > 9 { return activeIntervalSlow }  // ≥ 10
            if busyRunnerCount > 5 { return activeIntervalMid }   // 6–9
            return activeIntervalFast                              // ≤ 5
        }

        // --- Idle: exponential backoff ---
        // tick 1 → 15 s, 2 → 30 s, 3 → 60 s, 4 → 120 s, 5 → 240 s, 6+ → 300 s
        // The exponent is (consecutiveIdleTicks - 1) so tick 1 yields idleBase exactly.
        // Overflow safety: pow(2, n) → Double.infinity for large n;
        // min(infinity, idleMax) → idleMax (300). No trap, no incorrect result.
        let backed = idleBase * pow(2.0, Double(consecutiveIdleTicks - 1))
        return min(backed, idleMax)
    }
}
