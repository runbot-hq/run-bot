// InlineJobRowsView.swift
// RunBot
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - Set toggle helper
/// Set mutation helpers used internally by `InlineJobRowsView`.
private extension Set {
    /// Removes `member` if present; inserts it if absent.
    mutating func toggle(_ member: Element) {
        if contains(member) { remove(member) } else { insert(member) }
    }
}

// MARK: - TreeLineLeader
/// Vertical tree-connector line drawn to the left of a job or step row.
/// Renders a straight bar with an elbow arrow at the bottom for the last item.
private struct TreeLineLeader: View {
    /// Whether this is the last item in the list (draws elbow instead of continuing bar).
    let isLast: Bool
    /// Horizontal indent from the left edge to the vertical bar centre.
    var indent: CGFloat = 0
    /// Colour of the tree connector lines.
    private let lineColor = Color.secondary.opacity(0.3)
    /// Width of the vertical bar stroke.
    private let barWidth: CGFloat = 1
    /// Horizontal reach of the elbow arm.
    private let elbowWidth: CGFloat = 10
    /// Size of the arrowhead at the elbow tip.
    private let arrowSize: CGFloat = 4
    /// Draws the vertical bar and elbow arrow using a `Canvas`.
    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let barX = indent
            var vertPath = Path()
            vertPath.move(to: CGPoint(x: barX, y: 0))
            vertPath.addLine(to: CGPoint(x: barX, y: isLast ? midY : size.height))
            ctx.stroke(vertPath, with: .color(lineColor), lineWidth: barWidth)
            let arrowTip = CGPoint(x: barX + elbowWidth, y: midY)
            var elbowPath = Path()
            elbowPath.move(to: CGPoint(x: barX, y: midY))
            elbowPath.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY))
            ctx.stroke(elbowPath, with: .color(lineColor), lineWidth: barWidth)
            var arrow = Path()
            arrow.move(to: arrowTip)
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY - arrowSize / 2))
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY + arrowSize / 2))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(lineColor))
        }
        .frame(width: indent + elbowWidth + 2)
    }
}

// MARK: - JobRunnerTypeIcon
/// Small SF Symbol indicating whether a job runs on a self-hosted (local) or
/// GitHub-hosted (cloud) runner. Resolved via `ActiveJob.isLocalRunner`.
private struct JobRunnerTypeIcon: View {
    /// Pre-resolved local-runner flag from `ActiveJob.isLocalRunner`.
    let isLocalRunner: Bool?
    /// Renders a desktop or cloud SF Symbol based on the runner type.
    var body: some View {
        Image(systemName: isLocalRunner == true ? "desktopcomputer" : "cloud")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }
}

// MARK: - JobInlineProgress
/// Compact progress bar shown inside a job row while the job is running.
/// Fills proportionally to `fractionComplete`; hidden when no progress is available.
private struct JobInlineProgress: View {
    /// Completion fraction in the range 0.0–1.0.
    let progress: Double
    /// Renders a capsule progress bar proportional to `progress`.
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rbTextTertiary.opacity(0.22)).frame(height: 3)
                Capsule()
                    .fill(Color.rbBlue)
                    .frame(width: max(3, geo.size.width * CGFloat(progress)), height: 3)
            }
        }
        .frame(height: 3)
    }
}

// MARK: - StepRowView
/// Single step row inside an expanded job card.
/// Shows the step icon, name, and elapsed time aligned with the tree connector.
private struct StepRowView: View {
    /// The step to display.
    let step: GitHubStep
    /// Whether this is the last step in the list.
    let isLast: Bool
    /// Called when the user taps the step row.
    let onTap: () -> Void
    // indent = 9: centers the vertical bar under the job DonutStatusView dot.
    // Geometry: InlineJobRowsView.padding(.leading:12) + jobLeaderFrame(19) +
    // stepsContainer.padding(.horizontal:4) = 35 from InlineJobRowsView edge.
    // Job dot center = 12 + 19 + 8(card hpad) + 5(half dot10) = 44.
    // Step leader indent = 44 - 35 = 9.
    /// Horizontal indent aligning the step tree bar under the job status dot.
    private let dotIndent: CGFloat = 9
    /// Lays out the tree connector and step content side by side.
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TreeLineLeader(isLast: isLast, indent: dotIndent)
                .frame(maxHeight: .infinity)
            stepContent
        }
    }
    /// The step row content: icon, name, elapsed and a chevron tap target.
    private var stepContent: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(step.conclusionIcon)
                    .font(.system(size: 10))
                    .foregroundColor(iconColor)
                    .fixedSize()
                Text(step.name)
                    .font(RBFont.mono)
                    .foregroundColor(Color.rbTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                // GitHubStep.status is a raw String; "in_progress" means the step is running.
                if step.status == "in_progress" || step.conclusion != nil {
                    Text(step.elapsed)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextTertiary)
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.rbTextTertiary)
            }
            .padding(.horizontal, RBSpacing.sm)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .stepContextMenu(step: step, onTap: onTap)
    }
    /// Foreground colour for the step conclusion icon.
    private var iconColor: Color {
        switch step.conclusion {
        case "success": return Color.rbSuccess
        case "failure": return Color.rbDanger
        case "skipped", "cancelled": return Color.rbTextTertiary
        default: return step.status == "in_progress" ? Color.rbBlue : Color.rbTextTertiary
        }
    }
}

// MARK: - JobRowCard
/// Expandable card that represents one job within a workflow run.
/// Tapping the header toggles the step list; long-press opens the job in Safari.
private struct JobRowCard: View {
    /// The job this card represents.
    let job: ActiveJob
    /// The resolved display status for this job.
    let status: RBStatus
    /// Whether this is the last job card in the list (controls tree-line elbow).
    let isLast: Bool
    /// The parent workflow action group.
    let group: WorkflowActionGroup
    /// Whether the step list is currently expanded.
    let isExpanded: Bool
    /// Called when the user taps the job header to toggle expansion.
    let onToggle: () -> Void
    /// Called when the user taps a step row inside the expanded card.
    let onStepTap: (GitHubStep) -> Void
    // indent = 7: half of the workflow DonutStatusView dot (size 14).
    // Geometry: card colour bar(4) + clear spacer(12) + half-dot(7) = 23 from card edge.
    // InlineJobRowsView padding(.leading:12) + colour bar(4) = 16 from card edge.
    // So leader barX = 23 - 16 = 7 centers under the workflow dot.
    /// Horizontal indent aligning the job tree bar under the workflow status dot.
    private let dotIndent: CGFloat = 7
    /// Total number of steps in this job.
    private var totalSteps: Int { job.steps.count }
    /// Number of completed steps in this job.
    private var completedSteps: Int {
        // GitHubStep.conclusion is a raw String? — non-nil means the step has finished.
        // GitHubStep.status is a raw String — "completed" means the step has finished.
        job.steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
    }
    /// Renders the job tree connector, card header, and optional expanded step list.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TreeLineLeader(isLast: isLast && !isExpanded, indent: dotIndent)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                jobHeader
                if isExpanded { stepsContainer }
            }
            .glassCard(cornerRadius: RBRadius.small)
        }
        .padding(.vertical, 1)
        .jobContextMenu(job: job, group: group)
    }
    /// Job header row.
    ///
    /// Column order (#1037):
    /// graph-dot · runner-type-icon · job-name · job-id · [progress bar] · steps/total · elapsed
    private var jobHeader: some View {
        Button {
            guard totalSteps > 0 else { return }
            withAnimation(.easeInOut(duration: 0.15)) { onToggle() }
        } label: {
            HStack(spacing: 6) {
                DonutStatusView(status: status, progress: job.progressFraction ?? 0, size: 10)
                JobRunnerTypeIcon(isLocalRunner: job.isLocalRunner)
                Text(job.name)
                    .font(RBFont.mono)
                    .foregroundColor(job.isDimmed ? Color.rbTextTertiary : Color.rbTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text("#\(job.id)")
                    .font(RBFont.mono)
                    .foregroundColor(Color.rbTextTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                if job.jobStatus == .inProgress {
                    JobInlineProgress(progress: job.progressFraction ?? 0)
                        .frame(width: 120)
                }
                if totalSteps > 0 {
                    Text("\(completedSteps)/\(totalSteps)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextTertiary)
                        .fixedSize()
                }
                if job.startDate != nil {
                    Text(job.elapsed)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextTertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, RBSpacing.sm)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    /// Vertically stacked step rows shown when the job card is expanded.
    private var stepsContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(job.steps.enumerated()), id: \.element.number) { index, step in
                StepRowView(
                    step: step,
                    isLast: index == job.steps.count - 1,
                    onTap: { onStepTap(step) }
                )
            }
        }
        .padding(.horizontal, RBSpacing.xs)
        .padding(.bottom, RBSpacing.xs)
    }
}

// MARK: - InlineJobRowsView
/// Vertically stacked list of `JobRowCard` views for a single workflow run.
/// Rendered inside the action row when the run is expanded.
struct InlineJobRowsView: View {
    /// The workflow action group whose jobs are displayed.
    let group: WorkflowActionGroup
    /// Timer tick driving live elapsed-time refresh.
    let tick: Int
    /// When `true`, all jobs are shown; when `false`, only in-progress jobs are shown.
    var fullExpand: Bool = false
    // Default no-op handler; callers that need step navigation override this.
    /// Called when the user taps a step row. Defaults to a no-op.
    var onStepTap: (ActiveJob, GitHubStep) -> Void = { _, _ in
        // Intentionally empty: default is a no-op.
        // Callers that require navigation provide a real implementation.
    }
    /// Tracks whether the panel popover is currently visible.
    @Environment(PanelVisibilityState.self) private var panelVisibilityState: PanelVisibilityState
    /// The set of job IDs whose step lists are currently expanded.
    @State private var expandedJobIDs: Set<Int> = []
    /// A stable snapshot of `tick` captured at view evaluation time, used to key job row identity.
    private var tickSnapshot: Int { tick }
    /// Renders the list of job cards, gated on the panel being open.
    var body: some View {
        Group {
            if panelVisibilityState.isOpen {
                // jobStatus is the typed accessor on ActiveJob; raw job.status is a String.
                let jobs = fullExpand ? group.jobs : group.jobs.filter { $0.jobStatus == .inProgress }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        JobRowCard(
                            job: job,
                            status: job.rbStatus,
                            isLast: index == jobs.count - 1,
                            group: group,
                            isExpanded: expandedJobIDs.contains(job.id),
                            onToggle: { expandedJobIDs.toggle(job.id) },
                            onStepTap: { step in onStepTap(job, step) }
                        )
                        .id("\(job.id)-\(tickSnapshot)")
                    }
                }
                .padding(.leading, RBSpacing.md)
                .padding(.trailing, RBSpacing.xs)
                .padding(.bottom, RBSpacing.xs)
            }
        }
    }
}
