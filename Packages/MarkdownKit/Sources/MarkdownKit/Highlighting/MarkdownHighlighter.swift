// MarkdownHighlighter.swift
// RunBot
//
// @MainActor singleton wrapping Highlightr's JavaScriptCore engine.
// One JSContext is created at init (~50-150 ms); all subsequent calls are cheap.
// Bounded LRU cache (100 entries) prevents unbounded memory growth on large logs.
import AppKit
import Highlightr
import SwiftUI

/// Caching wrapper around `Highlightr` for use inside `MarkdownCodeBlockView`.
///
/// Call `highlight(_:language:colorScheme:)` from any `@MainActor` context.
/// Returns `nil` on unknown language or highlight failure; callers must fall back
/// to plain text rendering in that case.
@MainActor
public final class MarkdownHighlighter {

    // MARK: Shared instance

    /// Shared singleton. JSContext cold-start happens once at first access.
    public static let shared = MarkdownHighlighter()

    // MARK: Private state

    private let highlightr: Highlightr?
    private var cache: [(key: CacheKey, value: AttributedString)] = []
    private let cacheLimit = 100
    private var currentTheme: String = ""

    // MARK: Cache key

    private struct CacheKey: Equatable {
        let content: String
        let language: String
        let colorScheme: ColorScheme
    }

    // MARK: Init

    private init() {
        highlightr = Highlightr()
        highlightr?.setTheme(to: MarkdownHighlighterTheme.light)
        currentTheme = MarkdownHighlighterTheme.light
    }

    // MARK: Public API

    /// Returns a syntax-highlighted `AttributedString` for `code`, or `nil` on failure.
    ///
    /// - Parameters:
    ///   - code: Raw source code string.
    ///   - language: highlight.js language identifier. Pass `"plaintext"` when unknown.
    ///   - colorScheme: Current `ColorScheme`; drives theme selection.
    public func highlight(
        _ code: String,
        language: String,
        colorScheme: ColorScheme
    ) -> AttributedString? {
        let key = CacheKey(content: code, language: language, colorScheme: colorScheme)
        if let hit = cache.first(where: { $0.key == key }) { return hit.value }

        let theme = colorScheme == .dark ? MarkdownHighlighterTheme.dark : MarkdownHighlighterTheme.light
        guard let h = highlightr else { return nil }
        if theme != currentTheme {
            h.setTheme(to: theme)
            currentTheme = theme
        }

        guard let nsAttr = h.highlight(code, as: language) else { return nil }
        // Do NOT bake a fixed font into the AttributedString — callers apply
        // `.font(style.monoFont)` as a SwiftUI modifier so custom sizes are respected.
        guard let attributed = try? AttributedString(
            nsAttr,
            including: AttributeScopes.AppKitAttributes.self
        ) else { return nil }

        if cache.count >= cacheLimit { cache.removeFirst() }
        cache.append((key, attributed))
        return attributed
    }
}
