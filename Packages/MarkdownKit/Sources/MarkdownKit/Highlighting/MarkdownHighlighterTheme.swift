// MarkdownHighlighterTheme.swift
// RunBot
//
// highlight.js theme name constants used by MarkdownHighlighter.
// Both themes have neutral/transparent backgrounds that sit cleanly
// on top of surfaceElevated without colour clash.
import Foundation

/// highlight.js theme names used by `MarkdownHighlighter`.
public enum MarkdownHighlighterTheme {
    /// Light-mode theme — Xcode-inspired, neutral background.
    public static let light = "xcode"
    /// Dark-mode theme — Atom One Dark, pairs well with surfaceElevated.
    public static let dark = "atom-one-dark"
}
