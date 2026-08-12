// MarkdownBlock.swift
// RunBot
import Markdown
import Foundation

/// Normalised representation of a single top-level Markdown block.
///
/// Built by walking `Document.children` once; consumed by `MarkdownBlockView`.
///
/// Public because RunBot stores `[MarkdownBlock]` in `@State` after the
/// package-owned asynchronous parse. This is a cross-package transport model,
/// not an extension or custom-node API.
public enum MarkdownBlock: Sendable {
    case heading(level: Int, inlines: [InlineNode])
    case paragraph(inlines: [InlineNode])
    case orderedList(items: [[MarkdownBlock]], startIndex: Int)
    case unorderedList(items: [[MarkdownBlock]])
    case blockQuote(blocks: [MarkdownBlock])
    case codeBlock(code: String, language: String?)
    case thematicBreak
    case table(model: MarkdownTableModel)
    case unknown(plainText: String)
}

/// A single inline node in a paragraph or heading.
///
/// Public only because it is associated data of the public MarkdownBlock and
/// MarkdownTableModel value graph. Callers should not construct a parallel AST
/// or use this as an extension mechanism.
public indirect enum InlineNode: Sendable {
    case text(String)
    case softBreak
    case lineBreak
    case code(String)
    case strong([InlineNode])
    case emphasis([InlineNode])
    case strikethrough([InlineNode])
    case link(destination: String, inlines: [InlineNode])
    case unknown(String)
}
