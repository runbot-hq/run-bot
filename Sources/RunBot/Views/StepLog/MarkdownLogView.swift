// MarkdownLogView.swift
// RunBot
//
// Integration boundary between RunBot and MarkdownKit.
// Rendering surface: `MarkdownDocumentView(blocks:style:)` from the
// runbot-hq/MarkdownKit package. `MarkdownStyle.runBot` maps RunBot design tokens.
//
// Tranche 9 complete (ref #2600):
//   [x] Deleted Theme+RunBot.swift
//   [x] Removed MarkdownUI product from RunBot target in Package.swift
//   [x] Removed swift-markdown-ui from Package.swift dependencies
import MarkdownKit
import OSLog
import SwiftUI

/// OSLog logger for MarkdownKit render events scoped to `MarkdownRender` category.
private let markdownRenderLogger = Logger(
    subsystem: "com.runbot-hq.RunBot",
    category: "MarkdownRender"
)

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
        VStack(alignment: .leading, spacing: 0) {
            if let blocks {
                MarkdownDocumentView(blocks: blocks, style: .runBot)
                    .textSelection(.enabled)
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.vertical, 8)
                    .onAppear {
                        markdownRenderLogger.notice(
                            "document appeared blocks=\(blocks.count, privacy: .public)"
                        )
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: text) {
            await renderMarkdown()
        }
        .onAppear {
            markdownRenderLogger.notice(
                "MarkdownLogView appeared chars=\(text.count, privacy: .public)"
            )
        }
        .onDisappear {
            markdownRenderLogger.notice("MarkdownLogView disappeared")
        }
    }

    // MARK: - Private

    /// Parses and renders `text` off the main actor, then publishes the result to `blocks`.
    private func renderMarkdown() async {
        let renderID = UUID().uuidString.prefix(8)
        let lineCount = text.components(separatedBy: "\n").count
        let schemeName = colorScheme == .dark ? "dark" : "light"

        markdownRenderLogger.notice("[\(renderID, privacy: .public)] task started chars=\(text.count) lines=\(lineCount) scheme=\(schemeName, privacy: .public)")

        // Clear stale blocks immediately so the previous log is not shown
        // while the new one parses. parseAsync hops off-main via @concurrent.
        blocks = nil

        let parseStart = ContinuousClock.now
        let parsed = await BlockParser.parseAsync(text)
        let parseDuration = parseStart.duration(to: .now)
        let parseDurationText = String(describing: parseDuration)

        markdownRenderLogger.notice("[\(renderID, privacy: .public)] parse completed blocks=\(parsed.count) duration=\(parseDurationText, privacy: .public) cancelled=\(Task.isCancelled)")

        for (index, block) in parsed.enumerated() {
            markdownRenderLogger.debug("[\(renderID, privacy: .public)] parsed block index=\(index, privacy: .public) kind=\(block.renderLogKind, privacy: .public)")
        }

        if parsed.isEmpty, !text.isEmpty {
            markdownRenderLogger.error(
                "[\(renderID, privacy: .public)] parser returned zero blocks for non-empty input"
            )
        }

        guard !Task.isCancelled else {
            markdownRenderLogger.notice(
                "[\(renderID, privacy: .public)] cancelled after parse"
            )
            return
        }

        let prewarmStart = ContinuousClock.now

        markdownRenderLogger.notice("[\(renderID, privacy: .public)] prewarm started blocks=\(parsed.count, privacy: .public)")

        // Intentional ordering: MarkdownDocumentView uses a non-lazy VStack and
        // MarkdownCodeBlockView highlights synchronously on a cache miss. Publishing
        // blocks before prewarming would move the same JSCore work into View.body;
        // it would not produce an earlier usable render. Revisit only with measured
        // evidence and an asynchronous code-block rendering design.
        await preWarmHighlighter(blocks: parsed, colorScheme: colorScheme)

        let prewarmDuration = prewarmStart.duration(to: .now)
        let prewarmDurationText = String(describing: prewarmDuration)

        markdownRenderLogger.notice("[\(renderID, privacy: .public)] prewarm completed duration=\(prewarmDurationText, privacy: .public) cancelled=\(Task.isCancelled)")

        guard !Task.isCancelled else {
            markdownRenderLogger.notice(
                "[\(renderID, privacy: .public)] cancelled after prewarm"
            )
            return
        }

        blocks = parsed

        markdownRenderLogger.notice("[\(renderID, privacy: .public)] blocks published count=\(parsed.count, privacy: .public)")
    }
}
