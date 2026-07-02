// ISO8601DateParser.swift
// RunBotCore
import Foundation

// MARK: - ISO8601DateParser

/// Shared actor-isolated ISO-8601 date parser for the RunBotCore module.
///
/// `ISO8601DateFormatter` is expensive to allocate (it loads ICU calendars on
/// init) and is not `Sendable`. Wrapping a single instance in an actor gives
/// thread-safe reuse with no lock boilerplate and no `@unchecked Sendable`
/// escape hatch — fully compiler-verified by Swift 6.2 strict concurrency.
///
/// Previously three identical private actors (`DateParserActor`,
/// `WorkflowDateParserActor`, `GitHubDateParserActor`) lived in separate files.
/// They are consolidated here so callers share one allocated formatter.
public actor ISO8601DateParser {
    /// The underlying ISO-8601 formatter; actor isolation provides thread safety.
    private let iso = ISO8601DateFormatter()

    /// The module-wide shared instance. Use this from all call sites.
    public static let shared = ISO8601DateParser()

    /// Private initialiser — callers must use `shared`.
    private init() {}

    /// Parses an ISO-8601 date string. Returns `nil` on failure.
    public func parse(_ str: String) -> Date? {
        iso.date(from: str)
    }

    /// Builds an `ActiveJob` from a decoded `JobPayload` using the actor-owned formatter.
    ///
    /// Centralising job construction here keeps `makeActiveJob(from:iso:isDimmed:)`
    /// as the single source of truth while hiding the formatter from callers.
    public func makeJob(from payload: JobPayload, isDimmed: Bool = false) -> ActiveJob {
        makeActiveJob(from: payload, iso: iso, isDimmed: isDimmed)
    }
}
