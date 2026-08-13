// MarkdownTableCellView.swift
// RunBot
import SwiftUI

/// Renders a single table cell using `InlineTextView`.
@MainActor
struct MarkdownTableCellView: View {
    /// Inline nodes forming the cell's content.
    let inlines: [InlineNode]
    /// Column alignment determined by the GFM alignment marker.
    let alignment: MarkdownTableModel.ColumnAlignment
    /// `true` for header row cells; applies bold font weight.
    let isHeader: Bool
    /// Inherited style tokens.
    let style: MarkdownStyle

    private var textAlignment: TextAlignment {
        switch alignment {
        case .center: return .center
        case .right:  return .trailing
        default:      return .leading
        }
    }

    /// SwiftUI view body — see type-level doc for rendering contract.
    var body: some View {
        InlineTextView(inlines: inlines, style: style)
            .font(isHeader ? style.tableFont.bold() : style.tableFont)
            .foregroundColor(style.textPrimary)
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: 220, alignment: textAlignment == .trailing ? .trailing : textAlignment == .center ? .center : .leading)
            .padding(style.spacingXS)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
