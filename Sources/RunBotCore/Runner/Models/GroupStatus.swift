// GroupStatus.swift
// RunBotCore

// MARK: - GroupStatus

/// Type-safe status for a workflow run group (commit/PR trigger).
/// Mirrors ci-dash.py's group status derivation logic.
public enum GroupStatus {
    /// At least one sibling run is in progress.
    case inProgress
    /// Jobs have not yet loaded and no run is active — transient fetch window.
    case loading
    /// No run is in progress, but at least one is queued.
    case queued
    /// All runs have concluded (or all jobs are done).
    case completed
}

// MARK: - GroupStatus + display helpers

/// Display and sorting helpers for `GroupStatus`.
extension GroupStatus {
    /// Sort priority for display ordering.
    ///
    /// Lower value = higher display priority (in-progress before loading before queued before completed).
    public var sortPriority: Int {
        switch self {
        case .inProgress: return 0
        case .loading:    return 1
        case .queued:     return 2
        case .completed:  return 3
        }
    }
}

// MARK: - GroupStatus + RBStatus

/// RBStatus bridging for `GroupStatus`.
extension GroupStatus {
    /// Maps `GroupStatus` to the shared `RBStatus` for indicator display.
    /// For completed groups use `WorkflowActionGroup.rbStatus` to get the
    /// conclusion-aware mapping.
    public var rbStatus: RBStatus {
        switch self {
        case .inProgress: return .inProgress
        case .loading:    return .queued
        case .queued:     return .queued
        case .completed:  return .unknown
        }
    }
}
