// APICallCounter.swift
// GitHubClient
import Foundation

public struct APICallCounterSnapshot: Sendable, Equatable {
    public let count: Int
    public let limit: Int
    public var fraction: Double {
        guard limit > 0 else { return 0.0 }
        return max(0.0, min(Double(count) / Double(limit), 1.0))
    }
    public init(count: Int, limit: Int) {
        self.count = count
        self.limit = limit
    }
}

public protocol APICallCounterProtocol: Actor {
    func record()
    func snapshot() -> APICallCounterSnapshot
}

public actor APICallCounter: APICallCounterProtocol {
    public static let shared = APICallCounter()
    public static let hourlyLimit = 5_000
    var timestamps: [ContinuousClock.Instant] = []

    public init() {}

    public func record() {
        purge()
        timestamps.append(.now)
        if timestamps.count > Self.hourlyLimit {
            timestamps = Array(timestamps.suffix(Self.hourlyLimit))
        }
    }

    public func snapshot() -> APICallCounterSnapshot {
        purge()
        return APICallCounterSnapshot(count: timestamps.count, limit: Self.hourlyLimit)
    }

    private func purge() {
        let cutoff = ContinuousClock.now - .seconds(3_600)
        if let idx = timestamps.firstIndex(where: { $0 >= cutoff }) {
            if idx > 0 { timestamps.removeFirst(idx) }
        } else {
            timestamps.removeAll()
        }
    }
}

public let apiCallCounter = APICallCounter.shared
