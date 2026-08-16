// PendingFinalGroup.swift
// RunBotCore

import Foundation

// MARK: - PendingFinalGroup

/// Tracks a workflow group that disappeared from the active/completed API responses
/// but whose final state has not yet been resolved.
///
/// The group is retried on subsequent poll cycles up to `maxAttempts` before being
/// abandoned. This prevents the permanent blue indicator (issue #2859) when GitHub
/// transiently returns `nil` for a run's conclusion after the run vanishes from the
/// active-runs endpoint.
///
/// - Note: `Sendable` conformance is required because this type is carried across
///   the actor boundary in `GroupPollResult`.
public struct PendingFinalGroup: Sendable {
    /// The group snapshot from the previous poll cycle.
    public let group: WorkflowActionGroup
    /// Number of poll cycles this group has been retried.
    public let attempts: Int

    /// Maximum number of retry attempts before the group is abandoned.
    public static let maxAttempts = 5

    /// Creates a new pending-final group.
    /// - Parameters:
    ///   - group: The group snapshot to retry.
    ///   - attempts: Number of prior attempts (defaults to 1 for a fresh entry).
    public init(group: WorkflowActionGroup, attempts: Int = 1) {
        self.group = group
        self.attempts = attempts
    }
}
