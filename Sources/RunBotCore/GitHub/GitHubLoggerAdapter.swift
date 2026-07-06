// GitHubLoggerAdapter.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - GitHubLoggerAdapter

/// Bridges `GitHubLogger` (defined in `GitHubClient`) to the RunBot unified
/// logging system (`log()` free function in Logger.swift).
///
/// Passed to `GitHubClient` at construction time in `AppDelegate` so that
/// all `GitHubClient` diagnostic messages appear in the same `os.Logger`
/// stream as the rest of the app, filtered under the matching category.
///
/// ## Sendability
/// `GitHubLoggerAdapter` is a stateless value type; `Sendable` conformance is
/// synthesised automatically by the compiler and satisfies the `GitHubLogger`
/// protocol requirement.
///
/// ## Unknown categories
/// `GitHubClient` callers pass category strings as raw kebab-case literals
/// (e.g. `"transport"`, `"oauth"`). Unknown strings fall back to `.general`
/// rather than crashing, because `GitHubClient` can emit new category strings
/// before `RunBotCore` is updated. A `#if DEBUG` assertion fires so that new
/// category strings are caught early during development or CI rather than
/// silently degrading category metadata in production.
public struct GitHubLoggerAdapter: GitHubLogger {

    /// Creates a new `GitHubLoggerAdapter` instance.
    public init() {}

    /// Forwards a message from `GitHubClient` into `os.Logger` via the RunBot
    /// `log()` free function.
    ///
    /// The `category` string comes from `GitHubClient` callers as a raw
    /// kebab-case string (e.g. `"transport"`). It is mapped to a `LogCategory`
    /// case; unrecognised strings fall back to `.general` rather than crashing.
    ///
    /// - Note: In `DEBUG` builds, a `preconditionFailure` fires on the first
    ///   call with an unknown category so that new `GitHubClient` strings are
    ///   caught at development / CI time rather than silently falling back.
    public nonisolated func log(_ message: String, category: String) {
        guard let resolvedCategory = LogCategory(rawValue: category) else {
#if DEBUG
            preconditionFailure(
                "GitHubLoggerAdapter: unknown GitHubClient log category '\(category)'. "
                + "Add it to LogCategory.RawValue or update GitHubClient to use an existing category."
            )
#else
            RunBotCore.log(message, category: .general)
            return
#endif
        }
        RunBotCore.log(message, category: resolvedCategory)
    }
}
