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

    /// Current colour scheme — passed to `preWarmHighlightr` for theme selection.
    @Environment(\.colorScheme) private var colorScheme

    /// The rendered view — `Markdown` themed to RunBot design tokens.
    var body: some View {
        Markdown(text)
            .markdownTheme(.runBot)
            .textSelection(.enabled)
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
            .onAppear {
                // Pre-warm HighlightrService cache as soon as the markdown view
                // appears. CodeBlockView calls HighlightrService synchronously on
                // the main actor; if the cache is already warm the highlight is
                // instant. Pre-warming here (rather than in loadLog) avoids
                // touching StepLogView's large Task closure which hits the Swift
                // type-checker complexity limit when Highlightr is in the module.
                preWarmHighlightr(text: text, colorScheme: colorScheme)
            }
    }
}
