// LogDimmedLine.swift
// RunBot
import SwiftUI

/// A dimmed log line rendered for `##[command]` and `##[debug]` directives.
///
/// These lines are visually de-emphasised (secondary colour, reduced opacity)
/// so they don't compete with plain log output, while remaining present in the
/// view tree so copy-all selections include them.
struct LogDimmedLine: View {
    /// The directive text (prefix already stripped and trimmed).
    let text: String

    /// The view body.
    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color.rbTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0.7)
    }
}
