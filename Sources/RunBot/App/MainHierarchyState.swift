// MainHierarchyState.swift
// RunBot

import Observation
import RunBotCore

// MARK: - MainHierarchyState
//
// Process-lifetime UI state for the hierarchy displayed by `PanelMainView`.
//
// PROBLEM:
// `RootPanelView` conditionally renders one route. Navigating to Settings or
// Step Log removes `PanelMainView` from the SwiftUI hierarchy. Returning
// constructs a fresh instance, destroying child `@State` in `ActionRowView`
// and `InlineJobRowsView`.
//
// SOLUTION:
// Hoist all user-controlled expansion state into this process-lifetime object
// owned by `AppState`. Views read and write through computed properties;
// `@State` is removed from row views for the hoisted fields.
//
// OWNERSHIP:
// - Owned by `AppState` (one instance per process).
// - Never recreated on route changes.
// - Never reset in `navigateBack()` or panel hide/show callbacks.
// - Never persisted to `UserDefaults`; resets on process termination.
//
// KEYING:
// All entries are keyed by `WorkflowActionGroup.ID` (stable across polls).
// Never key by row offset, visible index, title, SHA, or array order.
//
// PRUNING:
// Call `retainGroups(_:)` whenever the set of current action IDs changes.
// This prevents unbounded stale entries from accumulating.

/// Process-lifetime UI state for the hierarchy displayed by `PanelMainView`.
///
/// Preserves workflow row expansion, nested job expansion, and visible-row
/// count across route navigation (Settings ↔ Main, Step Log ↔ Main) and
/// panel hide/unhide.
@MainActor
@Observable
final class MainHierarchyState {

    // MARK: - WorkflowExpansion

    /// Tri-state expansion of a workflow row.
    ///
    /// Using a typed enum (rather than `Bool?`) lets the store distinguish
    /// between "no entry yet" (absent key) and an explicit `.collapsed` set
    /// by user action. This preserves automatic initial-expansion policy for
    /// new rows while honouring user collapse intent on re-navigation.
    enum WorkflowExpansion: Equatable {
        /// User collapsed, or initial state for a non-in-progress workflow.
        case collapsed  // nil  — user collapsed, or initial state for non-inProgress
        /// In-progress workflow showing only running jobs.
        case partial    // false — in-progress partial view
        /// All jobs visible; set by explicit user tap.
        case full       // true  — fully expanded by user tap

        /// The `Bool?` representation used by `ActionRowView` / `RowTapModifier`.
        var value: Bool? {
            switch self {
            case .collapsed: nil
            case .partial:   false
            case .full:      true
            }
        }

        /// Converts from the existing tri-state `Bool?` row representation.
        init(_ value: Bool?) {
            switch value {
            case nil:   self = .collapsed
            case false: self = .partial
            case true:  self = .full
            }
        }
    }

    // MARK: - Stored state

    /// Per-workflow expansion state.
    ///
    /// An absent key means the row has never been visited; it may receive
    /// automatic initial-expansion policy. An explicit `.collapsed` value
    /// represents deliberate user intent and must survive navigation.
    private(set) var workflowExpansions: [WorkflowActionGroup.ID: WorkflowExpansion] = [:]

    /// Per-workflow set of expanded job IDs.
    ///
    /// Absent key is equivalent to an empty set. Stored as optional to avoid
    /// retaining empty sets; `setJobs(_:for:)` clears the key on empty input.
    private(set) var expandedJobIDs: [WorkflowActionGroup.ID: Set<Int>] = [:]

    /// Current "load more" watermark; mirrors `PanelMainView`'s previous `@State`.
    var visibleCount = 10

    // MARK: - Workflow expansion accessors

    /// Returns the stored expansion state, or `nil` if the row is new.
    ///
    /// `nil` is intentionally distinct from `.collapsed`: absent entries may
    /// receive the existing automatic initial-expansion policy, while an
    /// explicit `.collapsed` represents user intent.
    func expansion(for groupID: WorkflowActionGroup.ID) -> WorkflowExpansion? {
        workflowExpansions[groupID]
    }

    /// Stores the expansion state for the given workflow group.
    func setExpansion(_ expansion: WorkflowExpansion, for groupID: WorkflowActionGroup.ID) {
        workflowExpansions[groupID] = expansion
    }

    // MARK: - Job expansion accessors

    /// Returns the set of expanded job IDs for a workflow, or an empty set.
    func jobs(for groupID: WorkflowActionGroup.ID) -> Set<Int> {
        expandedJobIDs[groupID, default: []]
    }

    /// Stores expanded job IDs for a workflow; clears the entry when `jobIDs` is empty.
    func setJobs(_ jobIDs: Set<Int>, for groupID: WorkflowActionGroup.ID) {
        expandedJobIDs[groupID] = jobIDs.isEmpty ? nil : jobIDs
    }

    /// Removes all expanded job IDs for the given workflow group.
    func clearJobs(for groupID: WorkflowActionGroup.ID) {
        expandedJobIDs[groupID] = nil
    }

    // MARK: - Pruning

    /// Removes state for groups that are no longer present in the current poll.
    ///
    /// Call this whenever the set of `WorkflowActionGroup.ID`s changes.
    /// Reordering the same set of IDs must not affect stored state.
    func retainGroups(_ validGroupIDs: Set<WorkflowActionGroup.ID>) {
        workflowExpansions = workflowExpansions.filter { validGroupIDs.contains($0.key) }
        expandedJobIDs = expandedJobIDs.filter { validGroupIDs.contains($0.key) }
    }
}
