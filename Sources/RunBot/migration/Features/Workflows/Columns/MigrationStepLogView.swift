// MigrationStepLogView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

/// Composite identity used to reset `StepLogContentView` state when the
/// selected job/step pair changes. Step numbers repeat across jobs, so
/// both values are required.
private struct StepLogSelectionID: Hashable, Sendable {
    /// The GitHub Actions job ID that owns the selected step.
    let jobID: Int
    /// The step number within the job (1-based, as returned by the GitHub API).
    let stepNumber: Int
}

/// Step-log pane — renders the full step log using the shared `StepLogContentView`.
struct MigrationStepLogView: View {
    /// The job that owns the selected step.
    let selectedJob: ActiveJob?
    /// The currently selected step, or `nil` when none is selected.
    let selectedStep: GitHubStep?
    /// Shared log fetcher threaded from the composition root.
    @Binding var logFetcher: LogFetcher

    /// The pane content.
    var body: some View {
        MigrationWorkflowColumn(title: "Step log") {
            if let job = selectedJob, let step = selectedStep {
                StepLogContentView(
                    job: job,
                    step: step,
                    logFetcher: $logFetcher
                )
                .id(StepLogSelectionID(jobID: job.id, stepNumber: step.number))
            } else {
                MigrationColumnPlaceholder(
                    title: "Select a step",
                    systemImage: "doc.plaintext"
                )
            }
        }
    }
}
