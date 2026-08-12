// MarkdownInlineRenderer.swift
// RunBot
import Markdown
import SwiftUI

// MARK: - InlineParser

/// Converts `swift-markdown` inline AST nodes into `[InlineNode]`.
public enum InlineParser {

    /// Parses the direct children of any `Markup` node as inline nodes.
    public static func parse(_ markup: any Markup) -> [InlineNode] {
        markup.children.compactMap { node(from: $0) }
    }

    static func node(from markup: any Markup) -> InlineNode? {
        switch markup {
        case let t as Markdown.Text:
            return .text(t.string)
        case is SoftBreak:
            return .softBreak
        case is LineBreak:
            return .lineBreak
        case let c as InlineCode:
            return .code(c.code)
        case let s as Strong:
            return .strong(parse(s))
        case let e as Emphasis:
            return .emphasis(parse(e))
        case let st as Strikethrough:
            return .strikethrough(parse(st))
        case let l as Markdown.Link:
            return .link(destination: l.destination ?? "", inlines: parse(l))
        default:
            // Unknown inline container: preserve children without inventing emphasis styling.
            // Leaf nodes with no children (e.g. Image alt-text holder) return nil silently.
            let children = parse(markup)
            if children.isEmpty { return nil }
            return .unknown(children.map { node -> String in
                switch node {
                case .text(let s), .code(let s), .unknown(let s): return s
                case .softBreak: return " "
                case .lineBreak: return "\n"
                case .strong(let c), .emphasis(let c), .strikethrough(let c), .link(_, let c):
                    return c.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined()
                }
            }.joined())
        }
    }
}

// MARK: - InlineTextView

/// Renders a `[InlineNode]` array as a single SwiftUI `Text` by joining.
///
/// Uses a recursive `joined(_:)` helper instead of `Text +` concatenation
/// because the `+` operator is deprecated on macOS 26.
@MainActor
public struct InlineTextView: View {
    public let inlines: [InlineNode]
    public let style: MarkdownStyle

    public init(inlines: [InlineNode], style: MarkdownStyle) {
        self.inlines = inlines
        self.style = style
    }

    public var body: some View {
        joined(inlines)
    }

    // MARK: Private

    /// Recursively joins an array of `InlineNode` into a single `Text`.
    ///
    /// Uses `Text` concatenation via `+` which is deprecated on macOS 26 in favour
    /// of string interpolation. String interpolation cannot carry per-run formatting
    /// (bold, italic, colour) so `+` is intentional here.
    /// swiftlint:disable:next no_grouping_extension
    private func joined(_ nodes: [InlineNode]) -> SwiftUI.Text {
        // swiftlint:disable:next operator_usage_whitespace
        var out = SwiftUI.Text(verbatim: "")
        for node in nodes { out = out + rendered(node) } // swiftlint:disable:this operator_usage_whitespace
        return out
    }

    /// Flattens an `[InlineNode]` array to plain text for use in `AttributedString`
    /// contexts where rich formatting cannot be carried (e.g. link labels).
    private func inlinePlainText(_ nodes: [InlineNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let s), .code(let s), .unknown(let s): return s
            case .softBreak: return " "
            case .lineBreak: return "\n"
            case .strong(let c), .emphasis(let c), .strikethrough(let c), .link(_, let c):
                return inlinePlainText(c)
            }
        }.joined()
    }

    private func rendered(_ node: InlineNode) -> SwiftUI.Text {
        switch node {
        case .text(let s):
            return SwiftUI.Text(verbatim: s)
        case .softBreak:
            return SwiftUI.Text(verbatim: " ")
        case .lineBreak:
            return SwiftUI.Text(verbatim: "\n")
        case .code(let s):
            return SwiftUI.Text(verbatim: s)
                .font(style.monoFont)
                .foregroundColor(style.textSecondary)
        case .strong(let children):
            return joined(children).bold()
        case .emphasis(let children):
            return joined(children).italic()
        case .strikethrough(let children):
            return joined(children).strikethrough()
        case .link(let destination, let children):
            if let url = URL(string: destination), !destination.isEmpty {
                // Build visible label as plain text, attach the URL so the link
                // is actionable. Formatting inside the label (bold, italic) is
                // intentionally flattened — nested rich links are rare in CI logs.
                var attr = AttributedString(inlinePlainText(children))
                attr.link = url
                attr.foregroundColor = style.accent
                return SwiftUI.Text(attr)
            }
            return joined(children).foregroundColor(style.accent)
        case .unknown(let s):
            return SwiftUI.Text(verbatim: s)
        }
    }
}
