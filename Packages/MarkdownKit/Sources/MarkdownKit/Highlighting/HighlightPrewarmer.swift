// HighlightPrewarmer.swift
// MarkdownKit
//
// Pre-warms MarkdownHighlighter cache for all code blocks in a document.
// Uses MarkdownDetector.codeBlocks(in:) so this file does not need to
// call Document(parsing:) a second time.
import SwiftUI

/// Pre-warms `MarkdownHighlighter` for every code block found in `text`.
///
/// Call from `MarkdownDocumentView.onAppear` or from the host view after
/// `isMarkdownMode` is set to `true`.
@MainActor
public func preWarmMarkdownHighlighter(text: String, colorScheme: ColorScheme) {
    Task(priority: .utility) {
        let blocks = MarkdownDetector.codeBlocks(in: text)
        for block in blocks {
            let lang = block.language.flatMap { $0.isEmpty ? nil : $0 } ?? "plaintext"
            _ = await MarkdownHighlighter.shared.highlight(
                block.code,
                language: lang,
                colorScheme: colorScheme
            )
        }
    }
}
