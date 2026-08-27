// LogPlainLine.swift
// RunBot
import RunBotCore
import SwiftUI

/// A single plain log line rendered in monospaced text.
///
/// ANSI SGR escape sequences (GitHub Actions subset) are rendered via
/// `ansiAttributedString`; unrecognised codes are silently stripped.
///
/// `textSelection` is applied at the parent `LazyVStack` level; this view does not
/// need to set it individually.
struct LogPlainLine: View {
    /// The log line text to display (may contain ANSI escape sequences).
    let text: String

    /// Base monospaced font shared across all plain log line renders.
    private static let baseFont: Font = .system(size: 11, design: .monospaced)

    /// The view body.
    var body: some View {
        Text(ansiAttributedString(text, baseColor: .rbTextPrimary, font: Self.baseFont))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
