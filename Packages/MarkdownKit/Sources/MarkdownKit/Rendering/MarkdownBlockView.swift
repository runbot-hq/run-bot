// MarkdownBlockView.swift
// MarkdownKit
import SwiftUI

/// Dispatches rendering for a single `MarkdownBlock` to the appropriate sub-view.
///
/// Unknown/unsupported nodes render as readable plain text rather than
/// disappearing or crashing.
@MainActor
public struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle
    var listDepth: Int = 0

    public init(block: MarkdownBlock, style: MarkdownStyle, listDepth: Int = 0) {
        self.block = block
        self.style = style
        self.listDepth = listDepth
    }

    public var body: some View {
        Group {
            switch block {
            case .heading(let level, let inlines):
                headingView(level: level, inlines: inlines)

            case .paragraph(let inlines):
                InlineTextView(inlines: inlines, style: style)
                    .font(style.baseFont)
                    .foregroundColor(style.textPrimary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

            case .orderedList(let items, let start):
                MarkdownListView(items: items, ordered: true, startIndex: start, style: style, depth: listDepth)

            case .unorderedList(let items):
                MarkdownListView(items: items, ordered: false, style: style, depth: listDepth)

            case .blockQuote(let blocks):
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(style.borderSubtle)
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(blocks.indices, id: \.self) { i in
                            MarkdownBlockView(block: blocks[i], style: style)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)

            case .codeBlock(let code, let language):
                MarkdownCodeBlockView(code: code, language: language, style: style)

            case .thematicBreak:
                Divider()
                    .overlay(style.borderSubtle)
                    .padding(.vertical, 12)

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
        InlineTextView(inlines: inlines, style: style)
            .font(headingFont(level))
            .foregroundColor(level <= 3 ? style.textPrimary : style.textSecondary)
            .padding(.top, level == 1 ? 16 : level == 2 ? 12 : 10)
            .padding(.bottom, level <= 2 ? 8 : 4)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .system(size: 14, weight: .bold)
        case 2:  return .system(size: 13, weight: .semibold)
        case 3:  return .system(size: 12.5, weight: .medium)
        default: return .system(size: 12.5, weight: .regular)
        }
    }
}
