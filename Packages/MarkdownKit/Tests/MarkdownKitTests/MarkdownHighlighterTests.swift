// MarkdownHighlighterTests.swift
// RunBot
import Testing
import AppKit
import SwiftUI
@testable import MarkdownKit

/// Smoke tests for syntax highlighting, theme switching, and font normalization.
@Suite("MarkdownHighlighter")
@MainActor
struct MarkdownHighlighterTests {

    /// Representative Swift source used by the highlighting tests.
    private let swiftSource = #"let greeting = "Hello, Markdown!""#

    /// Verifies a recognized language produces highlighted output without data loss.
    @Test("highlights Swift source")
    func highlightsSwiftSource() throws {
        let highlighted = try #require(
            MarkdownHighlighter.shared.highlight(swiftSource, language: "swift", colorScheme: .light)
        )
        #expect(String(highlighted.characters) == swiftSource)
    }

    /// Verifies the shared highlighter supports switching between both color schemes.
    @Test("supports light and dark themes")
    func supportsLightAndDarkThemes() {
        let light = MarkdownHighlighter.shared.highlight(swiftSource, language: "swift", colorScheme: .light)
        let dark = MarkdownHighlighter.shared.highlight(swiftSource, language: "swift", colorScheme: .dark)
        let lightAgain = MarkdownHighlighter.shared.highlight(swiftSource, language: "swift", colorScheme: .light)
        #expect(light != nil)
        #expect(dark != nil)
        #expect(lightAgain != nil)
    }

    /// Verifies Highlightr's embedded font attributes are removed from every run.
    @Test("strips embedded AppKit font attributes")
    func stripsEmbeddedFontAttributes() throws {
        let highlighted = try #require(
            MarkdownHighlighter.shared.highlight(swiftSource, language: "swift", colorScheme: .light)
        )
        let bridged = NSAttributedString(highlighted)
        var containsFontAttribute = false
        bridged.enumerateAttribute(.font, in: NSRange(location: 0, length: bridged.length)) { value, _, _ in
            if value != nil { containsFontAttribute = true }
        }
        #expect(!containsFontAttribute)
    }
}