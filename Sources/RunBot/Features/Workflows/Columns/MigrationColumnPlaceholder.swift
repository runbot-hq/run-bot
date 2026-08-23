// MigrationColumnPlaceholder.swift
// RunBot

import SwiftUI

/// Width-adaptive placeholder for workflow column panes.
/// Uses `minimumScaleFactor` so text stays visible in narrow columns.
struct MigrationColumnPlaceholder: View {
    /// Primary label shown below the icon.
    let title: String
    /// SF Symbol name for the placeholder icon.
    let systemImage: String
    /// Optional secondary description shown below the title.
    var description: String?

    /// The placeholder layout.
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            if let description {
                Text(description)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
