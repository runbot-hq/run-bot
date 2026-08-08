// ISO8601DateParser.swift
// RunBotCore
import Foundation
import GitHubClient

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
    /// Parses timestamps with fractional seconds (e.g. `"2026-08-08T16:07:14.123Z"`).
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Parses standard timestamps without fractional seconds (e.g. `"2026-08-08T16:07:14Z"`).
    /// GitHub commonly omits fractional seconds; this formatter handles that case.
    private let standard = ISO8601DateFormatter()

    /// The module-wide shared instance. Use this from all call sites.
    public static let shared = ISO8601DateParser()

    /// Private initialiser — callers must use `shared`.
    private init() {}

    /// Parses standard and fractional ISO-8601 timestamps.
    ///
    /// Tries fractional-seconds format first (GitHub sometimes includes milliseconds),
    /// then falls back to standard format (GitHub commonly omits fractional seconds).
    public func parse(_ value: String) -> Date? {
        if let date = fractional.date(from: value) {
            #if DEBUG
            log(
                "[TimingTrace][actor-parse] mode=fractional raw=\(value) parsed=\(date)",
                category: .runner
            )
            #endif
            return date
        }
        if let date = standard.date(from: value) {
            #if DEBUG
            log(
                "[TimingTrace][actor-parse] mode=standard raw=\(value) parsed=\(date)",
                category: .runner
            )
            #endif
            return date
        }
        #if DEBUG
        log(
            "[TimingTrace][actor-parse] FAILED raw=\(value)",
            category: .runner
        )
        #endif
        return nil
    }
}
