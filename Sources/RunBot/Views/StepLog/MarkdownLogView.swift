// MarkdownLogView.swift
// RunBot
import MarkdownView
import SwiftUI

/// Renders a markdown string using `LiYanan2004/MarkdownView`,
/// themed to match RunBot's design tokens via environment modifiers.
///
/// Must live **inside** `StepLogView`'s existing `ScrollView` — never as a
/// parallel scroll container.
///
/// ✅ Scroll audit complete — verified against `LiYanan2004/MarkdownView@454625f`:
/// `MarkdownView.body` returns `MarkdownViewRenderer` directly with no `ScrollView`
/// wrapper. Safe to embed here without `.scrollDisabled(true)`.
/// The `#Preview` in `MarkdownView.swift` wraps in `ScrollView` to demonstrate
/// intended usage — that is caller convention, not a component requirement.
/// `DefaultCodeBlockStyle` uses `ScrollView(.horizontal)` for code blocks only —
/// horizontal-axis only, does not interfere with vertical scroll in the parent.
/// No action needed unless the library is updated to a new revision — re-verify
/// `MarkdownView.swift` body after any revision bump.
///
/// - Note: `LiYanan2004/MarkdownView` re-parses `text` on render via an internal
///   async path. Main thread is not blocked. Verified against `@454625f`.
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
