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

    // DEBUG: call counter so every GR event is uniquely numbered per row.
    @State private var geoCallCount = 0

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
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        geoCallCount += 1
                        let n = geoCallCount
                        log("【ActionRowView.geo[\(n)]】id=\(group.id) onAppear size=(\(geo.size.width),\(geo.size.height)) expandState=\(String(describing: expandState)) tick=\(tick)", category: .general)
                    }
                    .onChange(of: geo.size) { old, new in
                        geoCallCount += 1
                        let n = geoCallCount
                        log("【ActionRowView.geo[\(n)]】id=\(group.id) onChange (\(old.width),\(old.height)) → (\(new.width),\(new.height)) expandState=\(String(describing: expandState)) tick=\(tick)  ← ROW SIZE CHANGED", category: .general)
                    }
            }
        )
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
        .onAppear {
            log("【ActionRowView】id=\(group.id) onAppear rowStatus=\(rowStatus)", category: .general)
            applyInitialExpandState()
        }
        .onDisappear {
            log("【ActionRowView】id=\(group.id) onDisappear", category: .general)
        }
        .onChange(of: expandState) { old, new in
            log("【ActionRowView.expandState】id=\(group.id) \(String(describing: old)) → \(String(describing: new))", category: .general)
        }
        .onChange(of: rowStatus) { old, newStatus in
            log("【ActionRowView.rowStatus】id=\(group.id) \(old) → \(newStatus)", category: .general)
            handleStatusChange(newStatus)
        }
        .onChange(of: group) { old, new in
            log("【ActionRowView.group】id=\(group.id) group mutated — title: '\(old.title)' → '\(new.title)' status: \(old.groupStatus) → \(new.groupStatus) jobCount: \(old.jobs.count) → \(new.jobs.count)", category: .general)
        }
        .onChange(of: tick) { old, new in
            log("【ActionRowView.tick】id=\(group.id) tick \(old) → \(new)", category: .general)
        }
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
        let initial: Bool? = (status == .inProgress) ? false : nil
        log("【ActionRowView】id=\(group.id) applyInitialExpandState status=\(status) → expandState=\(String(describing: initial))", category: .general)
        expandState = initial
    }

    /// Animates expand state transitions when the row status changes.
    private func handleStatusChange(_ newStatus: RBStatus) {
        let animation: Animation = .easeInOut(duration: 0.15)
        if newStatus == .inProgress && expandState == nil {
            log("【ActionRowView】id=\(group.id) handleStatusChange: → inProgress, animating expandState nil → false", category: .general)
            withAnimation(animation) { expandState = false }
        }
        if previousStatus == .inProgress && (newStatus == .success || newStatus == .failed) {
            log("【ActionRowView】id=\(group.id) handleStatusChange: inProgress → \(newStatus), animating expandState → nil", category: .general)
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
            case .failure, .timedOut, .actionRequired, .startupFailure: return .failed
            case .cancelled, .skipped, .neutral, .stale, .unknown, nil: return .unknown
            }
        }
    }

    /// Main body of the action row.
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
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        log("【ActionRowView.rowContent.geo】id=\(group.id) onAppear size=(\(geo.size.width),\(geo.size.height))", category: .general)
                    }
                    .onChange(of: geo.size) { old, new in
                        log("【ActionRowView.rowContent.geo】id=\(group.id) onChange (\(old.width),\(old.height)) → (\(new.width),\(new.height))  ← ROW CONTENT WIDTH CHANGED", category: .general)
                    }
            }
        )
    }

    /// Trailing meta: time-ago · steps/total · elapsed · statusBadge.
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
            guard !jobs.isEmpty else {
                log("【RowTapModifier】tap ignored — no jobs", category: .general)
                return
            }
            let before = expandState
            withAnimation(.easeInOut(duration: 0.15)) {
                if expandState == true {
                    expandState = (rowStatus == .inProgress) ? false : nil
                } else {
                    expandState = true
                }
            }
            log("【RowTapModifier】tapped expandState \(String(describing: before)) → \(String(describing: expandState))", category: .general)
        }
    }
}
