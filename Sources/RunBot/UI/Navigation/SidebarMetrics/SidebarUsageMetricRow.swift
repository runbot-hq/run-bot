// SidebarUsageMetricRow.swift
// RunBot

import SwiftUI

// MARK: - SidebarUsageMetricRow

/// Two-zone metric row: percentage header and full-width severity-colored sparkline.
///
/// Used for CPU and GPU in the sidebar metrics footer.
/// When `value` is `nil` the header shows an em-dash and a neutral
/// empty graph band is rendered without fabricating zero samples.
struct SidebarUsageMetricRow: View {

    /// Short uppercase label shown as the row heading, e.g. "CPU".
    let title: String
    /// Full spoken label used by VoiceOver, e.g. "CPU" or "GPU".
    let accessibilityTitle: String
    /// Current percentage in the range 0-100, or `nil` when telemetry is absent.
    let value: Double?
    /// Ordered oldest-to-newest history values in the range 0-100.
    let history: [Double]
    /// Number of decimal places in the formatted percentage string.
    let fractionDigits: Int

    /// Value clamped to 0-100, or `nil` when unavailable.
    private var clampedValue: Double? {
        value.map { min(max($0, 0), 100) }
    }

    /// Formatted percentage string, or an em-dash when unavailable.
    private var formattedValue: String {
        guard let pct = clampedValue else { return "—" }
        return pct.formatted(
            .number.precision(.fractionLength(fractionDigits))
        ) + "%"
    }

    /// Full textual description for VoiceOver.
    private var accessibilityDescription: String {
        guard clampedValue != nil else { return "\(accessibilityTitle) unavailable" }
        return "\(accessibilityTitle), \(formattedValue)"
    }

    /// Header row plus full-width sparkline (or neutral band when unavailable).
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                Spacer()

                Text(formattedValue)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if let pct = clampedValue, !history.isEmpty {
                SparklineView(
                    history: history,
                    currentPct: pct
                )
                .frame(maxWidth: .infinity)
                .frame(height: SidebarMetricLayout.graphHeight)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .frame(height: SidebarMetricLayout.graphHeight)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: SidebarMetricLayout.rowHeight, maxHeight: SidebarMetricLayout.rowHeight, alignment: .center)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}
