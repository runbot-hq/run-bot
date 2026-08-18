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
    /// Commit message / PR title of the selected workflow, shown as the detail heading.
    let workflowName: String?
    /// Shared log fetcher threaded from the composition root.
    @Binding var logFetcher: LogFetcher

    /// The pane content: optional workflow title header, then step log or placeholder.
    var body: some View {
        if let job = selectedJob, let step = selectedStep {
            VStack(spacing: 0) {
                if let name = workflowName {
                    HStack {
                        Text(name)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 44)

                    Divider()
                }

                StepLogContentView(
                    job: job,
                    step: step,
                    logFetcher: $logFetcher
                )
                .id(StepLogSelectionID(jobID: job.id, stepNumber: step.number))
            }
        } else {
            MigrationColumnPlaceholder(
                title: "Select a step",
                systemImage: "doc.plaintext"
            )
        }
    }
}
