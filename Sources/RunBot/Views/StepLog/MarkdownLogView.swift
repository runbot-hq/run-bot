// MarkdownLogView.swift
// RunBot
import MarkdownUI
import SwiftUI

/// Renders a markdown string using `gonzalezreal/swift-markdown-ui`,
/// themed to match RunBot's design tokens via `Theme.runBot`.
///
/// Must live **inside** `StepLogView`'s existing `ScrollView` — never as a
/// parallel scroll container.
///
/// Scroll audit — `swift-markdown-ui@5f61335` (v2.4.1):
/// `Markdown.body` renders via `MarkdownBody` which lays out blocks in a
/// `VStack`-equivalent flow with no wrapping `ScrollView`. Safe to embed
/// here without `.scrollDisabled(true)`.
/// Re-verify `Markdown.swift` body after any revision bump.
struct MarkdownLogView: View {
    /// The markdown string to render.
    let text: String

    /// The rendered view — `Markdown` themed to RunBot design tokens.
    var body: some View {
        Markdown(text)
            .markdownTheme(.runBot)
            .textSelection(.enabled)
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
    }
}
