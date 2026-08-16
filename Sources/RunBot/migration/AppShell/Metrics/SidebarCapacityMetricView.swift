// SidebarCapacityMetricView.swift
// RunBot

import SwiftUI

// MARK: - SidebarCapacityMetricView

/// Three-zone metric row: header with used/total, capacity progress bar, used/free footer.
///
/// Used for Memory and Disk in the sidebar metrics footer.
/// Values are expressed in GB (Double) to match `SystemStats` storage.
/// Adaptive precision: values below 100 GB show one decimal; 100+ show none.
struct SidebarCapacityMetricView: View {

    /// Short uppercase label shown as the row heading, e.g. "MEM" or "DISK".
    let title: String
    /// Full spoken label used by VoiceOver, e.g. "Memory" or "Disk".
    let accessibilityTitle: String
    /// Used capacity in gigabytes.
    let used: Double
    /// Total capacity in gigabytes.
    let total: Double

    /// Free capacity clamped to zero.
    private var free: Double { max(total - used, 0) }

    /// Filled fraction clamped to 0-1; zero when total is zero.
    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(used / total, 0), 1)
    }

    /// Adaptive GB string: one decimal below 100, no decimals at 100+.
    private func formatted(_ value: Double) -> String {
        value >= 100
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    /// Full textual description for VoiceOver.
    private var accessibilityDescription: String {
        "\(accessibilityTitle), "
            + "\(formatted(used)) gigabytes used, "
            + "\(formatted(total)) gigabytes total, "
            + "\(formatted(free)) gigabytes free"
    }

    /// Severity color for the capacity bar, driven by used percentage.
    private var severityColor: Color {
        .rbMetricSeverity(percentage: fraction * 100)
    }

    /// Header, capacity bar, and used/free footer.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                Spacer()

                Text("\(formatted(used)) / \(formatted(total)) GB")
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.rbMetricTrack)

                    Capsule()
                        .fill(severityColor)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: SidebarMetricLayout.barHeight)

            HStack {
                Text("used \(formatted(used))")
                Spacer()
                Text("free \(formatted(free))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(height: SidebarMetricLayout.rowHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}
