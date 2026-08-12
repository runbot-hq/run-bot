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
/// This is a best-effort cache warmer, not part of rendering correctness.
/// It intentionally consumes the top-level normalized block array. Nested code
/// blocks remain correct through MarkdownCodeBlockView's normal cache-miss path.
/// Recursive tree warming is deferred unless profiling shows a real need.
///
/// Cancellation is owned by the calling MarkdownLogView task before and after
/// this phase. An individual Highlightr call is synchronous and cannot be
/// interrupted once started.
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
