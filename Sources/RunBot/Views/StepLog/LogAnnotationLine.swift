// LogAnnotationLine.swift
// RunBot
import RunBotCore
import SwiftUI

/// An annotation log line rendered with a coloured left border and a tinted background.
///
/// Matches the GitHub.com annotation pill style:
/// - `.warning` → amber (`Color.rbWarning`)
/// - `.error`   → red   (`Color.rbDanger`)
/// - `.notice`  → muted (`Color.rbTextSecondary`)
struct LogAnnotationLine: View {
    /// The severity level that determines border and background colour.
    let level: LogLine.AnnotationLevel
    /// The annotation message text (directive prefix already stripped).
    let text: String

    /// The view body.
    var body: some View {
        HStack(spacing: 0) {
            // 3pt coloured left border
            Rectangle()
                .fill(borderColor)
                .frame(width: 3)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.rbTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .background(borderColor.opacity(0.08))
        .cornerRadius(2)
    }

    /// The accent colour for the left border and tinted background, keyed on `level`.
    private var borderColor: Color {
        switch level {
        case .warning: return Color.rbWarning
        case .error:   return Color.rbDanger
        case .notice:  return Color.rbTextSecondary
        }
    }
}
