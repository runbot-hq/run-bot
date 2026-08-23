// SidebarMetricsView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - SidebarMetricLayout

/// Shared layout constants for sidebar metric rows.
/// Use these instead of hardcoding sizes in individual metric views.
enum SidebarMetricLayout {
    /// Fixed total row height for every metric row (usage and capacity).
    static let rowHeight: CGFloat = 44
    /// Height of the CPU and GPU sparkline graphs.
    static let graphHeight: CGFloat = 16
    /// Height of the Memory and Disk capacity bars.
    static let barHeight: CGFloat = 6
}

// MARK: - SidebarMetricsView

/// Pinned sidebar footer showing live CPU, GPU, memory, and disk metrics.
///
/// Owns a single `SystemStatsViewModel` whose lifecycle is tied to this view:
/// sampling starts on `.onAppear` and stops on `.onDisappear`. The sidebar
/// stays mounted while detail destinations change, so navigation never
/// restarts the sampler.
///
/// ## Layout
/// A `thinMaterial` rounded-rectangle groups the four rows inside a compact
/// footer that stays pinned below the navigation `List` in `AppSidebarView`.
/// The footer height is bounded so it cannot consume the entire sidebar when
/// the window is short.
///
/// ## Reuse
/// Reuses `SystemStatsViewModel`, `SystemStats`, and `SparklineView`.
/// Does not embed the full-page `SystemStatsView`.
@MainActor
struct SidebarMetricsView: View {

    /// View-local sampler. Constructed once; never written to `AppDependencies`.
    @State private var viewModel = SystemStatsViewModel()

    /// The four metric rows grouped in a compact material surface.
    var body: some View {
        VStack(spacing: 0) {
            SidebarUsageMetricView(
                title: "CPU",
                accessibilityTitle: "CPU",
                value: viewModel.stats.cpuPct,
                history: viewModel.cpuHistory.values,
                fractionDigits: 1
            )
            SidebarUsageMetricView(
                title: "GPU",
                accessibilityTitle: "GPU",
                value: viewModel.stats.gpuPct,
                history: viewModel.gpuHistory.values,
                fractionDigits: 0
            )

            SidebarCapacityMetricView(
                title: "MEM",
                accessibilityTitle: "Memory",
                used: viewModel.stats.memUsedGB,
                total: viewModel.stats.memTotalGB
            )
            SidebarCapacityMetricView(
                title: "DISK",
                accessibilityTitle: "Disk",
                used: viewModel.stats.diskUsedGB,
                total: viewModel.stats.diskTotalGB
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .frame(maxHeight: 200)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}
