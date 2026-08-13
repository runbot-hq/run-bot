// TableModelTests.swift
// RunBot
import Testing
import Markdown
@testable import MarkdownKit

@Suite struct TableModelTests {

    private func table(from md: String) -> Table {
        let doc = Document(parsing: md)
        return doc.children.first { $0 is Markdown.Table } as! Markdown.Table
    }

    @Test func alignmentMapping() {
        let model = MarkdownTableModel(table: table(from: """
        | L | C | R |
        |:--|:--:|--:|
        | a | b | c |
        """))
        #expect(model.columnCount == 3)
        #expect(model.headerCells[0].alignment == .left)
        #expect(model.headerCells[1].alignment == .center)
        #expect(model.headerCells[2].alignment == .right)
        #expect(model.rows.count == 1)
    }

    @Test func defaultAlignmentIsNone() {
        let model = MarkdownTableModel(table: table(from: """
        | A | B |
        |---|---|
        | 1 | 2 |
        """))
        #expect(model.headerCells[0].alignment == .none)
        #expect(model.headerCells[1].alignment == .none)
    }

    @Test func raggedRowNormalisedToColumnCount() {
        // Body row has only 1 cell but header defines 3 columns.
        let model = MarkdownTableModel(table: table(from: """
        | A | B | C |
        |---|---|---|
        | x |
        """))
        #expect(model.rows[0].count == 3)
        #expect(model.rows[0][1].inlines.isEmpty)
        #expect(model.rows[0][2].inlines.isEmpty)
    }

    @Test func emptyBodyProducesNoRows() {
        let model = MarkdownTableModel(table: table(from: """
        | A |
        |---|
        """))
        #expect(model.rows.isEmpty)
    }

    @Test func multipleBodyRows() {
        let model = MarkdownTableModel(table: table(from: """
        | X | Y |
        |---|---|
        | 1 | 2 |
        | 3 | 4 |
        | 5 | 6 |
        """))
        #expect(model.rows.count == 3)
    }

    @Test func inlineFormattingInCell() {
        let model = MarkdownTableModel(table: table(from: """
        | **Bold** |
        |----------|
        | *em* |
        """))
        // Header cell contains a Strong inline node.
        let headerInlines = model.headerCells[0].inlines
        let hasStrong = headerInlines.contains { if case .strong = $0 { return true }; return false }
        #expect(hasStrong)
    }
}
