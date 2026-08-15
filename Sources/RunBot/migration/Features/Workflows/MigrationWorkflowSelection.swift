// MigrationWorkflowSelection.swift
// RunBot

import Observation

/// In-memory selection state for the four-pane workflow layout.
///
/// Owns workflow → job → step selection using stable domain identifiers only.
/// Downstream selections are cleared whenever an upstream selection changes.
/// No persistence, stores, or runtime integration.
@MainActor
@Observable
final class MigrationWorkflowSelection {

    /// Selected `WorkflowActionGroup` identifier.
    var workflowID: String?
    /// Selected `ActiveJob` identifier (raw GitHub job ID).
    var jobID: Int?
    /// Selected step identifier — 1-based `GitHubStep.number` within the job.
    var stepNumber: Int?

    /// Selects a workflow and clears downstream job/step selection.
    func selectWorkflow(_ id: String?) {
        workflowID = id
        jobID = nil
        stepNumber = nil
    }

    /// Selects a job and clears downstream step selection.
    func selectJob(_ id: Int?) {
        jobID = id
        stepNumber = nil
    }

    /// Selects a step.
    func selectStep(_ number: Int?) {
        stepNumber = number
    }

    /// Removes any selections that no longer exist in the current data.
    ///
    /// Call after the workflow list is refreshed so stale selections do not
    /// silently point at removed items.
    func reconcile(workflows: [WorkflowActionGroup]) {
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
