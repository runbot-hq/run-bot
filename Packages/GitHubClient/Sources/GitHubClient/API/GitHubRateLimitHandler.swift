// GitHubRateLimitHandler.swift
// GitHubClient
import Foundation

// MARK: - RateLimitSnapshot

/// An atomic snapshot of rate-limit state returned by `RateLimitActorProtocol.snapshot()`.
public struct RateLimitSnapshot: Sendable, Equatable, Hashable {
    /// Whether the GitHub API is currently rate-limiting this client.
    public let isLimited: Bool
    /// The moment at which the rate-limit window expires, or `nil` if unknown.
    public let resetDate: Date?
    /// Calls remaining in the current rate-limit window, sourced from the
    /// `X-RateLimit-Remaining` response header. `nil` when the header is absent
    /// (e.g. before the first successful response or on non-rate-limited errors).
    public let remaining: Int?
    /// Creates a new snapshot.
    public init(isLimited: Bool, resetDate: Date?, remaining: Int? = nil) {
        self.isLimited = isLimited
        self.resetDate = resetDate
        self.remaining = remaining
    }
}

// MARK: - RateLimitActorProtocol

/// Injectable abstraction over `RateLimitActor` for deterministic testing.
public protocol RateLimitActorProtocol: Actor {
    /// Whether the GitHub API is currently rate-limiting this client.
    var isLimited: Bool { get }
    /// Arms the rate-limit flag and schedules an automatic reset.
    func set(resetAt: TimeInterval?)
    /// Clears the rate-limit flag and cancels any pending reset task.
    func clear()
    /// Clears the rate-limit flag only when the actor is not currently limited.
    /// This is a deliberate TOCTOU guard: callers that want to clear a transient
    /// state (e.g. after a successful response clears a suspected rate-limit)
    /// should use this method rather than `clear()` to avoid racing with a
    /// concurrent `set(resetAt:)` call that armed the flag after the check.
    func clearIfNotLimited()
    /// Returns `isLimited`, `resetDate`, and `remaining` in a single actor hop.
    func snapshot() -> RateLimitSnapshot
    /// Records the latest `X-RateLimit-Remaining` value from a successful response.
    func updateRemaining(_ remaining: Int)
}

// MARK: - RateLimitActor

/// Actor-isolated rate-limit state for the GitHub REST API.
public actor RateLimitActor: RateLimitActorProtocol {
    /// Whether the GitHub API is currently rate-limiting this client.
    public private(set) var isLimited = false
    /// The moment at which the rate-limit window expires. `nil` when unknown.
    public private(set) var resetDate: Date?
    /// Calls remaining in the current rate-limit window. `nil` until the first
    /// successful response that carries the `X-RateLimit-Remaining` header.
    public private(set) var remaining: Int?
    /// The structured `Task` that fires when the current rate-limit window expires.
    /// Cancelled and replaced on every `set(resetAt:)` call to ensure only one reset is pending.
    private var resetTask: Task<Void, Never>?
    /// Monotonically increasing generation counter incremented on every `set(resetAt:)` call.
    /// Each reset task captures its generation at creation and ignores the callback if the
    /// counter has since advanced, preventing stale tasks from clearing a newer rate-limit window.
    private var generation = 0
    /// Optional logger for diagnostic messages.
    private let logger: (any GitHubLogger)?

    /// Creates a new `RateLimitActor`.
    public init(logger: (any GitHubLogger)? = nil) {
        self.logger = logger
    }

    /// Arms the rate-limit flag and schedules an automatic reset.
    public func set(resetAt: TimeInterval?) {
        let now = Date.now
        let delay: TimeInterval
        if let ts = resetAt {
            let secondsUntilReset = ts - now.timeIntervalSince1970
            delay = min(max(secondsUntilReset, 5), 7200)
        } else {
            delay = 3600
        }
        let date = now.addingTimeInterval(delay)
        logger?.log("RateLimitActor › arming: delay=\(Int(delay))s resetDate=\(date)", category: "transport")
        generation &+= 1
        let capturedGeneration = generation
        resetTask?.cancel()
        isLimited = true
        resetDate = date
        resetTask = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self.didFire(generation: capturedGeneration, scheduledDelay: delay)
        }
    }

    /// Clears the rate-limit flag and cancels any pending reset task.
    public func clear() {
        resetTask?.cancel()
        resetTask = nil
        isLimited = false
        resetDate = nil
    }

    /// Clears the rate-limit flag only when the actor is not currently limited.
    public func clearIfNotLimited() {
        guard !isLimited else { return }
        clear()
    }

    /// Records the latest `X-RateLimit-Remaining` value from a successful response.
    public func updateRemaining(_ newRemaining: Int) {
        remaining = newRemaining
    }

    /// Returns `isLimited`, `resetDate`, and `remaining` in a single actor hop.
    public func snapshot() -> RateLimitSnapshot {
        RateLimitSnapshot(isLimited: isLimited, resetDate: resetDate, remaining: remaining)
    }

    /// Callback invoked when the reset `Task` sleep completes.
    /// Guards against stale callbacks by comparing `generation` to the value captured at task creation.
    /// No-ops silently if a newer `set(resetAt:)` call has superseded this task.
    private func didFire(generation: Int, scheduledDelay: TimeInterval) async {
        guard generation == self.generation else {
            logger?.log("RateLimitActor › stale didFire ignored", category: "transport")
            return
        }
        isLimited = false
        resetDate = nil
        resetTask = nil
        logger?.log("RateLimitActor › auto-reset fired after \(Int(scheduledDelay))s", category: "transport")
    }
}

/// The module-wide `RateLimitActor` instance.
public let rateLimitActor = RateLimitActor()

// MARK: - Rate-limit accessors

/// Whether the GitHub API is currently rate-limiting this client.
public var ghIsRateLimited: Bool {
    get async { await rateLimitActor.isLimited }
}

/// Clears the rate-limit flag.
///
/// - Note: `@concurrent` is the canonical Swift 6.2 spelling of `nonisolated(nonsending)`
///   per SE-0431. It is intentional on a free function delegating to an actor — it means
///   the function carries no actor isolation and can be called from any context.
@concurrent
public func clearGhRateLimit() async {
    await rateLimitActor.clear()
}

/// Returns a `RateLimitSnapshot` in a single actor hop.
///
/// - Note: `@concurrent` is the canonical Swift 6.2 spelling of `nonisolated(nonsending)`
///   per SE-0431. It is intentional on a free function delegating to an actor — it means
///   the function carries no actor isolation and can be called from any context.
@concurrent
public func ghRateLimitSnapshot() async -> RateLimitSnapshot {
    await rateLimitActor.snapshot()
}
