// ActionRowView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - ActionRowView
/// Row representing one GitHub Actions workflow run.
///
/// ⚠️ Do NOT add GlassEffectContainer, .glassEffectID, .bouncy, or
/// .glassEffectTransition to the row or rowContainer — they cause staggered/slow
/// expand animations (#957). The workflowStatusDonut GlassEffectContainer is
/// intentionally scoped to just the leading donut, not the row.
struct ActionRowView: View {
    /// The workflow action group this row represents.
    let group: WorkflowActionGroup
    /// Poll tick counter used to force time-ago label refreshes.
    let tick: Int
    /// Called when the user taps a step inside the expanded inline job rows.
    let onStepTap: (ActiveJob, GitHubStep) -> Void
    /// Drives the inline expand/collapse state: `nil` = collapsed, `false` = partially expanded, `true` = fully expanded.
    @State private var expandState: Bool?
    /// Tracks the previous row status to detect in-progress → done transitions.
    @State private var previousStatus: RBStatus?

    /// Workflow card: adaptive foreground glass background with status accent bar,
    /// wrapping row content and any inline job/step expansion.
    var body: some View {
        rowContainer {
            glassCardBackground
            statusAccentBar
        }
    }

    /// Wraps `rowContent` (and optionally `InlineJobRowsView`) in a card-shaped container
    /// with the supplied glass background.
    @ViewBuilder
    private func rowContainer<Background: View>(@ViewBuilder background: () -> Background) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: RBSpacing.md)
                rowContent
            }
            if let fullExpand = expandState {
                InlineJobRowsView(group: group, tick: tick, fullExpand: fullExpand, onStepTap: onStepTap)
            }
        }
        .frame(maxWidth: .infinity)
        // ⚠️ DO NOT REMOVE — sizing diagnostic for ActionRowView width/height investigation.
        // Kept commented out intentionally. Re-enable when testing sizing optimisations
        // to observe how row expand/collapse affects the size MBK reports for the panel.
        // Remove together with LogCategory.panel when closing #2275.
        // .background(
        //     GeometryReader { geo in
        //         Color.clear
        //             .onAppear {
        //                 log("【ActionRowView.geo】id=\(group.id) onAppear size=\(geo.size)", category: .general)
        //             }
        //             .onChange(of: geo.size) { old, new in
        //                 log("【ActionRowView.geo】id=\(group.id) onChange \(old) → \(new)", category: .general)
        //             }
        //     }
        // )
        .background {
            ZStack { background() }
                .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .workflowContextMenu(group: group)
        .modifier(RowTapModifier(jobs: group.jobs, expandState: $expandState, rowStatus: rowStatus))
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xxs)
        .onAppear { applyInitialExpandState() }
        // ⚠️ DO NOT REMOVE — expandState change logger for sizing investigation.
        // Kept commented out intentionally. Re-enable when testing how row expand/collapse
        // affects panel width reported to MBKPanelController.
        // Remove together with LogCategory.panel when closing #2275.
        // .onChange(of: expandState) { old, new in
        //     log("【ActionRowView.expandState】id=\(group.id) \(String(describing: old)) → \(String(describing: new))", category: .general)
        // }
        .onChange(of: rowStatus) { _, newStatus in handleStatusChange(newStatus) }
    }

    /// Left-edge glass accent strip whose colour reflects the current row status.
    /// Tint and glass are applied while the rendered surface is exactly 6 pt wide;
    /// the final infinite-width frame only positions that strip at the leading edge.
    @ViewBuilder private var statusAccentBar: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: RBRadius.card,
            bottomLeadingRadius: RBRadius.card,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .background(rowStatus.color.opacity(0.30), in: shape)
            .glassEffect(.regular, in: shape)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Adaptive foreground glass card background for the workflow card.
    /// Uses `rbGlassNeutralBackground` (black 0.15 light / white 0.10 dark) beneath regular
    /// Liquid Glass — opposite the root panel tint, establishing foreground/background
    /// hierarchy in both appearances.
    @ViewBuilder private var glassCardBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: RBRadius.card,
            style: .continuous
        )
        Color.clear
            .background(
                Color.rbGlassNeutralBackground,
                in: shape
            )
            .glassEffect(.regular, in: shape)
    }

    /// Sets the initial expand state based on the row's status at appear time.
    private func applyInitialExpandState() {
        let status = rowStatus
        previousStatus = status
        expandState = (status == .inProgress) ? false : nil
    }

    /// Animates expand state transitions when the row status changes.
    private func handleStatusChange(_ newStatus: RBStatus) {
        let animation: Animation = .easeInOut(duration: 0.15)
        if newStatus == .inProgress && expandState == nil {
            withAnimation(animation) { expandState = false }
        }
        if previousStatus == .inProgress && (newStatus == .success || newStatus == .failed) {
            withAnimation(animation) { expandState = nil }
        }
        previousStatus = newStatus
    }

    /// Derives the canonical `RBStatus` from the group's status and conclusion.
    private var rowStatus: RBStatus {
        switch group.groupStatus {
        case .inProgress: return .inProgress
        case .loading:    return .queued
        case .queued:     return .queued
        case .completed:
            switch group.conclusion {
            case .success: return .success
            // All failure-class subtypes map to the red (.failed) tier.
            // timedOut / actionRequired / startupFailure are intentionally grouped here
            // alongside .failure — statusBadge uses the same grouping.
            case .failure, .timedOut, .actionRequired, .startupFailure: return .failed
            // Accent-bar colour is undifferentiated for these — all map to the grey
            // (.unknown) tier. See statusBadge below for per-case text differentiation.
            case .cancelled, .skipped, .neutral, .stale, .unknown, nil: return .unknown
            }
        }
    }

    /// Main body of the action row.
    ///
    /// Column order (#984, updated #2598):
    /// workflowStatusDonut · repo-name · commit-title · branch-text · Spacer
    /// · time-ago · elapsed(mm:ss) · steps/total
    ///
    /// - sha: `group.label` (7-char sha or PR#), muted mono
    /// - repo-name: `group.repoShortName` stripped from owner/repo
    /// - branch: plain `Text` capped at RBMetrics.actionRowBranchMaxWidth, hidden when nil
    ///
    /// TITLE MODIFIER ORDER — do not reorder without reading this:
    /// 1. `.lineLimit(1)` + `.truncationMode(.tail)` configure truncation behaviour on the Text.
    /// 2. `.frame(maxWidth: RBMetrics.actionRowTitleMaxWidth)` caps the width, triggering the
    ///    ellipsis configured above. Must come AFTER truncation config, not before.
    /// 3. `.help(group.title)` attaches the tooltip to the already-frame-capped view — correct
    ///    scope. Always fires even when the title fits within the cap; this is intentional.
    ///    Conditionally suppressing it would require measuring rendered text width, which is
    ///    non-trivial in SwiftUI and not worth the complexity. macOS .help() on short labels
    ///    is a known accepted pattern across the ecosystem.
    /// 4. `.layoutPriority(1)` applies to the framed view — this is correct and intentional.
    ///    It means the title frame wins space over headBranch (priority 0) during layout
    ///    negotiation, but is still capped at actionRowTitleMaxWidth. Do NOT move
    ///    .layoutPriority above .frame: the priority must apply to the constrained container,
    ///    not the raw unbounded Text.
    private var rowContent: some View {
        let tickSnapshot = tick
        return HStack(spacing: 6) {
            workflowStatusDonut
            Text(group.repoShortName)
                .font(RBFont.mono)
                .foregroundColor(Color.rbTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1)                                                          // step 1: configure truncation
                .truncationMode(.tail)                                                 // step 1: configure truncation
                .frame(maxWidth: RBMetrics.actionRowTitleMaxWidth, alignment: .leading) // step 2: cap width, triggers ellipsis
                .help(group.title)                                                     // step 3: tooltip on capped view (always-on by design)
                .layoutPriority(1)                                                     // step 4: priority on the frame, not raw Text
            // Branch — plain text, hidden when nil (#1194)
            if let branch = group.headBranch {
                Text(branch)
                    .font(RBFont.mono)
                    .foregroundColor(Color.rbTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: RBMetrics.actionRowBranchMaxWidth, alignment: .leading)
                    .layoutPriority(0)
            }
            Spacer()
            metaTrailing(tick: tickSnapshot)
        }
        .padding(.trailing, RBSpacing.xs)
        .padding(.vertical, 4)
    }

    /// Trailing meta: time-ago · steps/total · elapsed · statusBadge.
    ///
    /// - time-ago: derived from `firstJobStartedAt ?? createdAt` so it is visible
    ///   even in queued/loading states before jobs have populated.
    /// - elapsed: shown for ALL statuses — completed rows show their final duration,
    ///   active rows show a live ticking value (keyed to `tick`).
    ///
    /// statusBadge is wrapped in its own standalone GlassEffectContainer — scoped to badge only.
    /// ⚠️ Do NOT expand this container to the row or rowContainer (#957).
    @ViewBuilder private func metaTrailing(tick tickSnapshot: Int) -> some View {
        // Use createdAt as fallback so time-ago is visible before firstJobStartedAt populates.
        // If both are nil (e.g. corrupted API response), the label is intentionally omitted — not a bug.
        if let start = group.firstJobStartedAt ?? group.createdAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(RBFont.mono)
                .foregroundColor(Color.rbTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // Gate tick binding to .inProgress only — mirrors the elapsed label below.
                // For non-inProgress rows the start date is static; group.id is a stable
                // sentinel so SwiftUI does not redraw this label on every poll tick.
                .id(group.groupStatus == .inProgress ? "\(tickSnapshot)" : group.id)
        }
        // Show elapsed for all statuses. Completed rows display a static final duration;
        // active rows tick live. Only bind tickSnapshot when in-progress to avoid
        // unnecessary redraws on completed/queued rows.
        //
        // Condition reads: show elapsed UNLESS the row is still in .loading AND no job has
        // started yet. That is the only state where group.elapsed would be a meaningless
        // "time since workflow was created" with no job context.
        // Equivalent form: suppress when (.loading AND firstJobStartedAt == nil).
        //
        // group.elapsed always returns a non-empty string for every state where
        // showElapsed == true: inProgress/queued use firstJobStartedAt ?? createdAt → now,
        // and completed uses firstJobStartedAt → lastJobCompletedAt. No empty-Text risk.
        let showElapsed = group.groupStatus != .loading || group.firstJobStartedAt != nil
        if showElapsed {
            Text(group.elapsed)
                .font(RBFont.mono)
                .foregroundColor(Color.rbTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // Both .id() arms produce String. Collision between "\(tickSnapshot)" and
                // group.id is not possible in practice: group.id is derived from the maximum
                // GitHub run ID (a large integer, e.g. "12893741234"), while tickSnapshot is a
                // small monotonic counter that resets with the app. The value spaces do not
                // overlap. Note: .queued elapsed reflects the value at last poll, not
                // per-second — this is intentional. Per-second ticking on a queued run
                // would be misleading.
                .id(group.groupStatus == .inProgress ? "\(tickSnapshot)" : group.id)
        }
        if !group.jobs.isEmpty {
            Text(group.jobProgress)
                .font(RBFont.mono)
                .foregroundColor(Color.rbTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Glass-wrapped donut for the leading position of the top-level workflow row.
    /// Keeps the existing 14 pt donut unchanged; adds ~3 pt padding and a subtle
    /// status-tinted circular glass surface. Scoped to just the donut — not the row.
    /// Do not apply this wrapper to job- or step-level donuts.
    @ViewBuilder private var workflowStatusDonut: some View {
        let shape = Circle()
        GlassEffectContainer {
            DonutStatusView(
                status: rowStatus,
                progress: group.progressFraction ?? 0,
                size: 14
            )
            .padding(3)
            .background(rowStatus.color.opacity(0.14), in: shape)
            .glassEffect(.regular, in: shape)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workflow status")
        .accessibilityValue(statusAccessibilityText)
    }

    /// Textual description of the current workflow status for accessibility (VoiceOver).
    /// Mirrors the former statusBadge text labels so VoiceOver continuity is preserved.
    private var statusAccessibilityText: String {
        switch group.groupStatus {
        case .inProgress: return "In progress"
        case .loading:    return "Loading"
        case .queued:     return "Queued"
        case .completed:
            switch group.conclusion {
            case .success:                                              return "Success"
            case .failure, .timedOut, .actionRequired, .startupFailure: return "Failed"
            case .cancelled:                                            return "Cancelled"
            case .skipped:                                              return "Skipped"
            case .neutral, .stale, .unknown, nil:                       return "Done"
            }
        }
    }
}

// MARK: - RowTapModifier
/// Animation is always `.easeInOut(duration: 0.15)` — do NOT add `.bouncy` (#957).
private struct RowTapModifier: ViewModifier {
    /// The jobs for this row; tap is a no-op when empty.
    let jobs: [ActiveJob]
    /// Drives the expand/collapse state of the parent row.
    @Binding var expandState: Bool?
    /// Current row status, used to decide the post-collapse state.
    let rowStatus: RBStatus

    /// Attaches the tap gesture that toggles expand state with a 0.15 s ease-in-out animation.
    func body(content: Content) -> some View {
        content.onTapGesture {
            guard !jobs.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if expandState == true {
                    expandState = (rowStatus == .inProgress) ? false : nil
                } else {
                    expandState = true
                }
            }
        }
    }
}
