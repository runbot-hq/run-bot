// SidebarMetricsView.swift
// RunBot

import RunBotCore
import SwiftUI

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

    /// View-local sampler. Constructed once; never written to `MigrationAppDependencies`.
    @State private var viewModel = SystemStatsViewModel()

    /// The four metric rows grouped in a compact material surface.
    var body: some View {
        VStack(spacing: 8) {
            SidebarUsageMetricView(
                title: "CPU",
                value: viewModel.stats.cpuPct,
                history: viewModel.cpuHistory.values
            )
            SidebarUsageMetricView(
                title: "GPU",
                value: viewModel.stats.gpuPct,
                history: viewModel.gpuHistory.values
            )
            SidebarCapacityMetricView(
                title: "MEM",
                used: viewModel.stats.memUsedGB,
                total: viewModel.stats.memTotalGB
            )
            SidebarCapacityMetricView(
                title: "DISK",
                used: viewModel.stats.diskUsedGB,
                total: viewModel.stats.diskTotalGB
            )
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}
