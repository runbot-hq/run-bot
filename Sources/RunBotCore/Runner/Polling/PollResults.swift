// PollResults.swift
// RunBotCore
import Foundation

// MARK: - Poll result value types

/// Result returned by `PollResultBuilder.buildJobState`.
public struct JobPollResult: Sendable {
    /// Jobs to display in the popover (in_progress → queued → cached done).
    public let display: [ActiveJob]
    /// Updated completed-job cache, trimmed to `PollResultBuilder.jobCacheLimit` entries.
    public let newCache: [Int: ActiveJob]
    /// Live-job snapshot for the next poll's diff.
    public let newPrevLive: [Int: ActiveJob]

    /// Creates a `JobPollResult` with all fields.
    /// - Parameters:
    ///   - display: Jobs to show in the popover.
    ///   - newCache: Updated completed-job cache.
    ///   - newPrevLive: Live-job snapshot for the next poll's diff.
    public init(display: [ActiveJob], newCache: [Int: ActiveJob], newPrevLive: [Int: ActiveJob]) {
        self.display = display
        self.newCache = newCache
        self.newPrevLive = newPrevLive
    }
}

/// Result returned by `PollResultBuilder.buildGroupState`.
public struct GroupPollResult: Sendable {
    /// Action groups to display in the popover.
    public let display: [WorkflowActionGroup]
    /// Updated group cache, trimmed to `PollResultBuilder.groupCacheLimit` entries.
    public let newGroupCache: [String: WorkflowActionGroup]
    /// Live-group snapshot for the next poll's diff.
    public let newPrevLiveGroups: [String: WorkflowActionGroup]
    /// Groups that vanished from the API response but whose final state could not
    /// yet be resolved. These are retried on subsequent poll cycles (issue #2859).
    ///
    /// Keyed by `compositeCacheKey` so the actor can merge them into the next
    /// poll's `snapPrevGroups` for retry without duplicating live entries.
    public let pendingFinalGroups: [String: PendingFinalGroup]

    /// Creates a `GroupPollResult` with all fields.
    /// - Parameters:
    ///   - display: Groups to show in the popover.
    ///   - newGroupCache: Updated group cache.
    ///   - newPrevLiveGroups: Live-group snapshot for the next poll's diff.
    ///   - pendingFinalGroups: Groups awaiting final-state resolution.
    public init(
        display: [WorkflowActionGroup],
        newGroupCache: [String: WorkflowActionGroup],
        newPrevLiveGroups: [String: WorkflowActionGroup],
        pendingFinalGroups: [String: PendingFinalGroup] = [:]
    ) {
        self.display = display
        self.newGroupCache = newGroupCache
        self.newPrevLiveGroups = newPrevLiveGroups
        self.pendingFinalGroups = pendingFinalGroups
    }
}
