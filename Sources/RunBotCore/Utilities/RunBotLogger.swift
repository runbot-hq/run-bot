// RunBotLogger.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - RunBotLogger

/// Bridges `GitHubLogger` (defined in `GitHubClient`) to the RunBot unified
/// logging system (`log()` free function in Logger.swift).
///
/// Passed to `OAuthService` at construction time in `AppDelegate` so that
/// OAuth diagnostic messages appear in the same `os.Logger` stream as the
/// rest of the app, filtered under the `.transport` category.
///
/// ## Sendability
/// `RunBotLogger` is a stateless value type; `Sendable` conformance is
/// synthesised automatically by the compiler and satisfies the `GitHubLogger`
/// protocol requirement.
public struct RunBotLogger: GitHubLogger {

    /// Creates a new `RunBotLogger` instance.
    public init() {}

    /// Forwards a message from `GitHubClient` into `os.Logger` via the RunBot
    /// `log()` free function.
    ///
    /// The `category` string comes from `GitHubClient` callers as a raw
    /// kebab-case string (e.g. `"transport"`). It is mapped to a `LogCategory`
    /// case; unrecognised strings fall back to `.general` rather than crashing,
    /// because `GitHubClient` can in principle emit new category strings before
    /// `RunBotCore` is updated.
    public nonisolated func log(_ message: String, category: String) {
        let resolvedCategory = LogCategory(rawValue: category) ?? .general
        RunBotCore.log(message, category: resolvedCategory)
    }
}
