// ScopeRowView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - ScopeRowView

/// Reusable scope row matching the Local Runner row hierarchy. (#2907)
///
/// Status dot, display name, scope type, monitoring toggle, and delete action.
/// Capsule label, Active / Paused text, and chevron have been removed.
struct ScopeRowView: View {

    // MARK: - Inputs

    /// The scope entry to display.
    let scope: ScopeEntry
    /// Called when the row body is tapped (selection).
    let onSelect: () -> Void
    /// Called when the toggle is flipped with the new enabled state.
    let onSetEnabled: (Bool) -> Void
    /// Called when the delete button is tapped.
    let onDelete: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Circle()
                    .fill(scope.isEnabled ? Color.rbSuccess : Color.secondary)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(scope.displayName ?? scope.scope)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(scope.scope.contains("/") ? "Repository" : "Organization")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { scope.isEnabled },
                        set: { onSetEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .scaleEffect(0.8, anchor: .trailing)
                .buttonStyle(.borderless)
                .help(scope.isEnabled ? "Pause monitoring" : "Resume monitoring")

                Button(
                    action: onDelete,
                    label: {
                        Image(systemName: "minus.circle")
                            .font(.caption2)
                            .foregroundStyle(Color.rbDanger)
                    }
                )
                .buttonStyle(.plain)
                .help("Remove scope")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 5)
    }
}
