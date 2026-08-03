// LogDimmedLine.swift
// RunBot
import RunBotCore
import SwiftUI

/// A dimmed log line rendered for `##[command]` and `##[debug]` directives.
///
/// These lines are visually de-emphasised (secondary colour, reduced opacity)
/// so they don't compete with plain log output, while remaining present in the
/// view tree so copy-all selections include them.
///
/// ANSI SGR escape sequences (GitHub Actions subset) are rendered via
/// `ansiAttributedString`; unrecognised codes are silently stripped.
struct LogDimmedLine: View {
    /// The directive text (prefix already stripped and trimmed, may contain ANSI sequences).
    let text: String

    /// Base monospaced font shared across all dimmed log line renders.
    private static let baseFont: Font = .system(size: 11, design: .monospaced)

    /// The view body.
    var body: some View {
        Text(ansiAttributedString(text, baseColor: .rbTextSecondary, font: Self.baseFont))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0.7)
    }
}
