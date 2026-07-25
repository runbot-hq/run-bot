// PanelLocalRunnerRow.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - RunnerTypeIcon
/// Small icon indicating whether a runner is local (desktop) or cloud-hosted.
/// `internal` (not private) — also used by ActionRowView.swift.
struct RunnerTypeIcon: View {
    /// `true` for a self-hosted local runner, `false` for a cloud runner.
    let isLocal: Bool

    /// Renders the appropriate SF Symbol for the runner type.
    var body: some View {
        Image(systemName: isLocal ? "desktopcomputer" : "cloud")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }
}

// MARK: - RunnerMetricsBadge
/// CPU + MEM badge for runner rows.
///
/// Always rendered (shows 0% until real metrics arrive) to prevent layout jump.
///
/// Glass architecture — identical to StatusBadge in ActionRowView.metaTrailing:
///   - Badge applies tint + .glassEffect(.regular, in: Capsule()) internally.
///   - Call site wraps badge in a standalone GlassEffectContainer (NOT nested
///     inside the card container) so it samples the real backdrop behind the panel.
///
/// ❌ Do NOT wrap the card itself in GlassEffectContainer — ActionRowView does not
///    do this and neither should runnerCard. Card glass is applied via .background{}.
private struct RunnerMetricsBadge: View {
    /// CPU utilisation percentage (0–100). `nil` means no data has arrived yet.
    let cpu: Double?
    /// Memory utilisation percentage (0–100). `nil` means no data has arrived yet.
    let mem: Double?

    /// Renders CPU and MEM metric items inside a `statPillBackground` capsule.
    /// Shows "—" when metrics are nil (runner idle / not yet enriched) so that
    /// zero load is distinguishable from "no data".
    var body: some View {
        HStack(spacing: 8) {
            metricItem(label: "CPU", value: cpu.map { String(format: "%.0f%%", $0) } ?? "—")
            metricItem(label: "MEM", value: mem.map { String(format: "%.0f%%", $0) } ?? "—")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .statPillBackground()
    }

    /// Renders a single label–value pair for use inside the badge HStack.
    private func metricItem(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(RBFont.statLabel)
                .foregroundColor(.secondary)
            Text(value)
                .font(RBFont.statValue)
                .foregroundColor(.primary)
                .monospacedDigit()
        }
    }
}

// MARK: - PanelLocalRunnerRow
/// Renders a card for each runner passed in.
///
/// ❌ DO NOT add an isBusy filter here — isBusy is set by RunnerStatusEnricher
/// on a separate background cycle and will always lag behind the RunnerStore
/// fetch cycle, causing rows to be silently swallowed. (#948)
struct PanelLocalRunnerRow: View {
    /// Maximum number of runner cards shown before a "+ N more…" overflow label is appended.
    private static let maxVisibleRunners = 3
    /// The runners to display. Up to `maxVisibleRunners` are shown; a "+ N more…" label is appended when exceeded.
    let runners: [RunnerModel]

    /// Renders the runner list when non-empty, otherwise produces no view.
    var body: some View {
        if !runners.isEmpty { runnerList(runners) }
    }

    /// Renders up to `maxVisibleRunners` runner cards followed by a divider.
    @ViewBuilder private func runnerList(_ active: [RunnerModel]) -> some View {
        ForEach(active.prefix(Self.maxVisibleRunners)) { runner in runnerCard(runner) }
        if active.count > Self.maxVisibleRunners {
            Text("+ \(active.count - Self.maxVisibleRunners) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 2)
        }
        Divider()
    }

    /// Glass architecture mirrors ActionRowView exactly:
    ///   - .glassCard() applied via .background{} directly — NO GlassEffectContainer around the card.
    ///   - RunnerMetricsBadge gets its own standalone GlassEffectContainer, same as
    ///     StatusBadge in ActionRowView.metaTrailing.
    private func runnerCard(_ runner: RunnerModel) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.rbWarning).frame(width: 7, height: 7)
            HStack(spacing: 4) {
                Text(runner.runnerName)
                    .font(RBFont.label)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let subtitle = runnerSubtitle(runner) {
                    Text("· \(subtitle)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer()
            // Standalone GlassEffectContainer — same as StatusBadge in metaTrailing.
            // NOT nested inside a card container so it samples the real backdrop.
            if #available(macOS 26, *) {
                GlassEffectContainer {
                    RunnerMetricsBadge(
                        cpu: runner.metrics?.cpu,
                        mem: runner.metrics?.mem
                    )
                }
            } else {
                RunnerMetricsBadge(
                    cpu: runner.metrics?.cpu,
                    mem: runner.metrics?.mem
                )
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xs + 2)
        .background {
            // .glassCard() handles its own #available branch internally.
            // No outer #available check needed here.
            Color.clear.glassCard(cornerRadius: RBRadius.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xxs)
    }

    /// Returns a formatted subtitle combining architecture and OS platform, or `nil` if neither is available.
    private func runnerSubtitle(_ runner: RunnerModel) -> String? {
        let arch = runner.platformArchitecture.map { normaliseArch($0) }
        let os = runner.platform.map { normalisePlatform($0) }
        return [arch, os].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    /// Normalises a raw architecture string to a canonical lowercase form.
    private func normaliseArch(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ARM64": return "arm64"
        case "X64":   return "x64"
        case "X86":   return "x86"
        default:      return raw.lowercased()
        }
    }

    /// Normalises a raw platform string to a human-readable OS name.
    private func normalisePlatform(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("osx") || lower.hasPrefix("darwin") { return "macOS" }
        if lower.hasPrefix("linux") { return "Linux" }
        if lower.hasPrefix("win") { return "Windows" }
        return raw
    }
}

// MARK: - String+nilIfEmpty
//
// Moved from PanelMainView+Subviews.swift.
// Retains only shared glue after extracting focused view files:
//   - PanelHeaderView.swift  (PanelHeaderView, SectionHeaderLabel)
//   - RunnerRowViews.swift   (PanelLocalRunnerRow, RunnerMetricsBadge, RunnerTypeIcon)
//   - ActionRowView.swift    (ActionRowView, RowTapModifier)

/// Convenience helpers used across panel subview files.
extension String {
    /// Returns `nil` when the string is empty, otherwise returns `self`.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
