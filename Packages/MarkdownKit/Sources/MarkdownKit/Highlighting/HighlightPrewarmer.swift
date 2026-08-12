// HighlightPrewarmer.swift
// RunBot
//
// Pre-warms MarkdownHighlighter cache using already-parsed [MarkdownBlock].
// No Document(parsing:) call here — the caller owns the parse lifecycle.
import SwiftUI

/// Pre-warms `MarkdownHighlighter` for every `.codeBlock` in `blocks`.
///
/// Call this inside the same background `Task` that produces the blocks, so
/// highlighting is warm before the view renders for the first time.
///
/// - Parameters:
///   - blocks: Pre-parsed block model from `BlockParser.parseAsync`.
///   - colorScheme: Current colour scheme; drives theme selection.
nonisolated public func preWarmHighlighter(
    blocks: [MarkdownBlock],
    colorScheme: ColorScheme
) async {
    for block in blocks {
        guard case .codeBlock(let code, let lang) = block else { continue }
        let language = lang.flatMap { $0.isEmpty ? nil : $0 } ?? "plaintext"
        _ = await MarkdownHighlighter.shared.highlight(
            code,
            language: language,
            colorScheme: colorScheme
        )
    }
}
