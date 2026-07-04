// GitHubLogger.swift
// RunBotGitHubClient

/// Log categories used by `GitHubClient` types.
public enum LogCategory: String, Sendable {
    /// Network transport events (requests, responses, errors).
    case transport
    /// GitHub API call events.
    case api
    /// Authentication and token events.
    case auth
    /// General-purpose diagnostic events.
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

/// A no-op logger used as a safe default when no logger is injected.
public struct SilentGitHubLogger: GitHubLogger {
    /// Creates a new silent logger.
    public init() {}
    /// Does nothing.
    public nonisolated func log(_ message: String, category: LogCategory) {}
}
