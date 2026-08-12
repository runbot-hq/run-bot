// MarkdownDocumentView.swift
// RunBot
//
// Public rendering entry point for normalized MarkdownBlock values.
// The convenience markdown initializer parses synchronously for short inputs;
// RunBot uses parseAsync + init(blocks:style:) for full step logs.
import Markdown
import SwiftUI

// MARK: - MarkdownDocumentView

/// Public rendering surface for MarkdownKit.
///
/// Prefer `MarkdownDocumentView(blocks:style:)` when the caller has already
/// parsed off the main actor. Use `MarkdownDocumentView(markdown:style:)` only
/// for simple / short strings where main-thread parse cost is negligible.
@MainActor
public struct MarkdownDocumentView: View {
    private let blocks: [MarkdownBlock]
    private let style: MarkdownStyle

    /// Creates a document view from pre-parsed blocks (preferred — no parse on main actor).
    public init(blocks: [MarkdownBlock], style: MarkdownStyle) {
        self.blocks = blocks
        self.style = style
    }

    /// Creates a document view by parsing `markdown` synchronously.
    ///
    /// ⚠️ Runs `Document(parsing:)` on the calling actor. For large strings call
    /// `BlockParser.parseAsync(_:)` off the main actor and use `init(blocks:style:)`.
    public init(markdown: String, style: MarkdownStyle) {
        self.style = style
        let doc = Document(parsing: markdown)
        self.blocks = doc.children.map { BlockParser.parse($0) }
    }

    /// The rendered document.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { i in
                MarkdownBlockView(block: blocks[i], style: style)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - BlockParser

/// Converts a single `swift-markdown` `Markup` node into a `MarkdownBlock`.
///
/// Top-level only — list-item children are handled recursively inside
/// `MarkdownListView` via further `BlockParser.parse` calls.
public enum BlockParser {

    /// Parses a full Markdown string into `[MarkdownBlock]` off the main actor.
    ///
    /// `@concurrent` forces an executor hop under `NonisolatedNonsendingByDefault`
    /// (Swift 6.2), ensuring `Document(parsing:)` never runs on the caller's actor
    /// even when called from a main-actor `.task` closure.
    ///
    /// Safe to call from a `Task` or `task(id:)` modifier. The result is
    /// `Sendable` and can be stored in `@State` on the main actor.
    @concurrent
    public static func parseAsync(_ markdown: String) async -> [MarkdownBlock] {
        let doc = Document(parsing: markdown)
        return doc.children.map { parse($0) }
    }

    /// Parses a single `Markup` node into a `MarkdownBlock`.
    public static func parse(_ markup: any Markup) -> MarkdownBlock {
        switch markup {
        case let h as Heading:
            return .heading(level: h.level, inlines: InlineParser.parse(h))

        case let p as Paragraph:
            return .paragraph(inlines: InlineParser.parse(p))

        case let ol as OrderedList:
            let items: [[MarkdownBlock]] = ol.listItems.map { item in
                Array(item.children.map { parse($0) })
            }
            return .orderedList(items: items, startIndex: Int(ol.startIndex))

        case let ul as UnorderedList:
            let items: [[MarkdownBlock]] = ul.listItems.map { item in
                Array(item.children.map { parse($0) })
            }
            return .unorderedList(items: items)

        case let bq as BlockQuote:
            return .blockQuote(blocks: Array(bq.children.map { parse($0) }))

        case let cb as CodeBlock:
            let lang = cb.language.flatMap { $0.isEmpty ? nil : $0 }
            return .codeBlock(code: cb.code, language: lang)

        case is ThematicBreak:
            return .thematicBreak

        case let t as Markdown.Table:
            return .table(model: MarkdownTableModel(table: t))

        default:
            return .unknown(plainText: extractPlainText(from: markup))
        }
    }
}

// MARK: - PlainTextWalker

/// Best-effort plain-text extractor for unknown / unsupported node types.
///
/// Entry point is the free function `extractPlainText(from:)` — avoids any
/// method-name collision with `PlainTextConvertibleMarkup.collect(plainText:)`
/// from the swift-markdown module.
private struct PlainTextWalker: MarkupWalker {
    private(set) var result = ""

    mutating func visitText(_ text: Markdown.Text) {
        result += text.string
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += inlineCode.code
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
    }

    mutating func visitInlineHTML(_ html: InlineHTML) {
        result += html.rawHTML
    }
}

/// Extracts best-effort plain text from any `Markup` node.
private func extractPlainText(from markup: any Markup) -> String {
    var walker = PlainTextWalker()
    walker.visit(markup)
    return walker.result
}
