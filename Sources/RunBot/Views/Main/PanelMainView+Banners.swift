// PanelMainView+Banners.swift
// RunBot
//
// Inline banner views (fetch error, rate-limit) for PanelMainView.
// Extracted from PanelMainView.swift for readability — no behaviour changes.
// All sizing contract invariants live in PanelMainView.swift.
import SwiftUI

extension PanelMainView {

    // MARK: - Banners

    /// Inline error banner shown when `appState.runnerState.fetchError` is non-nil.
    ///
    /// Displays a truncated error description. Dismisses automatically on the next
    /// successful fetch cycle when `applyFetchResult` clears `fetchError`.
    /// Stale `runners`/`jobs`/`actions` remain visible below the banner so the user
    /// still sees the last-known state while connectivity is degraded.
    func fetchErrorBanner(_ error: any Error) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption)
            Text("Fetch error — \(error.localizedDescription)")
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    /// Rate-limit warning banner showing a countdown to API reset.
    ///
    /// WHY withExtendedLifetime(displayTick):
    /// `displayTick` must be read inside `body` to register a SwiftUI dependency so the
    /// banner label refreshes every second. However, `rateLimitBanner` is a computed var
    /// called from body — not body itself — so the compiler cannot see the read directly.
    /// `withExtendedLifetime` is a zero-cost call that makes the dependency explicit to both
    /// the compiler and future readers without changing runtime behaviour. The actual per-second
    /// refresh is driven by the `tick:` parameter chain: body → actionsSectionContent →
    /// ActionRowView(tick:). This call is intentional and not dead code.
    var rateLimitBanner: some View {
        withExtendedLifetime(displayTick) {}
        let countdownLabel: String
        if let resetDate = appState.runnerState.rateLimitResetDate {
            let remaining = max(0, resetDate.timeIntervalSinceNow)
            if remaining < 1 {
                countdownLabel = "resuming\u{2026}"
            } else if remaining < 60 {
                countdownLabel = "resets in \(Int(remaining))s"
            } else {
                let mins = Int(remaining) / 60; let secs = Int(remaining) % 60
                countdownLabel = String(format: "resets in %dm %02ds", mins, secs)
            }
        } else { countdownLabel = "pausing polls" }
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow).font(.caption)
            Text("GitHub rate limit reached -- \(countdownLabel)").font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
