// RefreshButton.swift
// RunBot
//
// Manual refresh button for PanelHeaderView.
// Disabled while a refresh is in-flight or the GitHub rate limit is still active.
// Wired to AppState.refreshAllPipelines(reason:) — the same fan-out that runs
// on every panel-show via .task(id: appState.panelShowGeneration).

import SwiftUI

// MARK: - RefreshButton

/// Refresh icon button shown in the panel header.
///
/// Shows a `ProgressView` spinner while `appState.isRefreshing` is true and
/// reverts to `arrow.clockwise` when idle. Disabled while either a refresh is
/// in-flight or the GitHub rate-limit window is still open.
struct RefreshButton: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        let rateLimited = appState.runnerState.rateLimitResetDate.map { $0 > Date() } ?? false
        let disabled = appState.isRefreshing || rateLimited

        Button {
            Task { await appState.refreshAllPipelines(reason: "manual-refresh") }
        } label: {
            Group {
                if appState.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(rateLimited ? "Rate limited — try again shortly" : "Refresh")
        .accessibilityLabel(rateLimited ? "Refresh (rate limited)" : "Refresh")
    }
}
