// HighlightrPrewarmer.swift
// RunBot
//
// Free function that pre-warms the HighlightrService cache for all code
// blocks in a markdown document. Uses MarkdownDetector.codeBlocks(in:)
// (from RunBotCore) so this file does NOT need to import Markdown —
// avoiding the type-checker complexity crash in StepLogView.swift.
import RunBotCore
import SwiftUI

/// Pre-warms `HighlightrService` for every code block found in `text`.
///
/// Called from `StepLogView` after `isMarkdownMode` is set to `true`.
func preWarmHighlightr(text: String, colorScheme: ColorScheme) {
    Task(priority: .utility) {
        let blocks = MarkdownDetector.codeBlocks(in: text)
        for block in blocks {
            _ = await HighlightrService.shared.highlight(
                block.code,
                language: block.language?.isEmpty == false
                    ? block.language!
                    : "plaintext",
                colorScheme: colorScheme
            )
        }
    }
}
