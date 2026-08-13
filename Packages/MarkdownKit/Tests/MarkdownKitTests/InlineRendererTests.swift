// InlineRendererTests.swift
// RunBot
import Markdown
@testable import MarkdownKit
import Testing

@Suite struct InlineRendererTests {

    private func inlines(from md: String) -> [InlineNode] {
        let blocks = Document(parsing: md).children.map { BlockParser.parse($0) }
        guard case .paragraph(let nodes) = blocks.first else { return [] }
        return nodes
    }

    @Test func plainText() {
        let nodes = inlines(from: "hello world")
        guard case .text(let s) = nodes.first else {
            Issue.record("expected .text node"); return
        }
        #expect(s == "hello world")
    }

    @Test func boldParsed() {
        let nodes = inlines(from: "**bold**")
        let hasStrong = nodes.contains { if case .strong = $0 { return true }; return false }
        #expect(hasStrong)
    }

    @Test func italicParsed() {
        let nodes = inlines(from: "*italic*")
        let hasEmphasis = nodes.contains { if case .emphasis = $0 { return true }; return false }
        #expect(hasEmphasis)
    }

    @Test func inlineCodeParsed() {
        let nodes = inlines(from: "`code`")
        let hasCode = nodes.contains { if case .code = $0 { return true }; return false }
        #expect(hasCode)
    }

    @Test func strikeParsed() {
        let nodes = inlines(from: "~~strike~~")
        let hasStrike = nodes.contains { if case .strikethrough = $0 { return true }; return false }
        #expect(hasStrike)
    }

    @Test func linkParsed() {
        let nodes = inlines(from: "[label](https://example.com)")
        guard case .link(let dest, _) = nodes.first else {
            Issue.record("expected .link node"); return
        }
        #expect(dest == "https://example.com")
    }

    @Test func linkDestinationSurvivesParsing() {
        // Regression for #2731: destination must be non-empty after InlineParser.
        let nodes = inlines(from: "[RunBot](https://runbot.example.com/logs/123)")
        guard case .link(let dest, let children) = nodes.first else {
            Issue.record("expected .link node"); return
        }
        #expect(dest == "https://runbot.example.com/logs/123")
        // Label text must also survive.
        let hasLabel = children.contains { if case .text(let s) = $0 { return s == "RunBot" }; return false }
        #expect(hasLabel)
    }

    @Test func hardBreakEmitsNewline() {
        // Regression for #2731: .lineBreak must map to "\n", not " ".
        // Two trailing spaces produce a hard line break in CommonMark.
        let nodes = inlines(from: "line one  \nline two")
        let hasLineBreak = nodes.contains { if case .lineBreak = $0 { return true }; return false }
        #expect(hasLineBreak)
    }

    @Test func emptyStringProducesNoNodes() {
        let nodes = inlines(from: "")
        #expect(nodes.isEmpty)
    }

    @Test func unknownInlineContainerPreservesNestedVisibleText() {
        // Regression for #2740: unsupported inline containers (e.g. Image) must
        // preserve recursively nested visible text rather than discarding it.
        let nodes = inlines(from: "![prefix **bold** and `code`](https://example.com/image.png)")
        guard case .unknown(let text) = nodes.first else {
            Issue.record("expected unknown inline fallback")
            return
        }
        #expect(text == "prefix bold and code")
    }
}
