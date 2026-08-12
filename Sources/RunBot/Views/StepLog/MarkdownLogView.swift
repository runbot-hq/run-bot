// MarkdownLogView.swift
// RunBot
//
// Integration boundary between RunBot and MarkdownKit.
// Rendering surface: `MarkdownDocumentView(blocks:style:)` from the internal
// MarkdownKit package. `MarkdownStyle.runBot` maps RunBot design tokens.
//
// Tranche 9 complete (ref #2600):
//   [x] Deleted Theme+RunBot.swift
//   [x] Removed MarkdownUI product from RunBot target in Package.swift
//   [x] Removed swift-markdown-ui from Package.swift dependencies
import MarkdownKit
import SwiftUI

/// Renders a Markdown string inside RunBot's step log.
///
/// Parsing and highlight prewarming run in a background task keyed on `text`
/// so the main actor is never blocked by `Document(parsing:)`. The view shows
/// nothing until the first parse completes (typically <10 ms for real logs).
///
/// Must live inside `StepLogView`'s existing `ScrollView` — never as a
/// parallel scroll container. `MarkdownDocumentView` uses a plain `VStack`
/// internally with no wrapping scroll view.
struct MarkdownLogView: View {
    /// The markdown string to render.
    let text: String

    /// Current colour scheme — drives highlight theme selection.
    @Environment(\.colorScheme) private var colorScheme

    /// Pre-parsed block model. `nil` while the background parse is in flight.
    @State private var blocks: [MarkdownBlock]?

    /// The rendered view.
    var body: some View {
        Group {
            if let blocks {
                MarkdownDocumentView(blocks: blocks, style: .runBot)
                    .textSelection(.enabled)
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.vertical, 8)
            }
        }
        .task(id: text) {
            // Parse and prewarm off the main actor.
            // task(id:) cancels automatically when text changes or the view disappears.
            let parsed = await BlockParser.parseAsync(text)
            await preWarmHighlighter(blocks: parsed, colorScheme: colorScheme)
            blocks = parsed
        }
    }
}
