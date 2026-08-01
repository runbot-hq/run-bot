// MarkdownLogView.swift
// RunBot
import MarkdownView
import SwiftUI

/// Renders a markdown string using `LiYanan2004/MarkdownView`,
/// themed to match RunBot's design tokens via environment modifiers.
///
/// Must live **inside** `StepLogView`'s existing `ScrollView` — never as a
/// parallel scroll container. `MarkdownView` renders inline without its own
/// scroll container by default, but verify against the library source before
/// shipping (nested scroll views on macOS silently break scroll behaviour).
/// If it does wrap in a ScrollView, apply `.scrollDisabled(true)`. (§6 of #2394)
///
/// - Note: `LiYanan2004/MarkdownView` re-parses `text` async/lazily on render,
///   so this does not block the main thread — but confirm against the actual
///   library implementation before shipping. (§5 of #2394)
struct MarkdownLogView: View {
    /// The markdown string to render.
    let text: String

    /// The rendered view — `MarkdownView` themed to RunBot design tokens.
    var body: some View {
        MarkdownView(text)
            .markdownFontGroup(RunBotMarkdownFontGroup())
            .markdownCodeBlockStyle(.default())
            .textSelection(.enabled)
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
    }
}
