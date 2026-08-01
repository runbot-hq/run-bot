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
///
/// When `params` is non-nil, the optional `title` is rendered bold above the message
/// and the optional `file:line` pair is rendered as a small secondary badge.
struct LogAnnotationLine: View {
    /// The severity level that determines border and background colour.
    let level: LogLine.AnnotationLevel
    /// The annotation message text (directive prefix already stripped).
    let text: String
    /// Optional structured metadata from the `::name params::message` wire format.
    ///
    /// When non-nil, `title` is rendered bold above the message and `file:line`
    /// is rendered as a small secondary badge. Falls back gracefully when nil.
    var params: AnnotationParams?

    /// The view body.
    var body: some View {
        HStack(spacing: 0) {
            // 3pt coloured left border
            Rectangle()
                .fill(borderColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                // Title row (bold) + file:line badge on the same line when both present
                if params?.title != nil || fileBadge != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let title = params?.title {
                            Text(title)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(borderColor)
                        }
                        if let badge = fileBadge {
                            Text(badge)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color.rbTextSecondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.rbTextSecondary.opacity(0.12))
                                .cornerRadius(3)
                        }
                    }
                }
                // Message text
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(borderColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Formats the `file:line` badge string when either `file` or `line` is present.
    private var fileBadge: String? {
        guard let file = params?.file else {
            return params?.line.map { ":\($0)" }
        }
        if let line = params?.line {
            return "\(file):\(line)"
        }
        return file
    }
}
