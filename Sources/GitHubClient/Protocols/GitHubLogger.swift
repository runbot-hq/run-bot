// GitHubLogger.swift
// GitHubClient

/// Log categories used by `GitHubClient` types.
public enum LogCategory: String, Sendable {
    /// Transport-layer diagnostics (API calls, pagination, rate limits).
    case transport
    /// General API operation logs.
    case api
    /// Authentication and OAuth flow logs.
    case auth
    /// Uncategorised log messages.
    case general
}

/// Injectable logging protocol used by `GitHubClient` types to forward
/// diagnostic messages to the host app's logging system.
///
/// Conforming types must be `Sendable` and run `log` on any isolation domain
/// (hence `nonisolated`).
public protocol GitHubLogger: Sendable {
    /// Emits a diagnostic message.
    /// - Parameters:
    ///   - message: The log message string.
    ///   - category: The log category.
    nonisolated func log(_ message: String, category: LogCategory)
}

/// A no-op logger used as a default when no logger is injected.
public struct SilentGitHubLogger: GitHubLogger {
    /// Creates a new `SilentGitHubLogger` instance.
    public init() {}
    /// No-op implementation that discards the message.
    public nonisolated func log(_ message: String, category: LogCategory) {}
}
