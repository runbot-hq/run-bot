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
/// expand animations (#957). The statusBadge GlassEffectContainer in metaTrailing
/// is intentionally scoped to just the badge, not the row.
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

    /// Renders the row using the appropriate glass card background for the current OS.
    var body: some View {
        if #available(macOS 26, *) {
            rowContainer {
                Color.clear.glassCard(cornerRadius: RBRadius.card)
                statusAccentBar
            }
        } else {
            rowContainer {
                glassCardBackground
                statusAccentBar
            }
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
        // affects panel width reported to MBKPopoverController.
        // Remove together with LogCategory.panel when closing #2275.
        // .onChange(of: expandState) { old, new in
        //     log("【ActionRowView.expandState】id=\(group.id) \(String(describing: old)) → \(String(describing: new))", category: .general)
        // }
        .onChange(of: rowStatus) { _, newStatus in handleStatusChange(newStatus) }
    }

    /// Left-edge accent bar whose colour reflects the current row status.
    @ViewBuilder private var statusAccentBar: some View {
        Rectangle()
            .fill(rowStatus.color)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pre-macOS-26 glass card background used as the ZStack layer inside `rowContainer`.
    @ViewBuilder private var glassCardBackground: some View {
        Color.clear.glassCard(cornerRadius: RBRadius.card)
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
    /// Column order (#984):
    /// graph-dot · local-remote-icon · sha · repo-name · commit-title · branch-text · Spacer
    /// · time-ago · steps/total · elapsed(mm:ss) · statusBadge
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
            DonutStatusView(status: rowStatus, progress: group.progressFraction ?? 0, size: 14)
            RunnerTypeIcon(isLocal: group.isLocalGroup ?? false)
            Text(group.label)
                .font(RBFont.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.repoShortName)
                .font(RBFont.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: RBMetrics.actionRowTitleMaxWidth, alignment: .leading)
                .help(group.title)
                .layoutPriority(1)
            if let branch = group.headBranch {
                Text(branch)
                    .font(RBFont.mono)
                    .foregroundColor(.secondary)
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
        if let start = group.firstJobStartedAt ?? group.createdAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(RBFont.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .id(group.groupStatus == .inProgress ? "\(tickSnapshot)" : group.id)
        }
        if !group.jobs.isEmpty {
            Text(group.jobProgress)
                .font(RBFont.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        let showElapsed = group.groupStatus != .loading || group.firstJobStartedAt != nil
        if showElapsed {
            Text(group.elapsed)
                .font(RBFont.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .id(group.groupStatus == .inProgress ? "\(tickSnapshot)" : group.id)
        }
        if #available(macOS 26, *) {
            GlassEffectContainer { statusBadge }
        } else {
            statusBadge
        }
    }

    /// Badge view produced from the group's current status and conclusion.
    /// Keep conclusion groupings in sync with `rowStatus` above.
    @ViewBuilder private var statusBadge: some View {
        switch group.groupStatus {
        case .inProgress: StatusBadge(status: .inProgress, text: "IN PROGRESS")
        case .loading:    StatusBadge(status: .queued, text: "LOADING")
        case .queued:     StatusBadge(status: .queued, text: "QUEUED")
        case .completed:
            switch group.conclusion {
            case .success: StatusBadge(status: .success, text: "SUCCESS")
            case .failure, .timedOut, .actionRequired, .startupFailure:
                StatusBadge(status: .failed, text: "FAILED")
            case .cancelled: StatusBadge(status: .unknown, text: "CANCELLED")
            case .skipped: StatusBadge(status: .unknown, text: "SKIPPED")
            case .neutral, .stale, .unknown, nil: StatusBadge(status: .unknown, text: "DONE")
            }
        }
    }
}

// MARK: - RowTapModifier
/// Animation is always `.easeInOut(duration: 0.15)` — do NOT add `.bouncy` (#957).
private struct RowTapModifier: ViewModifier {
    let jobs: [ActiveJob]
    @Binding var expandState: Bool?
    let rowStatus: RBStatus

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
