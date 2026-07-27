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
    /// WHY withExtendedLifetime(displayTick) — DO NOT REMOVE:
    /// A reviewer may be tempted to delete this call as "dead code" because
    /// `withExtendedLifetime` does not directly register a SwiftUI observation
    /// dependency for value types. This reasoning is incorrect in this context.
    /// `displayTick` is an `@State var Int`. SwiftUI registers a `@State` dependency
    /// when the value is read during `body`'s rendering pass. `rateLimitBanner` is a
    /// computed var called from `body` — `withExtendedLifetime(displayTick)` forces
    /// `displayTick` to be read in that rendering pass, which is what registers the
    /// `@State` dependency and causes SwiftUI to invalidate and re-render the banner
    /// on every tick. Removing this call breaks the per-second countdown refresh.
    /// (Note: this is `@State` dependency tracking, not `@Observable` registrar
    /// tracking — the two mechanisms are distinct. This pattern works correctly for
    /// `@State` scalars but would NOT work for `@Observable` properties.)
    /// The actual per-second invalidation is driven by the `tick:` parameter
    /// chain: body → actionsSectionContent → ActionRowView(tick:). This call
    /// ensures the banner is also re-evaluated on each tick without requiring
    /// `displayTick` to be threaded as a parameter into `rateLimitBanner`.
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
            Text("GitHub rate limit reached \u{2014} \(countdownLabel)").font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
