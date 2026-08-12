// MarkdownTableCellView.swift
// MarkdownKit
import SwiftUI

/// Renders a single table cell using `InlineTextView`.
@MainActor
struct MarkdownTableCellView: View {
    let inlines: [InlineNode]
    let alignment: MarkdownTableModel.ColumnAlignment
    let isHeader: Bool
    let style: MarkdownStyle

    private var textAlignment: TextAlignment {
        switch alignment {
        case .center: return .center
        case .right:  return .trailing
        default:      return .leading
        }
    }

    var body: some View {
        InlineTextView(inlines: inlines, style: style)
            .font(isHeader ? style.baseFont.bold() : style.baseFont)
            .foregroundColor(style.textPrimary)
            .multilineTextAlignment(textAlignment)
            .lineLimit(10)
            .frame(maxWidth: 220, alignment: textAlignment == .trailing ? .trailing : textAlignment == .center ? .center : .leading)
            .padding(style.spacingXS)
            .textSelection(.enabled)
    }
}
