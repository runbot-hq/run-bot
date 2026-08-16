// SidebarUsageMetricView.swift
// RunBot

import SwiftUI

// MARK: - SidebarUsageMetricView

/// Compact one-line metric row showing a percentage value and sparkline history.
///
/// Used for CPU and GPU in the sidebar metrics footer.
/// The sparkline yields layout space before the numeric label so the value
/// remains readable even in a narrow sidebar.
///
/// When `value` is `nil` (e.g. GPU telemetry unavailable) the label shows
/// an em-dash and the sparkline is omitted entirely — no fabricated zeros.
struct SidebarUsageMetricView: View {

    /// Short uppercase label shown in a fixed-width leading slot, e.g. "CPU".
    let title: String
    /// Current percentage in the range 0–100, or `nil` when telemetry is absent.
    let value: Double?
    /// Ordered oldest-to-newest history values in the range 0–100.
    let history: [Double]

    /// Formatted percentage string, or an em-dash when unavailable.
    private var formattedValue: String {
        guard let value else { return "—" }
        let clamped = min(max(value, 0), 100)
        return String(format: "%.0f%%", clamped)
    }

    /// Full textual description for VoiceOver.
    private var accessibilityText: String {
        guard let value else { return "\(title) unavailable" }
        let clamped = min(max(value, 0), 100)
        return "\(title) \(String(format: "%.0f", clamped)) percent"
    }

    /// The compact horizontal metric row.
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .frame(width: 30, alignment: .leading)

            if value != nil, !history.isEmpty {
                SparklineView(
                    history: history,
                    currentPct: min(max(value ?? 0, 0), 100)
                )
                .frame(minWidth: 24, idealWidth: 56, maxWidth: 80)
                .frame(height: 18)
                .layoutPriority(0)
            } else {
                Spacer(minLength: 0).layoutPriority(0)
            }

            Text(formattedValue)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 42, alignment: .trailing)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
