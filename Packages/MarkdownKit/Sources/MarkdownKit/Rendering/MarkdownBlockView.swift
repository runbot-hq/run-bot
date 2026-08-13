// MarkdownBlockView.swift
// RunBot
import SwiftUI

/// Dispatches rendering for a single `MarkdownBlock` to the appropriate sub-view.
///
/// Unknown/unsupported nodes render as readable plain text rather than
/// disappearing or crashing.
@MainActor
public struct MarkdownBlockView: View {
    /// The block node to render.
    let block: MarkdownBlock
    /// Inherited style tokens.
    let style: MarkdownStyle
    /// Current list nesting depth; 0 = not inside a list.
    var listDepth: Int = 0

    /// Creates a block view for the given block, style, and optional list depth.
    public init(block: MarkdownBlock, style: MarkdownStyle, listDepth: Int = 0) {
        self.block = block
        self.style = style
        self.listDepth = listDepth
    }

    /// SwiftUI view body — see type-level doc for rendering contract.
    public var body: some View {
        Group {
            switch block {
            case .heading(let level, let inlines):
                headingView(level: level, inlines: inlines)

            case .paragraph(let inlines):
                InlineTextView(inlines: inlines, style: style)
                    .font(style.baseFont)
                    .foregroundColor(style.paragraphTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(
                        .bottom,
                        listDepth > 0 ? style.listItemSpacing : style.blockBottomSpacing
                    )

            case .orderedList(let items, let start):
                MarkdownListView(items: items, ordered: true, startIndex: start, style: style, depth: listDepth)

            case .unorderedList(let items):
                MarkdownListView(items: items, ordered: false, style: style, depth: listDepth)

            case .blockQuote(let blocks):
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(style.borderSubtle)
                        .frame(width: style.blockQuoteBorderWidth)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(blocks.indices, id: \.self) { i in
                            MarkdownBlockView(block: blocks[i], style: blockQuoteContentStyle)
                        }
                    }
                    .padding(.horizontal, style.blockQuoteHorizontalPadding)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, style.blockBottomSpacing)

            case .codeBlock(let code, let language):
                MarkdownCodeBlockView(code: code, language: language, style: style)

            case .thematicBreak:
                Divider()
                    .overlay(style.borderSubtle)
                    .padding(.vertical, style.spacingMD)

            case .table(let model):
                MarkdownTableView(model: model, style: style)

            case .unknown(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(text)
                        .font(style.baseFont)
                        .foregroundColor(style.textSecondary)
                        .padding(.bottom, 4)
                } else {
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Private helpers

    @ViewBuilder
    private func headingView(level: Int, inlines: [InlineNode]) -> some View {
        let heading = style.headings.style(for: level)
        InlineTextView(inlines: inlines, style: style)
            .font(heading.font)
            .foregroundColor(heading.color)
            .padding(.top, heading.topSpacing)
            .padding(.bottom, heading.bottomSpacing)
    }

    private var blockQuoteContentStyle: MarkdownStyle {
        var copy = style
        copy.baseFont = style.blockQuoteFont
        copy.paragraphTextColor = style.blockQuoteTextColor
        return copy
    }
}
