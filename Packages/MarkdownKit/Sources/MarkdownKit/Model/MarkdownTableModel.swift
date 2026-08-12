// MarkdownTableModel.swift
// MarkdownKit
import Markdown

/// Normalised, deterministic representation of a GFM table.
///
/// Decoupled from SwiftUI — fully unit-testable without any view imports.
public struct MarkdownTableModel: Sendable {

    /// Per-column alignment derived from the table’s alignment row.
    public enum ColumnAlignment: Sendable {
        /// No alignment specified.
        case none
        /// Left-aligned column.
        case left
        /// Centre-aligned column.
        case center
        /// Right-aligned column.
        case right
    }

    /// A single table cell with parsed inline content and column alignment.
    public struct Cell: Sendable {
        /// Parsed inline nodes for this cell’s content.
        public let inlines: [InlineNode]
        /// Column alignment inherited from the table header row.
        public let alignment: ColumnAlignment
    }

    /// Cells in the header row, one per column.
    public let headerCells: [Cell]
    /// Body rows, each normalised to `columnCount` cells.
    public let rows: [[Cell]]
    /// Number of columns (derived from alignment row or header cell count).
    public let columnCount: Int

    /// Builds a model from a `swift-markdown` `Table` node.
    public init(table: Markdown.Table) {
        let rawAlignments: [ColumnAlignment] = table.columnAlignments.map {
            switch $0 {
            case .left:   return .left
            case .center: return .center
            case .right:  return .right
            default:      return .none
            }
        }
        let colCount = max(rawAlignments.count, 1)
        self.columnCount = colCount

        func alignment(at index: Int) -> ColumnAlignment {
            index < rawAlignments.count ? rawAlignments[index] : .none
        }

        func parseCells(from container: any TableCellContainer) -> [Cell] {
            let rawCells = Array(container.cells)
            return (0..<colCount).map { i in
                let inlines: [InlineNode] = i < rawCells.count
                    ? InlineParser.parse(rawCells[i])
                    : []
                return Cell(inlines: inlines, alignment: alignment(at: i))
            }
        }

        // Table.Head conforms to TableCellContainer directly — it IS the header row.
        self.headerCells = parseCells(from: table.head)
        self.rows = table.body.rows.map { parseCells(from: $0) }
    }
}
