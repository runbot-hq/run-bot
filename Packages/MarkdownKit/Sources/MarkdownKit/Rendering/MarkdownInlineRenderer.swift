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
        // Unsupported inline HTML is preserved as literal readable text.
        // It is intentionally not interpreted or rendered as HTML (#2600 non-goal).
        case let html as InlineHTML:
            return .unknown(html.rawHTML)
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

/// Renders a `[InlineNode]` array as a single SwiftUI `Text`.
///
/// Builds an `AttributedString` incrementally so that per-run formatting
/// (bold, italic, strikethrough, colour, font) is fully expressed without
/// relying on the `Text +` concatenation operator, which is deprecated on
/// macOS 26 in favour of string interpolation.
@MainActor
public struct InlineTextView: View {
    /// The inline nodes to render as a single attributed `Text`.
    public let inlines: [InlineNode]
    /// Style tokens controlling fonts and colours.
    public let style: MarkdownStyle

    /// Creates an inline text view for the given inline nodes and style.
    public init(inlines: [InlineNode], style: MarkdownStyle) {
        self.inlines = inlines
        self.style = style
    }

    /// SwiftUI view body — see type-level doc for rendering contract.
    public var body: some View {
        SwiftUI.Text(attributedString(for: inlines))
    }

    // MARK: Private

    /// Recursively builds an `AttributedString` for the given inline nodes.
    private func attributedString(for nodes: [InlineNode]) -> AttributedString {
        nodes.reduce(into: AttributedString()) { result, node in
            result += attributed(node)
        }
    }

    /// Unions `intent` into every run of the rendered children rather than
    /// overwriting, so nested emphasis (e.g. `***bold italic***`) keeps both
    /// `.stronglyEmphasized` and `.emphasized` on the same run.
    private func addingIntent(
        _ intent: InlinePresentationIntent,
        to children: [InlineNode]
    ) -> AttributedString {
        var result = attributedString(for: children)
        let runs = result.runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
        for (range, existing) in runs {
            result[range].inlinePresentationIntent = existing.union(intent)
        }
        return result
    }

    /// Converts a single `InlineNode` into an `AttributedString` run.
    private func attributed(_ node: InlineNode) -> AttributedString {
        switch node {
        case .text(let s):
            return AttributedString(s)

        case .softBreak:
            return AttributedString(" ")

        case .lineBreak:
            return AttributedString("\n")

        case .code(let s):
            var a = AttributedString(s)
            a.swiftUI.font = style.monoFont
            a.swiftUI.foregroundColor = style.textSecondary
            a.swiftUI.backgroundColor = style.inlineCodeBackground
            return a

        case .strong(let children):
            return addingIntent(.stronglyEmphasized, to: children)

        case .emphasis(let children):
            return addingIntent(.emphasized, to: children)

        case .strikethrough(let children):
            var a = attributedString(for: children)
            a.strikethroughStyle = .single
            return a

        case .link(let destination, let children):
            var a = attributedString(for: children)
            // Only make http/https links actionable. Markdown here comes from
            // untrusted CI log output; permitting file://, runbot://, or other
            // registered schemes would let log content dispatch arbitrary
            // system actions on click.
            if let url = URL(string: destination),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                a.link = url
            }
            a.swiftUI.foregroundColor = style.accent
            if !style.showsLinkUnderline {
                a.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: .clear)
            }
            return a

        case .unknown(let s):
            return AttributedString(s)
        }
    }
}
