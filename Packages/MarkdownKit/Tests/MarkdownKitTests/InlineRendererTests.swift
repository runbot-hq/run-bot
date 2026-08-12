// InlineRendererTests.swift
// MarkdownKitTests
import Markdown
import Testing
@testable import MarkdownKit

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

    @Test func emptyStringProducesNoNodes() {
        let nodes = inlines(from: "")
        #expect(nodes.isEmpty)
    }
}
