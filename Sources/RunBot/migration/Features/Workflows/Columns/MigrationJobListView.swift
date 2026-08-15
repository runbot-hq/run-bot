// MigrationJobListView.swift
// RunBot

import SwiftUI

/// Jobs column — renders job rows or a contextual placeholder.
struct MigrationJobListView: View {
    let jobs: [ActiveJob]
    var selection: MigrationWorkflowSelection

    /// The column layout.
    var body: some View {
        MigrationWorkflowColumn(title: "Jobs") {
            if selection.workflowID == nil {
                MigrationColumnPlaceholder(
                    title: "Select a workflow",
                    systemImage: "list.bullet.rectangle"
                )
            } else if jobs.isEmpty {
                MigrationColumnPlaceholder(
                    title: "No jobs",
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                List(jobs, selection: Binding(
                    get: { selection.jobID },
                    set: { selection.selectJob($0) }
                )) { job in
                    MigrationJobRow(job: job)
                        .tag(job.id)
                }
                .listStyle(.plain)
            }
        }
    }
}
