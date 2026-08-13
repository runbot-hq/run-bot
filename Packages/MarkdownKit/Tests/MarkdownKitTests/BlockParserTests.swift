// BlockParserTests.swift
// RunBot
import Testing
import Markdown
@testable import MarkdownKit

@Suite struct BlockParserTests {

    private func blocks(from md: String) -> [MarkdownBlock] {
        Document(parsing: md).children.map { BlockParser.parse($0) }
    }

    @Test func headingLevels() {
        let bs = blocks(from: "# H1\n## H2\n### H3")
        guard bs.count == 3 else { Issue.record("expected 3 blocks"); return }
        if case .heading(let l, _) = bs[0] { #expect(l == 1) } else { Issue.record("expected heading") }
        if case .heading(let l, _) = bs[1] { #expect(l == 2) } else { Issue.record("expected heading") }
        if case .heading(let l, _) = bs[2] { #expect(l == 3) } else { Issue.record("expected heading") }
    }

    @Test func paragraph() {
        let bs = blocks(from: "Hello world")
        if case .paragraph(let inlines) = bs.first {
            #expect(!inlines.isEmpty)
        } else {
            Issue.record("expected paragraph")
        }
    }

    @Test func thematicBreak() {
        let bs = blocks(from: "---")
        if case .thematicBreak = bs.first { } else {
            Issue.record("expected thematicBreak")
        }
    }

    @Test func codeBlockLanguage() {
        let bs = blocks(from: "```swift\nlet x = 1\n```")
        if case .codeBlock(let code, let lang) = bs.first {
            #expect(lang == "swift")
            #expect(code.contains("let x"))
        } else {
            Issue.record("expected codeBlock")
        }
    }

    @Test func codeBlockNoLanguage() {
        let bs = blocks(from: "```\nfoo\n```")
        if case .codeBlock(_, let lang) = bs.first {
            #expect(lang == nil)
        } else {
            Issue.record("expected codeBlock")
        }
    }

    @Test func unorderedList() {
        let bs = blocks(from: "- a\n- b\n- c")
        if case .unorderedList(let items) = bs.first {
            #expect(items.count == 3)
        } else {
            Issue.record("expected unorderedList")
        }
    }

    @Test func orderedList() {
        let bs = blocks(from: "1. first\n2. second")
        if case .orderedList(let items, let start) = bs.first {
            #expect(items.count == 2)
            #expect(start == 1)
        } else {
            Issue.record("expected orderedList")
        }
    }

    @Test func orderedListNonOneStart() {
        // A list beginning at 7. must preserve that start index (fix for #2731).
        let bs = blocks(from: "7. seventh\n8. eighth\n9. ninth")
        if case .orderedList(let items, let start) = bs.first {
            #expect(items.count == 3)
            #expect(start == 7)
        } else {
            Issue.record("expected orderedList")
        }
    }

    @Test func blockQuote() {
        let bs = blocks(from: "> quoted text")
        if case .blockQuote(let inner) = bs.first {
            #expect(!inner.isEmpty)
        } else {
            Issue.record("expected blockQuote")
        }
    }

    @Test func tableDispatch() {
        let bs = blocks(from: "| A |\n|---|\n| 1 |")
        if case .table(_) = bs.first { } else {
            Issue.record("expected table block")
        }
    }

    @Test func emptyDocumentProducesNoBlocks() {
        let bs = blocks(from: "")
        #expect(bs.isEmpty)
    }
}
