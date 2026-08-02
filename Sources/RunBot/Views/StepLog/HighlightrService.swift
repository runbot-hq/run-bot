// HighlightrService.swift
// RunBot
//
// @MainActor singleton that wraps Highlightr's JavaScriptCore engine.
// One JSContext is created at init (~50–150 ms); all subsequent calls are cheap.
// A bounded LRU cache (100 entries) prevents unbounded memory growth on large logs.
import AppKit
import Highlightr
import SwiftUI

/// Caching wrapper around `Highlightr` for use inside `CodeBlockView`.
///
/// Call `highlight(_:language:colorScheme:)` from any `@MainActor` context.
/// Returns `nil` on unknown language or highlight failure; callers must fall back
/// to plain text rendering in that case.
@MainActor
final class HighlightrService {
    // MARK: Shared instance

    /// Shared singleton. JSContext cold-start happens once at first access.
    static let shared = HighlightrService()

    // MARK: Private state

    /// Underlying `Highlightr` instance. `nil` when JSContext fails to initialise.
    private let highlightr: Highlightr?
    /// LRU cache — newest entry at the back, oldest evicted from the front.
    private var cache: [(key: CacheKey, value: AttributedString)] = []
    /// Maximum number of entries before the oldest is evicted.
    private let cacheLimit = 100

    // MARK: Init

    /// Private init — use `shared`. Triggers JSContext cold-start once.
    private init() {
        highlightr = Highlightr()
        highlightr?.setTheme(to: HighlightrTheme.light)
    }

    // MARK: Cache key

    /// Equatable cache key combining code content, language tag, and colour scheme.
    private struct CacheKey: Equatable {
        /// Raw source code string.
        let content: String
        /// highlight.js language identifier.
        let language: String
        /// Light or dark — drives theme selection.
        let colorScheme: ColorScheme
    }

    // MARK: Public API

    /// Returns a syntax-highlighted `AttributedString` for `code`, or `nil` on failure.
    ///
    /// - Parameters:
    ///   - code: Raw source code string.
    ///   - language: highlight.js language identifier (e.g. `"swift"`, `"python"`).
    ///     Pass `"plaintext"` when the language is unknown — never pass an empty string.
    ///   - colorScheme: Current `ColorScheme`; drives theme selection.
    /// - Returns: Highlighted `AttributedString`, or `nil` when Highlightr fails or
    ///   the language is unrecognised.
    func highlight(
        _ code: String,
        language: String,
        colorScheme: ColorScheme
    ) -> AttributedString? {
        let key = CacheKey(content: code, language: language, colorScheme: colorScheme)
        if let hit = cache.first(where: { $0.key == key }) { return hit.value }

        let theme = colorScheme == .dark ? HighlightrTheme.dark : HighlightrTheme.light
        guard let highlightr else { return nil }
        highlightr.setTheme(to: theme)

        guard
            let nsAttr = highlightr.highlight(code, as: language),
            let attributed = try? AttributedString(nsAttr, including: AttributeScopes.AppKitAttributes.self)
        else { return nil }

        if cache.count >= cacheLimit { cache.removeFirst() }
        cache.append((key, attributed))
        return attributed
    }
}
