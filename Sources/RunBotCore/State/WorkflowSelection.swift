// WorkflowSelection.swift
// RunBotCore

import Observation

/// In-memory selection state for the workflow hierarchy and step-log detail.
///
/// Owns workflow → job → step selection using stable domain identifiers only.
/// Downstream selections are cleared whenever an upstream selection changes.
/// No persistence, stores, or runtime integration.
@MainActor
@Observable
public final class WorkflowSelection {

    /// Selected `WorkflowActionGroup` identifier.
    public var workflowID: String?
    /// Selected `ActiveJob` identifier (raw GitHub job ID).
    public var jobID: Int?
    /// Selected step identifier — 1-based `GitHubStep.number` within the job.
    public var stepNumber: Int?

    /// Creates an empty selection state.
    public init() {}

    /// Selects a workflow and clears downstream job/step selection.
    public func selectWorkflow(_ id: String?) {
        workflowID = id
        jobID = nil
        stepNumber = nil
    }

    /// Selects a job and clears downstream step selection.
    public func selectJob(_ id: Int?) {
        jobID = id
        stepNumber = nil
    }

    /// Selects a step.
    public func selectStep(_ number: Int?) {
        stepNumber = number
    }

    /// Selects a job within its owning workflow.
    ///
    /// Hierarchy rows stay visible for workflows other than the selected one,
    /// so the full path must be set on tap. Keeps the current step selection
    /// when the job is unchanged (e.g. a collapse tap); clears it otherwise.
    public func selectJob(_ id: Int, inWorkflow workflowID: String) {
        self.workflowID = workflowID
        if jobID != id { stepNumber = nil }
        jobID = id
    }

    /// Selects a step within its owning workflow and job.
    ///
    /// Sets the full path so a step tap in any expanded workflow shows the
    /// correct log, even when a different workflow or job was selected before.
    public func selectStep(_ number: Int, ofJob jobID: Int, inWorkflow workflowID: String) {
        self.workflowID = workflowID
        self.jobID = jobID
        stepNumber = number
    }

    /// Removes any selections that no longer exist in the current data.
    ///
    /// Call after the workflow list is refreshed so stale selections do not
    /// silently point at removed items.
    public func reconcile(workflows: [WorkflowActionGroup]) {
        guard let wid = workflowID else { return }
        guard let workflow = workflows.first(where: { $0.id == wid }) else {
            selectWorkflow(nil)
            return
        }
        guard let jid = jobID else { return }
        guard let job = workflow.jobs.first(where: { $0.id == jid }) else {
            selectJob(nil)
            return
        }
        guard let snum = stepNumber else { return }
        if !job.steps.contains(where: { $0.number == snum }) {
            selectStep(nil)
        }
    }
}
