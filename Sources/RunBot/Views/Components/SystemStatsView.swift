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
/// glass effect — matching the `StatusBadge` pattern in `SettingsView+Sections.swift`.
///
/// Corner radius: `RBRadius.small` (6 pt) -- matches toolbar button rounding.
///
/// Expands content to fill its allocated width before applying the glass surface,
/// so the glass shape tracks the stable outer frame rather than the intrinsic text width.
struct GlassBadgeContainer<Content: View>: View {
    /// The live-updating chip content rendered in the foreground.
    @ViewBuilder let content: () -> Content

    /// Renders the chip with an adaptive neutral tint beneath native Liquid Glass.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
        GlassEffectContainer {
            content()
                .frame(maxWidth: .infinity)
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
    /// The sparkline flexes to absorb any width not claimed by the label or value.
    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.rbTextSecondary)
                .fixedSize()
            SparklineView(history: history, currentPct: currentPct)
                .frame(minWidth: 16, maxWidth: .infinity)
                .frame(height: 14)
                .layoutPriority(0)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(labelColor)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    /// Foreground color shifting green -> orange -> red as `currentPct` crosses 60 and 85.
    /// - SeeAlso: `SparklineView.themeColor` uses the same 60/85 breakpoints.
    var labelColor: Color {
        if currentPct > 85 { return .rbDanger }
        if currentPct > 60 { return .rbWarning }
        return .primary
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
    /// Each chip gets an equal, stable share of the available bar width.
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
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
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
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            Color.secondary.opacity(0.3).frame(width: 1, height: 14)
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
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.sm)
    }
}
