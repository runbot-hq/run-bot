// LogGroupHeader.swift
// RunBot
import SwiftUI

/// A tappable group header row rendered for `##[group]` directives.
///
/// Displays a disclosure chevron that rotates when the group is expanded,
/// matching the visual convention GitHub.com uses for collapsible log sections.
struct LogGroupHeader: View {
    /// The group title extracted from the `##[group]Title` directive.
    let title: String
    /// Whether the group's child lines are currently hidden.
    let isCollapsed: Bool
    /// Called when the user taps the header row to toggle the collapsed state.
    let onToggle: () -> Void

    /// The view body.
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.rbTextSecondary)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.rbTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()) // full-width tap target
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
        .accessibilityHint("Double-tap to \(isCollapsed ? "expand" : "collapse")")
    }
}
