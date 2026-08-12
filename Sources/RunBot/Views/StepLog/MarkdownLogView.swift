// MarkdownLogView.swift
// RunBot
//
// Integration boundary between RunBot and MarkdownKit.
// Rendering surface: `MarkdownDocumentView(markdown:style:)` from the internal
// MarkdownKit package. `MarkdownStyle.runBot` maps RunBot design tokens.
//
// Tranche 9 complete (ref #2600):
//   [x] Deleted Theme+RunBot.swift
//   [x] Removed MarkdownUI product from RunBot target in Package.swift
//   [x] Removed swift-markdown-ui from Package.swift dependencies
import MarkdownKit
import SwiftUI

/// Renders a Markdown string inside RunBot’s step log.
///
/// Must live inside `StepLogView`’s existing `ScrollView` — never as a
/// parallel scroll container. `MarkdownDocumentView` uses a plain `VStack`
/// internally with no wrapping scroll view.
struct MarkdownLogView: View {
    /// The markdown string to render.
    let text: String

    /// Current colour scheme — passed to `preWarmMarkdownHighlighter` for theme selection.
    @Environment(\.colorScheme) private var colorScheme

    /// The rendered view.
    var body: some View {
        MarkdownDocumentView(markdown: text, style: .runBot)
            .textSelection(.enabled)
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
            .onAppear {
                preWarmMarkdownHighlighter(text: text, colorScheme: colorScheme)
            }
    }
}
