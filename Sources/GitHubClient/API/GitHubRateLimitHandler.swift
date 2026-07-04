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

    /// Creates a new snapshot with the given rate-limit state.
    public init(isLimited: Bool, resetDate: Date?) {
        self.isLimited = isLimited
        self.resetDate = resetDate
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
    func clearIfNotLimited()
    /// Returns `isLimited` and `resetDate` in a single actor hop.
    func snapshot() -> RateLimitSnapshot
}

// MARK: - RateLimitActor

/// Actor-isolated rate-limit state.
public actor RateLimitActor: RateLimitActorProtocol {
    /// Whether the GitHub API is currently rate-limiting this client.
    public private(set) var isLimited = false
    /// The moment at which the rate-limit window expires.
    public private(set) var resetDate: Date?
    /// Structured task that clears `isLimited` when it fires.
    private var resetTask: Task<Void, Never>?
    /// Incremented on every `set(resetAt:)` call.
    private var generation = 0

    /// Creates a new `RateLimitActor` instance.
    public init() {}

    /// Arms the rate-limit flag and schedules an automatic reset.
    public func set(resetAt: TimeInterval?) {
        let delay: TimeInterval
        if let ts = resetAt {
            let secondsUntilReset = ts - Date().timeIntervalSince1970
            delay = min(max(secondsUntilReset, 5), 7200)
        } else {
            delay = 3600
        }
        let date = Date().addingTimeInterval(delay)
        generation &+= 1
        let capturedGeneration = generation
        resetTask?.cancel()
        isLimited = true
        resetDate = date
        resetTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
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

    /// Returns both `isLimited` and `resetDate` in a single actor hop.
    public func snapshot() -> RateLimitSnapshot {
        RateLimitSnapshot(isLimited: isLimited, resetDate: resetDate)
    }

    // MARK: Private

    private func didFire(generation: Int, scheduledDelay: TimeInterval) async {
        guard generation == self.generation else { return }
        isLimited = false
        resetDate = nil
        resetTask = nil
    }
}

/// The module-wide `RateLimitActor` instance shared by `GitHubResponseDecoder`
/// and `GitHubURLSessionTransport`.
public let rateLimitActor = RateLimitActor()

// MARK: - Rate-limit accessors

/// Whether the GitHub API is currently rate-limiting this client.
public var ghIsRateLimited: Bool {
    get async { await rateLimitActor.isLimited }
}

/// Clears the rate-limit flag. Called at the start of each poll cycle.
nonisolated(nonsending)
public func clearGhRateLimit() async {
    await rateLimitActor.clear()
}

/// Returns a `RateLimitSnapshot` containing `isLimited` and `resetDate` in a single actor hop.
nonisolated(nonsending)
public func ghRateLimitSnapshot() async -> RateLimitSnapshot {
    await rateLimitActor.snapshot()
}
