// ScopeRowView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - ScopeRowView

/// Reusable scope row extracted from `ScopesView`.
///
/// Displays scope identity, enable/disable toggle, and delete button.
/// Toggle and delete do not also fire `onSelect`.
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

    /// The row layout.
    var body: some View {
        let isRepo = scope.scope.contains("/")
        let displayName = scope.displayName ?? scope.scope
        let hasAlias = scope.displayName != nil
        return Button {
            onSelect()
        } label: {
            HStack(spacing: 8) {
                Text(isRepo ? "Repo" : "Org")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.rbSurfaceElevated))
                    .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if hasAlias {
                        Text(scope.scope)
                            .font(.caption2)
                            .foregroundColor(Color.rbTextTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Text(scope.isEnabled ? "Active" : "Paused")
                    .font(.caption2)
                    .foregroundColor(scope.isEnabled ? Color.rbSuccess : Color.rbTextTertiary)
                Toggle("", isOn: Binding(
                    get: { scope.isEnabled },
                    set: { onSetEnabled($0) }
                ))
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .labelsHidden()
                .help(scope.isEnabled ? "Pause monitoring" : "Resume monitoring")
                .scaleEffect(0.8, anchor: .trailing)
                .buttonStyle(.borderless)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextTertiary)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.caption2)
                        .foregroundColor(Color.rbDanger)
                }
                .buttonStyle(.borderless)
                .help("Remove scope")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 5)
        .settingsGlassCard(background: .rbGlassNeutralBackground, cornerRadius: RBRadius.small)
        .padding(.horizontal, RBSpacing.xs)
        .opacity(scope.isEnabled ? 1.0 : 0.5)
    }
}
