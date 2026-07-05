// WorkflowContextMenuModifier.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - Pasteboard helper
/// Copies `text` to the general pasteboard.
/// `@MainActor` enforced -- `NSPasteboard` requires main-thread access.
@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - WorkflowContextMenuModifier
/// `ViewModifier` that attaches a workflow-level right-click context menu to an `ActionRowView`.
///
/// All mutations are routed through `WorkflowActionsUseCase` and launched as
/// plain structured `Task { }` values (never `Task.detached`) so they inherit
/// the `@MainActor` context of the SwiftUI button closure, surface errors
/// correctly, and are cancellable on view dismissal via `.onDisappear` (P9).
///
/// `currentTask` is always cancelled before being overwritten so no in-flight
/// task is silently orphaned when the user fires a second action in quick
/// succession (e.g. Re-run All followed immediately by Cancel).
private struct WorkflowContextMenuModifier: ViewModifier {
    /// The workflow action group this menu acts on.
    let group: WorkflowActionGroup

    /// Use-case that owns all transport mutations (P7, P8).
    private let actions = WorkflowActionsUseCase()

    /// Tracks the most recently launched mutation task so it can be cancelled
    /// when the view disappears or a new action is triggered (P9 — structured lifetime).
    @State private var currentTask: Task<Void, Never>?

    /// Wraps `content` with a right-click context menu and cancels any
    /// in-flight mutation task when the view disappears.
    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            .onDisappear { currentTask?.cancel() }
    }

    /// Context menu items: re-run failed, re-run all, cancel, copy log, open on GitHub.
    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = group.groupStatus == .completed
        let isLive = group.groupStatus == .inProgress
        let scope = group.repo
        let runIDs = group.runs.map { $0.id }

        // Re-run failed
        Button {
            currentTask?.cancel()
            currentTask = Task { await actions.rerunFailed(runIDs: runIDs, scope: scope) }
        } label: { Label("Re-run Failed Jobs", systemImage: "arrow.counterclockwise") }
        .disabled(!isConcluded)

        // Re-run all
        Button {
            currentTask?.cancel()
            currentTask = Task { await actions.rerunAll(runIDs: runIDs, scope: scope) }
        } label: { Label("Re-run All Jobs", systemImage: "arrow.clockwise") }
        .disabled(!isConcluded)

        // Cancel
        Button {
            currentTask?.cancel()
            currentTask = Task { await actions.cancel(runIDs: runIDs, scope: scope) }
        } label: { Label("Cancel", systemImage: "xmark.circle") }
        .disabled(!isLive)

        Divider()

        // Copy log
        // ⚠️ LogFetcher() is allocated inline here — DI follow-up tracked in #1518.
        Button {
            let capturedGroup = group
            currentTask?.cancel()
            currentTask = Task {
                guard let text = await LogFetcher().fetchActionLogs(group: capturedGroup),
                      !text.isEmpty else { return }
                copyToPasteboard(text)
            }
        } label: { Label("Copy Log", systemImage: "doc.on.doc") }

        Divider()

        // Open on GitHub — synchronous, no Task needed
        Button {
            guard let htmlUrl = group.runs.first?.htmlUrl,
                  let runUrl = URL(string: htmlUrl) else { return }
            NSWorkspace.shared.open(runUrl)
        } label: { Label("Show Workflow on GitHub", systemImage: "doc.text") }
        .disabled(group.runs.first?.htmlUrl == nil)

        Button {
            let sha = group.headSha
            let repo = group.repo
            guard let url = URL(string: "https://github.com/\(repo)/commit/\(sha)") else { return }
            NSWorkspace.shared.open(url)
        } label: { Label("Show Commit on GitHub", systemImage: "number") }
    }
}

// MARK: - JobContextMenuModifier
/// `ViewModifier` that attaches a job-level right-click context menu to a `JobRowCard`.
///
/// All mutations are routed through `WorkflowActionsUseCase` and launched as
/// plain structured `Task { }` values (never `Task.detached`) so they inherit
/// the `@MainActor` context of the SwiftUI button closure, surface errors
/// correctly, and are cancellable on view dismissal via `.onDisappear` (P9).
///
/// `currentTask` is always cancelled before being overwritten so no in-flight
/// task is silently orphaned when the user fires a second action in quick
/// succession (e.g. Re-run Job followed immediately by Cancel).
private struct JobContextMenuModifier: ViewModifier {
    /// The job this menu acts on.
    let job: ActiveJob
    /// The parent workflow action group, used for run-level re-run and cancel actions.
    let group: WorkflowActionGroup

    /// Use-case that owns all transport mutations (P7, P8).
    private let actions = WorkflowActionsUseCase()

    /// Tracks the most recently launched mutation task so it can be cancelled
    /// when the view disappears or a new action is triggered (P9 — structured lifetime).
    @State private var currentTask: Task<Void, Never>?

    /// Wraps `content` with a right-click context menu and cancels any
    /// in-flight mutation task when the view disappears.
    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            .onDisappear { currentTask?.cancel() }
    }

    /// Context menu items: re-run job, cancel, copy log, open on GitHub.
    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = job.jobConclusion != nil
        let isLive = job.jobStatus == .inProgress
        let scope = group.repo

        // Re-run job
        Button {
            let jobID = job.id
            currentTask?.cancel()
            currentTask = Task { await actions.rerunJob(jobID: jobID, scope: scope) }
        } label: { Label("Re-run Job", systemImage: "arrow.counterclockwise") }
        .disabled(!isConcluded)

        // Cancel
        Button {
            let runIDs = group.runs.map { $0.id }
            currentTask?.cancel()
            currentTask = Task { await actions.cancel(runIDs: runIDs, scope: scope) }
        } label: { Label("Cancel", systemImage: "xmark.circle") }
        .disabled(!isLive)

        Divider()

        // Copy log
        // ⚠️ LogFetcher() is allocated inline here — DI follow-up tracked in #1518.
        Button {
            let capturedJob = job
            currentTask?.cancel()
            currentTask = Task {
                guard let text = await LogFetcher().fetchJobLog(jobID: capturedJob.id, scope: scope),
                      !text.isEmpty else { return }
                copyToPasteboard(text)
            }
        } label: { Label("Copy Log", systemImage: "doc.on.doc") }

        Divider()

        // Open on GitHub — synchronous, no Task needed
        Button {
            guard let htmlUrl = job.htmlUrl, let url = URL(string: htmlUrl) else { return }
            NSWorkspace.shared.open(url)
        } label: { Label("Show Job on GitHub", systemImage: "doc.text") }
        .disabled(job.htmlUrl == nil)
    }
}

// MARK: - View extensions
/// Convenience modifiers for attaching workflow, job, and step context menus to any `View`.
extension View {
    /// Attaches a workflow-level right-click context menu (re-run, cancel, copy log, open on GitHub).
    func workflowContextMenu(group: WorkflowActionGroup) -> some View {
        modifier(WorkflowContextMenuModifier(group: group))
    }

    /// Attaches a job-level right-click context menu (re-run, cancel, copy log, open on GitHub).
    func jobContextMenu(job: ActiveJob, group: WorkflowActionGroup) -> some View {
        modifier(JobContextMenuModifier(job: job, group: group))
    }

    /// Attaches a step-level right-click context menu (copy step name, view log).
    func stepContextMenu(step: GitHubStep, onTap: @escaping () -> Void) -> some View {
        modifier(StepContextMenuModifier(step: step, onTap: onTap))
    }
}

// MARK: - StepContextMenuModifier
/// `ViewModifier` that attaches a step-level right-click context menu to a step row.
private struct StepContextMenuModifier: ViewModifier {
    /// The step this menu acts on.
    let step: GitHubStep
    /// Called when the user selects "View Log" from the context menu.
    let onTap: () -> Void

    /// Wraps `content` with step-level context menu actions (copy name, view log).
    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                copyToPasteboard(step.name)
            } label: { Label("Copy Step Name", systemImage: "doc.on.doc") }
            Button(action: onTap) {
                Label("View Log", systemImage: "text.alignleft")
            }
        }
    }
}
