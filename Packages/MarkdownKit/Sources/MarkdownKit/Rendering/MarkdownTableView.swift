// MarkdownTableView.swift
// RunBot
import SwiftUI

/// Renders a GFM table using a horizontally-scrolling `Grid`.
///
/// `MarkdownTableModel` normalises ragged rows and alignment before this
/// view is constructed. Cell widths are bounded at 220pt to prevent a single
/// wide column from pushing the table off screen in narrow panels.
@MainActor
public struct MarkdownTableView: View {
    let model: MarkdownTableModel
    let style: MarkdownStyle

    public init(model: MarkdownTableModel, style: MarkdownStyle) {
        self.model = model
        self.style = style
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Single Grid so header and body columns share the same width measurement.
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                // Header row
                GridRow {
                    ForEach(model.headerCells.indices, id: \.self) { i in
                        MarkdownTableCellView(
                            inlines: model.headerCells[i].inlines,
                            alignment: model.headerCells[i].alignment,
                            isHeader: true,
                            style: style
                        )
                    }
                }
                // Header / body separator
                GridRow {
                    Divider()
                        .overlay(style.borderSubtle)
                        .gridCellColumns(max(model.headerCells.count, 1))
                }
                // Body rows
                ForEach(model.rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(model.rows[r].indices, id: \.self) { c in
                            MarkdownTableCellView(
                                inlines: model.rows[r][c].inlines,
                                alignment: model.rows[r][c].alignment,
                                isHeader: false,
                                style: style
                            )
                        }
                    }
                    if r < model.rows.count - 1 {
                        GridRow {
                            Divider()
                                .overlay(style.borderSubtle.opacity(0.4))
                                .gridCellColumns(max(model.headerCells.count, 1))
                        }
                    }
                }
            }
        }
        .padding(.bottom, style.blockBottomSpacing)
    }
}
