// MarkdownHighlighter.swift
// RunBot
//
// @MainActor singleton wrapping Highlightr's JavaScriptCore engine.
// One JSContext is created at init (~50-150 ms); all subsequent calls are cheap.
// Bounded FIFO cache (100 entries) prevents unbounded memory growth on large logs.
import AppKit
import Highlightr
import SwiftUI

/// Caching wrapper around `Highlightr` for use inside `MarkdownCodeBlockView`.
///
/// Call `highlight(_:language:colorScheme:)` from any `@MainActor` context.
/// Returns `nil` on unknown language or highlight failure; callers must fall back
/// to plain text rendering in that case.
///
/// Highlightr owns one JavaScriptCore context and all access is intentionally
/// serialized on MainActor to preserve the current synchronous SwiftUI
/// cache-miss contract. Moving it to another actor requires asynchronous
/// code-block rendering and must be justified by profiling.
///
/// The cache is intentionally bounded FIFO rather than LRU. Its linear lookup
/// is capped at 100 entries; maintaining a dictionary plus ordering structure
/// would duplicate state without a demonstrated production bottleneck.
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
        // Strip Highlightr's embedded `.font` attributes before conversion.
        // Highlightr themes bake in ~14–16pt fonts at run level; those AppKit
        // run-level attributes beat the `.font(style.monoFont)` SwiftUI view
        // modifier, producing inconsistent sizes between highlighted blocks and
        // plain-text fallbacks. Retaining syntax colours while removing font
        // attributes lets callers control the final size.
        let mutable = NSMutableAttributedString(attributedString: nsAttr)
        mutable.removeAttribute(
            .font,
            range: NSRange(location: 0, length: mutable.length)
        )
        guard let attributed = try? AttributedString(
            mutable,
            including: AttributeScopes.AppKitAttributes.self
        ) else { return nil }

        if cache.count >= cacheLimit { cache.removeFirst() }
        cache.append((key, attributed))
        return attributed
    }
}
