// GitHubRateLimitHandler.swift
// GitHubClient

import Foundation

public struct RateLimitSnapshot: Sendable, Equatable, Hashable {
    public let isLimited: Bool
    public let resetDate: Date?
    public init(isLimited: Bool, resetDate: Date?) {
        self.isLimited = isLimited
        self.resetDate = resetDate
    }
}

public protocol RateLimitActorProtocol: Actor {
    var isLimited: Bool { get }
    func set(resetAt: TimeInterval?)
    func clear()
    func clearIfNotLimited()
    func snapshot() -> RateLimitSnapshot
}

public actor RateLimitActor: RateLimitActorProtocol {
    public private(set) var isLimited = false
    public private(set) var resetDate: Date?
    private var resetTask: Task<Void, Never>?
    private var generation = 0

    public init() {}

    public func set(resetAt: TimeInterval?) {
        let delay: TimeInterval
        if let ts = resetAt {
            let secondsUntilReset = ts - Date().timeIntervalSince1970
            delay = min(max(secondsUntilReset, 5), 7200)
        } else {
            delay = 3600
        }
        let date = Date().addingTimeInterval(delay)
        log("RateLimitActor › arming: delay=\(Int(delay))s resetDate=\(date)", category: .transport)
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

    public func clear() {
        resetTask?.cancel()
        resetTask = nil
        isLimited = false
        resetDate = nil
    }

    public func clearIfNotLimited() {
        guard !isLimited else { return }
        clear()
    }

    public func snapshot() -> RateLimitSnapshot {
        RateLimitSnapshot(isLimited: isLimited, resetDate: resetDate)
    }

    private func didFire(generation: Int, scheduledDelay: TimeInterval) async {
        guard generation == self.generation else {
            log("RateLimitActor › stale didFire ignored (gen=\(generation) current=\(self.generation))", category: .transport)
            return
        }
        isLimited = false
        resetDate = nil
        resetTask = nil
        log("RateLimitActor › auto-reset fired after \(Int(scheduledDelay))s", category: .transport)
    }
}

public let rateLimitActor = RateLimitActor()

public var ghIsRateLimited: Bool {
    get async { await rateLimitActor.isLimited }
}

nonisolated(nonsending)
public func clearGhRateLimit() async {
    await rateLimitActor.clear()
}

nonisolated(nonsending)
public func ghRateLimitSnapshot() async -> RateLimitSnapshot {
    await rateLimitActor.snapshot()
}
