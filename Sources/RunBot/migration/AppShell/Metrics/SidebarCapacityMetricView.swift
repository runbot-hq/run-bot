// SidebarCapacityMetricView.swift
// RunBot

import SwiftUI

// MARK: - SidebarCapacityMetricView

/// Compact two-line metric row showing used / total GB and available GB.
///
/// Used for Memory and Disk in the sidebar metrics footer.
/// Values are expressed in GB (Double) to match `SystemStats` storage;
/// `formatGB(_:)` trims trailing zeros and appends "GB".
struct SidebarCapacityMetricView: View {

    /// Short uppercase label, e.g. "MEM" or "DISK".
    let title: String
    /// Used capacity in gigabytes.
    let used: Double
    /// Total capacity in gigabytes.
    let total: Double

    /// Available capacity derived from inputs; clamped to zero.
    private var available: Double { max(total - used, 0) }

    /// Formats a GB value compactly with one decimal place.
    private func formatGB(_ gb: Double) -> String {
        String(format: "%.1f GB", gb)
    }

    /// Full textual description for VoiceOver.
    private var accessibilityText: String {
        "\(title), \(formatGB(used)) used, \(formatGB(total)) capacity, \(formatGB(available)) available"
    }

    /// The compact two-line capacity row.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                Spacer()
                Text("\(formatGB(used)) / \(formatGB(total))")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
            Text("\(formatGB(available)) available")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
