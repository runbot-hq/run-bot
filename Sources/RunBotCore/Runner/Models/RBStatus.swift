// RBStatus.swift
// RunBotCore

// MARK: - RBStatus

/// Semantic display-status values shared across RunBotCore and the UI layer.
///
/// Cases are defined here in `RunBotCore` so that `ActiveJob.rbStatus` can be
/// computed without importing SwiftUI or AppKit.
/// The `color` property is added via a `RunBot`-layer extension in `DesignTokens.swift`.
public enum RBStatus: Sendable {
    /// A job or workflow step that is currently executing.
    case inProgress
    /// A job or workflow step that completed successfully.
    case success
    /// A job or workflow step that failed.
    case failed
    /// A job or workflow step that is waiting to run.
    case queued
    /// A job or workflow step that was intentionally skipped.
    case skipped
    /// A job or workflow step that was explicitly cancelled.
    case cancelled
    /// An unrecognised or unavailable status.
    case unknown
}
