// HighlightrTheme+RunBot.swift
// RunBot
//
// highlight.js theme name constants for HighlightrService.
// Both themes have neutral/transparent backgrounds that sit cleanly
// on top of `rbSurfaceElevated` without colour clash.
// Verify in both light and dark mode before shipping any custom theme.
import Foundation

/// highlight.js theme names used by `HighlightrService`.
///
/// Both are built-in themes shipped with the Highlightr bundle.
/// If a custom theme matching RunBot design tokens is needed, add a `.json`
/// file to `Resources/` and reference it here — defer to a follow-up.
enum HighlightrTheme {
    /// Light-mode theme — Xcode-inspired, neutral background.
    static let light = "xcode"
    /// Dark-mode theme — Atom One Dark, pairs well with `rbSurfaceElevated`.
    static let dark = "atom-one-dark"
}
