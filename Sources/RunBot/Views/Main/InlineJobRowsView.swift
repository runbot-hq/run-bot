// InlineJobRowsView.swift
// RunBot
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - Set toggle helper
/// Set mutation helpers used internally by `InlineJobRowsView`.
///
/// `Set` has no built-in `toggle(_:)` — this extension provides the SwiftUI
/// state-mutation pattern used by `expandedJobIDs` in `InlineJobRowsView`.
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
    /// Extends the connector into surrounding row spacing so adjacent segments meet.
    /// Defaults to zero; job-header call sites pass 2 to bridge card padding and stack spacing.
    var verticalOverlap: CGFloat = 0
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
        .padding(.vertical, -verticalOverlap)
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

/// Compact determinate progress bar shown inside a running job row.
///
/// The fill width reports actual progress. A low-contrast sheen travels across
/// the complete bar to communicate ongoing activity without changing the
/// reported progress value.
private struct JobInlineProgress: View {
    /// Completion fraction in the range `0...1`.
    let progress: Double

    /// Disables the continuous sheen when requested by the user.
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// Horizontal sheen position as a fraction of the complete bar width.
    ///
    /// Begins outside the leading edge and finishes outside the trailing edge
    /// so the repeating reset is invisible.
    @State private var sheenPhase: CGFloat = -0.34

    /// Progress clamped to the supported range.
    private var normalizedProgress: CGFloat {
        CGFloat(max(0, min(1, progress)))
    }

    /// Lays out the track, fill, and optional sheen inside a clipped capsule.
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                track
                progressFill(width: width)

                if !reduceMotion {
                    travelingSheen(width: width)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
    }

    /// Static unfinished portion of the progress bar.
    private var track: some View {
        Capsule()
            .fill(Color.rbTextTertiary.opacity(0.22))
            .frame(height: 3)
    }

    /// Static determinate progress fill.
    private func progressFill(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.rbBlue)
            .frame(
                width: max(3, width * normalizedProgress),
                height: 3
            )
    }

    /// Low-contrast highlight moving across the complete progress-bar track.
    private func travelingSheen(width: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0), location: 0),
                .init(color: Color.white.opacity(0.10), location: 0.25),
                .init(color: Color.white.opacity(0.34), location: 0.50),
                .init(color: Color.white.opacity(0.10), location: 0.75),
                .init(color: Color.white.opacity(0), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width * 0.34, height: 3)
        .offset(x: width * sheenPhase)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { startSheen() }
    }

    /// Starts one complete leading-to-trailing traversal every 2.1 seconds.
    private func startSheen() {
        sheenPhase = -0.34

        withAnimation(
            .linear(duration: 2.1)
                .repeatForever(autoreverses: false)
        ) {
            sheenPhase = 1
        }
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
    // indent = 7: centers the vertical bar under the 10 pt job status donut.
    //
    // Geometry relative to the job card:
    // - Job-card horizontal padding: RBSpacing.sm = 6 pt
    // - Half of the job donut: 10 / 2 = 5 pt
    // - Step-container horizontal inset: RBSpacing.xs = 4 pt
    // - Connector indent: 6 + 5 - 4 = 7 pt
    /// Horizontal indent aligning the step tree bar under the job status dot.
    private let dotIndent: CGFloat = 7
    /// Lays out the tree connector and step content side by side.
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TreeLineLeader(isLast: isLast, indent: dotIndent)
                .frame(maxHeight: .infinity)
            stepContent
        }
    }
    /// The step row content: icon, name, step number, elapsed and a chevron tap target.
    ///
    /// Column order:
    /// status icon · step title · step number · Spacer · duration · chevron
    ///
    /// `step.number` is the 1-based index assigned by the GitHub API and is the
    /// canonical source of truth. Main uses compact `#N` notation; StepLog retains
    /// its existing `step #N` badge and is not changed here. The number is fixed-size
    /// at layout priority 2 so it remains visible even when the title truncates.
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
                Text("#\(step.number)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.rbTextTertiary)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .accessibilityLabel("Step \(step.number)")
                Spacer(minLength: 4)
                // ELAPSED GUARD — two conditions, both required:
                //
                // 1. status != "queued"
                //    Steps that have not yet been dispatched carry status "queued".
                //    They have no startedAt timestamp, so there is genuinely no
                //    elapsed time to display. Steps blocked by a concurrency group
                //    also arrive here before transitioning to "in_progress".
                //    NOTE: status is a raw String from the GitHub API — there is
                //    intentionally no typed enum used here because the API can
                //    introduce new status values (e.g. "waiting", "pending") that
                //    we want to fall through to the elapsed display rather than
                //    silently suppress. Only "queued" is excluded.
                //
                // 2. step.startDate != nil
                //    `GitHubStep` has no `createdAt` field in the GitHub Actions
                //    API response, so unlike `GitHubJob` there is no createdDate
                //    fallback. `formatElapsed(start:end:isCompleted:now:)` returns
                //    the sentinel "00:00" (not "") when start is nil — displaying
                //    that would be misleading for a step that has not started.
                //    This guard ensures we only render once real timing data exists.
                //
                // DO NOT replace with `!step.elapsed.isEmpty` — formatElapsed
                // NEVER returns ""; it always returns "00:00", "--:--", or mm:ss.
                // An isEmpty check would be a dead condition and would leak
                // sentinel strings into the UI.
                if step.status != "queued", step.startDate != nil {
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
    ///
    /// Uses raw String comparisons because `step.conclusion` is a raw `String?`
    /// from the GitHub API — not a typed enum. `stepConclusion` (the typed
    /// accessor on `GitHubStep`) is available but not used here to keep the
    /// switch exhaustive over the raw values without an extra conversion.
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
///
/// NOTE: This struct must remain free of `@State`. `InlineJobRowsView` replaces
/// each card's SwiftUI identity on every timer tick (`.id("\(job.id)-\(tick)")`) to
/// drive live elapsed-time re-renders. Any `@State` added here would silently reset
/// on every tick. If card-level state is needed in the future, hoist it to
/// `InlineJobRowsView` or adopt a different refresh strategy before adding it.
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
        // Two conditions are intentional — both are needed, not redundant:
        // - conclusion != nil: step finished with a result (success/failure/skipped/…).
        // - status == "completed": defensive fallback for API responses where
        //   conclusion is temporarily absent but the step is no longer running.
        // Using a union (||) rather than conclusion-only avoids an off-by-one in
        // the steps/total counter when the API populates fields out of order.
        job.steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
    }
    /// Renders the job tree connector, card header, and optional expanded step list.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // isLast && !isExpanded — intentional compound condition:
            // When this is the last job AND it is expanded, we pass isLast: false
            // so TreeLineLeader draws a full-height straight bar rather than the
            // terminal elbow. This keeps the vertical connector running through the
            // expanded step list, preserving the tree hierarchy visually.
            // If isExpanded were not factored in, the elbow would render at the job
            // header row while steps are still shown below it, breaking the geometry.
            TreeLineLeader(isLast: isLast && !isExpanded, indent: dotIndent, verticalOverlap: 2)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                jobHeader
                if isExpanded { stepsContainer }
            }
            .background {
                RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                    .strokeBorder(Color.rbJobRowStroke, lineWidth: 0.5)
            }
        }
        .padding(.vertical, 1)
        .jobContextMenu(job: job, group: group)
    }
    /// Job header row.
    ///
    /// Column order:
    /// graph-dot · runner-type-icon · job-name · job-id · [progress bar] · elapsed · steps/total
    ///
    /// The elapsed duration appears before step progress so the rightmost value is always
    /// the step fraction. A centered-dot separator is shown between the two when both are
    /// present; missing values do not leave a dangling separator.
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
                if job.jobStatus == .inProgress,
                   let fraction = job.progressFraction,
                   fraction > 0,
                   fraction < 1 {
                    JobInlineProgress(progress: fraction)
                        .frame(width: 120)
                }
                // ELAPSED GUARD — mirrors GitHubJob.elapsed(now:)'s own start logic:
                // `formatElapsed(start: startDate ?? createdDate, ...)`. We show the
                // label iff at least one of those dates is non-nil, which means the
                // model itself has real timing data to display.
                //
                // WHY NOT `job.startDate != nil` alone:
                //   startDate parses `startedAt` via ISO8601DateFormatter. If the API
                //   returns a date string in a format the formatter can't parse, startDate
                //   is nil even though createdDate may still be valid. That was the
                //   original bug (#2129) — the label was silently dropped.
                //
                // WHY NOT `!job.elapsed.isEmpty`:
                //   `formatElapsed` NEVER returns "". It always returns "00:00",
                //   "--:--", or a mm:ss string. An isEmpty check is a dead condition
                //   and would leak "00:00" onto queued jobs that have no dates at all.
                //
                // WHY NOT guard on `job.jobStatus`:
                //   Status is unreliable as a timing proxy — a completed job can still
                //   lack a startedAt if the API response was partial. Date presence is
                //   the authoritative signal.
                let showsElapsed = job.startDate != nil || job.createdDate != nil
                let showsStepProgress = totalSteps > 0

                HStack(spacing: RBSpacing.xs) {
                    if showsElapsed {
                        Text(job.elapsed)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.rbTextTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("Job duration")
                    }

                    if showsElapsed, showsStepProgress {
                        jobMetadataSeparator
                    }

                    if showsStepProgress {
                        Text("\(completedSteps)/\(totalSteps)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.rbTextTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, RBSpacing.sm)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    /// Decorative centered-dot separator between job duration and step progress.
    private var jobMetadataSeparator: some View {
        Text("·")
            .font(.caption2)
            .foregroundStyle(Color.rbTextTertiary)
            .accessibilityHidden(true)
    }

    /// Vertically stacked step rows shown when the job card is expanded.
    private var stepsContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `GitHubStep` has no `id` property — `number` is the 1-based step index
            // assigned by the GitHub API and is stable within a job run. It is the
            // correct ForEach identity key. Do not use array index as the id — steps
            // can be reordered by the API between refreshes.
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
    /// A stable snapshot of `tick` captured at view evaluation time.
    ///
    /// Embedding `tick` in each `JobRowCard`'s SwiftUI identity string forces
    /// SwiftUI to re-evaluate the card on every timer tick, which drives the
    /// live elapsed-time counter. Without this, SwiftUI's diffing would consider
    /// stable job IDs unchanged and skip re-rendering elapsed labels.
    /// Do not remove the tick component from the `.id(...)` modifier.
    ///
    /// NOTE: replacing the SwiftUI identity on every tick means any card-level
    /// `@State` would reset each tick. This is intentional and safe today because
    /// `JobRowCard` carries no `@State` of its own — `expandedJobIDs` lives here
    /// in the parent and is therefore preserved across ticks. If card-level `@State`
    /// is added in the future, move that state up to this view or use a different
    /// refresh strategy.
    private var tickSnapshot: Int { tick }
    /// Renders the list of job cards, gated on the panel being open.
    var body: some View {
        Group {
            if panelVisibilityState.isOpen {
                // `jobStatus` is the typed accessor on `ActiveJob`; `raw.status` is a
                // raw String. fullExpand shows all jobs; default shows only running ones.
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
                        // job.id alone would be stable enough for diffing, but tick
                        // must be part of the identity to force re-render on each
                        // timer tick for live elapsed updates. See `tickSnapshot`.
                        .id("\(job.id)-\(tickSnapshot)")
                    }
                }
                // .fixedSize(horizontal: false, vertical: true) is LOAD-BEARING (#2264).
                // Forces the VStack to report its full natural height to the parent
                // ScrollView in PanelMainView so the popover grows when a row expands.
                // Without this, the ScrollView under-reports content height on expansion
                // and the popover does not resize to accommodate the new job cards.
                // ❌ NEVER remove this modifier.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, RBSpacing.md)
                .padding(.trailing, RBSpacing.xs)
                .padding(.bottom, RBSpacing.xs)
            }
        }
        // Fix #2349/#2354: when the active row collapses back to partial expand
        // (fullExpand transitions false→true→false), InlineJobRowsView stays mounted
        // because expandState is set to `false` rather than `nil` for .inProgress rows.
        // This means expandedJobIDs persists and steps appear expanded after collapse.
        // Clearing expandedJobIDs here resets all job cards to their default closed
        // state, matching the expected "active row state" on collapse.
        .onChange(of: fullExpand) { _, newValue in
            if !newValue { expandedJobIDs.removeAll() }
        }
    }
}
