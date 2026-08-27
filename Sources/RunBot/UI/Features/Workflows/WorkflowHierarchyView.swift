// WorkflowHierarchyView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - WorkflowHierarchyView

/// Workflow hierarchy column — workflows with expandable nested jobs and steps.
///
/// Replaces the former workflow/job/step columns (issue #2880) so ownership is
/// visible in the UI hierarchy instead of being synchronised across columns.
/// Expansion is purely user-driven: nothing expands or collapses because a
/// status changed. Selection lives in the shared `WorkflowSelection`
/// so the step-log detail column stays in sync.
@MainActor
struct WorkflowHierarchyView: View {
    /// Observable runner state. Observed directly to stay live across polls.
    @Bindable var runnerState: RunnerState
    /// Shared selection state owned by `AppNavigationSplitView`.
    var selection: WorkflowSelection

    /// IDs of workflows whose job lists are currently expanded.
    @State private var expandedWorkflows: Set<String> = []
    /// IDs of jobs whose step lists are currently expanded.
    @State private var expandedJobs: Set<Int> = []

    /// Current workflow snapshot derived from the observable runner state.
    private var workflows: [WorkflowActionGroup] { runnerState.actions }

    /// The column layout: title header, divider, hierarchy list or empty-state placeholder.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workflows")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider()

            Group {
            if workflows.isEmpty {
                ColumnPlaceholder(
                    title: "No workflows",
                    systemImage: "bolt.horizontal.circle"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(workflows) { workflow in
                            WorkflowNode(
                                workflow: workflow,
                                selection: selection,
                                isExpanded: expandedWorkflows.contains(workflow.id),
                                expandedJobs: $expandedJobs,
                                onToggleExpansion: { toggleWorkflowExpansion(workflow.id) }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
            .onChange(of: runnerState.actions) { _, actions in
                selection.reconcile(workflows: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Toggles the expanded state of a workflow's job list.
    private func toggleWorkflowExpansion(_ id: String) {
        if expandedWorkflows.contains(id) {
            expandedWorkflows.remove(id)
        } else {
            expandedWorkflows.insert(id)
        }
    }
}

// MARK: - WorkflowNode

/// One workflow entry: the selectable workflow row plus its nested job group.
private struct WorkflowNode: View {
    /// The workflow this node represents.
    let workflow: WorkflowActionGroup
    /// Shared selection state mutated on row tap.
    var selection: WorkflowSelection
    /// Whether this workflow's job group is currently expanded.
    let isExpanded: Bool
    /// IDs of jobs whose step lists are currently expanded, owned by the hierarchy root.
    @Binding var expandedJobs: Set<Int>
    /// Called when the user taps the workflow row to toggle its job group.
    let onToggleExpansion: () -> Void

    /// `true` when this workflow is the deepest selected hierarchy level.
    private var isSelected: Bool {
        selection.workflowID == workflow.id && selection.jobID == nil
    }

    /// The workflow row and, when expanded, its nested job group.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                // Re-clicking the selected workflow only toggles expansion so an
                // active job/step selection (and its log) is not discarded.
                if selection.workflowID != workflow.id {
                    selection.selectWorkflow(workflow.id)
                }
                onToggleExpansion()
            } label: {
                WorkflowRow(workflow: workflow)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(SelectionBackground(isSelected: isSelected))

            if isExpanded, !workflow.jobs.isEmpty {
                jobsGroup
            }
        }
    }

    /// The nested job nodes inside the subtle group fill and stroke.
    private var jobsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(workflow.jobs.enumerated()), id: \.element.id) { index, job in
                JobNode(
                    workflowID: workflow.id,
                    job: job,
                    selection: selection,
                    isLast: index == workflow.jobs.count - 1,
                    isExpanded: expandedJobs.contains(job.id),
                    onToggleExpansion: { toggleJobExpansion(job.id) }
                )
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.leading, 12)
        .padding(.bottom, 4)
    }

    /// Toggles the expanded state of a job's step list.
    private func toggleJobExpansion(_ id: Int) {
        if expandedJobs.contains(id) {
            expandedJobs.remove(id)
        } else {
            expandedJobs.insert(id)
        }
    }
}

// MARK: - JobNode

/// One job entry: connector line, selectable job row, and nested step rows.
private struct JobNode: View {
    /// Identifier of the workflow that owns this job.
    let workflowID: String
    /// The job this node represents.
    let job: ActiveJob
    /// Shared selection state mutated on row tap.
    var selection: WorkflowSelection
    /// Whether this is the last job in the group (controls the connector elbow).
    let isLast: Bool
    /// Whether this job's step list is currently expanded.
    let isExpanded: Bool
    /// Called when the user taps the job row to toggle its step list.
    let onToggleExpansion: () -> Void

    /// `true` when this job is the deepest selected hierarchy level.
    private var isSelected: Bool {
        selection.jobID == job.id && selection.stepNumber == nil
    }

    /// The connector, job row, and optional expanded step list.
    ///
    /// `isLast && !isExpanded` is intentional: when the last job is expanded the
    /// connector keeps its full-height bar so the tree line runs through the
    /// step list instead of terminating at the job row.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TreeConnector(isLast: isLast && !isExpanded)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    selection.selectJob(job.id, inWorkflow: workflowID)
                    onToggleExpansion()
                } label: {
                    JobRow(job: job)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(SelectionBackground(isSelected: isSelected))

                if isExpanded, !job.steps.isEmpty {
                    stepsContainer
                }
            }
        }
    }

    /// Vertically stacked step nodes shown when the job is expanded.
    ///
    /// `GitHubStep` has no `id` property — `number` is the 1-based step index
    /// assigned by the GitHub API and is stable within a job run.
    private var stepsContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(job.steps.enumerated()), id: \.element.number) { index, step in
                StepNode(
                    workflowID: workflowID,
                    job: job,
                    step: step,
                    selection: selection,
                    isLast: index == job.steps.count - 1
                )
            }
        }
        .padding(.leading, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - StepNode

/// One step entry: connector line and selectable step row.
private struct StepNode: View {
    /// Identifier of the workflow that owns this step's job.
    let workflowID: String
    /// The job that owns this step.
    let job: ActiveJob
    /// The step this node represents.
    let step: GitHubStep
    /// Shared selection state mutated on row tap.
    var selection: WorkflowSelection
    /// Whether this is the last step in the list (controls the connector elbow).
    let isLast: Bool

    /// `true` when this step is the selected hierarchy leaf.
    private var isSelected: Bool {
        selection.jobID == job.id && selection.stepNumber == step.number
    }

    /// The connector and step row.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TreeConnector(isLast: isLast)
                .frame(maxHeight: .infinity)

            Button {
                selection.selectStep(step.number, ofJob: job.id, inWorkflow: workflowID)
            } label: {
                StepRow(step: step)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(SelectionBackground(isSelected: isSelected))
        }
    }
}

// MARK: - SelectionBackground

/// Rounded highlight shown behind the deepest selected hierarchy row.
private struct SelectionBackground: View {
    /// Whether the row this background belongs to is currently selected.
    let isSelected: Bool

    /// The highlight shape — transparent when not selected.
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
    }
}
