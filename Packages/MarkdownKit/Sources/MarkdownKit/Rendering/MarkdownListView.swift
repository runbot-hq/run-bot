// MarkdownListView.swift
// RunBot
import SwiftUI

/// Renders ordered and unordered lists, supporting nested lists via `listDepth`.
@MainActor
public struct MarkdownListView: View {
    let items: [[MarkdownBlock]]
    let ordered: Bool
    let startIndex: Int
    let style: MarkdownStyle
    let depth: Int

    public init(
        items: [[MarkdownBlock]],
        ordered: Bool,
        startIndex: Int = 1,
        style: MarkdownStyle,
        depth: Int = 0
    ) {
        self.items = items
        self.ordered = ordered
        self.startIndex = startIndex
        self.style = style
        self.depth = depth
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style.listItemSpacing) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ordered ? "\(startIndex + i)." : "•")
                        .font(style.baseFont)
                        .foregroundColor(style.textSecondary)
                        .frame(minWidth: ordered ? 20 : 10, alignment: .trailing)
                    VStack(alignment: .leading, spacing: style.listItemSpacing) {
                        ForEach(items[i].indices, id: \.self) { j in
                            MarkdownBlockView(
                                block: items[i][j],
                                style: style,
                                listDepth: depth + 1
                            )
                        }
                    }
                }
            }
        }
        .padding(
            .bottom,
            depth == 0 ? style.blockBottomSpacing : style.listItemSpacing
        )
    }
}
