// SystemStatsView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - SystemStatsView

// periphery:ignore
/// Full-page system stats view shown in the settings panel.
struct SystemStatsView: View {
    /// The view model providing live CPU, memory, and disk stats.
    @State private var viewModel = SystemStatsViewModel()
    /// Renders a vertical list of labelled stat rows.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Stats")
                .font(.headline)
                .padding(.bottom, 4)
            statRow(label: "CPU", value: String(format: "%.1f%%", viewModel.stats.cpuPct))
            statRow(label: "Memory Used", value: String(format: "%.1f GB", viewModel.stats.memUsedGB))
            statRow(label: "Memory Total", value: String(format: "%.1f GB", viewModel.stats.memTotalGB))
            statRow(label: "Disk Used", value: String(format: "%.1f GB", viewModel.stats.diskUsedGB))
            statRow(label: "Disk Total", value: String(format: "%.1f GB", viewModel.stats.diskTotalGB))
        }
        .padding()
        .glassCard(cornerRadius: RBRadius.card)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    /// Returns a single label/value `HStack` row for display in the stats panel.
    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(RBFont.monoSmall)
                .foregroundColor(Color.rbTextSecondary)
            Spacer()
            Text(value)
                .font(RBFont.mono)
        }
    }
}

// MARK: - GlassBadgeContainer

/// A stable glass wrapper for live-updating chip content (CPU, MEM, DISK chips only).
///
/// Uses `rbGlassNeutralBackground` (black 0.15 light / white 0.10 dark) beneath a `.regular`
/// glass effect — matching the `StatusCountBadge` pattern in `SettingsView+Sections.swift`.
///
/// Corner radius: `RBRadius.small` (6 pt) -- matches toolbar button rounding.
///
/// Do NOT apply to DiskPillBadge (the "22% free" pill) -- that has its own styling.
struct GlassBadgeContainer<Content: View>: View {
    /// The live-updating chip content rendered in the foreground.
    @ViewBuilder let content: () -> Content

    /// Renders the chip with an adaptive neutral tint beneath native Liquid Glass.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
        GlassEffectContainer {
            content()
                .padding(.horizontal, RBSpacing.sm)
                .padding(.vertical, RBSpacing.xs)
                .background(Color.rbGlassNeutralBackground, in: shape)
                .glassEffect(.regular, in: shape)
        }
    }
}

// MARK: - SparklineMetricView

/// A single header metric chip: label + inline sparkline + monospaced value in one horizontal row.
///
/// Layout: CPU [sparkline] 41.1% MEM [sparkline] 6.4/16.0GB
///
/// Do NOT restore the VStack layout -- it makes the header ~70pt tall.
struct SparklineMetricView: View {
    /// The short uppercase label displayed to the left of the sparkline (e.g. "CPU", "MEM").
    let label: String
    /// The formatted value string displayed to the right of the sparkline.
    let value: String
    /// Ring-buffer history of samples (0-100) ordered oldest to newest, used to draw the sparkline.
    let history: [Double]
    /// Current value (0-100) used to derive `labelColor`.
    let currentPct: Double

    /// Renders label, sparkline, and value in a horizontal stack.
    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.rbTextSecondary)
                .fixedSize()
            SparklineView(history: history, currentPct: currentPct)
                .frame(width: 40, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(labelColor)
                .fixedSize()
        }
        .fixedSize()
    }

    /// Foreground color shifting green -> orange -> red as `currentPct` crosses 60 and 85.
    /// - SeeAlso: `SparklineView.themeColor` uses the same 60/85 breakpoints.
    var labelColor: Color {
        if currentPct > 85 { return .rbDanger }
        if currentPct > 60 { return .rbWarning }
        return .primary
    }
}

// MARK: - DiskPillBadge

/// Compact pill showing disk FREE percentage.
///
/// Color thresholds (based on free space, not used):
/// - `freePct < 15` -> `rbDanger` (disk nearly full)
/// - `freePct < 40` -> `rbWarning` (disk getting full)
/// - `freePct >= 40` -> `rbSuccess` (plenty of space)
///
/// macOS 26+: wrapped in a `GlassEffectContainer` at the call site (HeaderStatsBar)
/// so it gets a dedicated CABackdropLayer sampling region. The `.glassEffect` here
/// then refracts correctly without being glass-on-glass with no shared container.
struct DiskPillBadge: View {
    /// Free disk space as a percentage (0-100).
    let freePct: Double

    /// Renders a styled percentage pill with danger/warning/success color.
    var body: some View {
        Text(String(format: "%.0f%% free", freePct))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(pillColor)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(pillColor.opacity(0.15), in: Capsule())
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
    }

    /// Pill foreground and tint color based on free disk percentage.
    private var pillColor: Color {
        if freePct < 15 { return .rbDanger }
        if freePct < 40 { return .rbWarning }
        return .rbSuccess
    }
}

// MARK: - HeaderStatsBar

/// Compact single-row stats bar: CPU | MEM | DISK inline chips for the panel header.
///
/// Accepts an existing `SystemStatsViewModel` so it shares the sampler
/// already running in `PanelMainView` -- no second timer is created.
struct HeaderStatsBar: View {
    /// The view model supplying live CPU, memory, and disk stats.
    var statsVM: SystemStatsViewModel

    /// Renders CPU, MEM, and DISK chips separated by thin dividers.
    var body: some View {
        HStack(spacing: RBSpacing.md) {
            let cpuPct = statsVM.stats.cpuPct
            GlassBadgeContainer {
                SparklineMetricView(
                    label: "CPU",
                    value: String(format: "%.1f%%", cpuPct),
                    history: statsVM.cpuHistory.values,
                    currentPct: cpuPct
                )
            }
            Color.secondary.opacity(0.3).frame(width: 1, height: 14)
            let memTotal = statsVM.stats.memTotalGB
            let memUsed = statsVM.stats.memUsedGB
            let memPct = memTotal > 0 ? memUsed / memTotal * 100 : 0.0
            GlassBadgeContainer {
                SparklineMetricView(
                    label: "MEM",
                    value: String(format: "%.1f/%.1fGB", memUsed, memTotal),
                    history: statsVM.memHistory.values,
                    currentPct: memPct
                )
            }
            Color.secondary.opacity(0.3).frame(width: 1, height: 14)
            HStack(spacing: RBSpacing.xs) {
                let diskTotal = statsVM.stats.diskTotalGB
                let diskUsed = statsVM.stats.diskUsedGB
                let diskUsedPct = diskTotal > 0 ? diskUsed / diskTotal * 100 : 0.0
                GlassBadgeContainer {
                    SparklineMetricView(
                        label: "DISK",
                        value: String(format: "%d/%dGB",
                                      Int(statsVM.stats.diskUsedGB.rounded()),
                                      Int(statsVM.stats.diskTotalGB.rounded())),
                        history: statsVM.diskHistory.values,
                        currentPct: diskUsedPct
                    )
                }
                if statsVM.stats.diskTotalGB > 0 {
                    // GlassEffectContainer gives DiskPillBadge its own dedicated
                    // CABackdropLayer sampling region so .glassEffect inside the
                    // pill refracts correctly instead of glass-on-glass with no container.
                    GlassEffectContainer {
                        DiskPillBadge(freePct: statsVM.stats.diskFreePct)
                    }
                }
            }
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.sm)
    }
}
