// LogSectionHeader.swift
// RunBot
import SwiftUI

/// A section heading rendered for `##[section]` directives.
///
/// Displays a `Divider()` above the title to visually separate runner diagnostic
/// sections from surrounding log output. The title is bold monospaced to match
/// GitHub.com’s section heading style.
struct LogSectionHeader: View {
    /// The section title extracted from the `##[section]Title` directive.
    let title: String

    /// The view body.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Color.rbTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.vertical, 2)
    }
}
