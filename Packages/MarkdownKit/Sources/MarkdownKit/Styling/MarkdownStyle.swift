// MarkdownStyle.swift
// MarkdownKit
//
// Rendering tokens consumed by all MarkdownKit views.
// Must NOT reference any RunBot-specific symbol (RBFont, RBSpacing, etc.).
// RunBot maps its design tokens onto this struct via MarkdownStyle+RunBot.swift
// inside the RunBot target.
import SwiftUI

// MARK: - Heading style value types

/// Per-level heading typography, colour, and spacing.
public struct MarkdownHeadingStyle: Sendable {
    public var font: Font
    public var color: Color
    public var topSpacing: CGFloat
    public var bottomSpacing: CGFloat

    public init(
        font: Font,
        color: Color,
        topSpacing: CGFloat,
        bottomSpacing: CGFloat
    ) {
        self.font = font
        self.color = color
        self.topSpacing = topSpacing
        self.bottomSpacing = bottomSpacing
    }
}

/// Fixed six-slot container so a missing level is impossible at runtime.
public struct MarkdownHeadingStyles: Sendable {
    public var h1: MarkdownHeadingStyle
    public var h2: MarkdownHeadingStyle
    public var h3: MarkdownHeadingStyle
    public var h4: MarkdownHeadingStyle
    public var h5: MarkdownHeadingStyle
    public var h6: MarkdownHeadingStyle

    public init(
        h1: MarkdownHeadingStyle,
        h2: MarkdownHeadingStyle,
        h3: MarkdownHeadingStyle,
        h4: MarkdownHeadingStyle,
        h5: MarkdownHeadingStyle,
        h6: MarkdownHeadingStyle
    ) {
        self.h1 = h1
        self.h2 = h2
        self.h3 = h3
        self.h4 = h4
        self.h5 = h5
        self.h6 = h6
    }

    func style(for level: Int) -> MarkdownHeadingStyle {
        switch level {
        case 1: return h1
        case 2: return h2
        case 3: return h3
        case 4: return h4
        case 5: return h5
        default: return h6
        }
    }
}

// MARK: - MarkdownStyle

/// Focused style token bag for MarkdownKit renderers.
///
/// Callers construct a value and pass it to `MarkdownDocumentView(markdown:style:)`.
/// RunBot defines `MarkdownStyle.runBot` in its own target by mapping existing
/// design tokens. Do not grow this into a generic theme DSL.
public struct MarkdownStyle: Sendable {
    // MARK: Typography
    public var baseFont: Font
    public var monoFont: Font
    /// Small label font used for language tags above code blocks.
    public var labelFont: Font

    // MARK: Colours
    public var textPrimary: Color
    public var textSecondary: Color
    public var textTertiary: Color
    public var accent: Color
    public var surfaceElevated: Color
    public var borderSubtle: Color

    // MARK: Geometry
    public var radiusSmall: CGFloat
    public var spacingXS: CGFloat
    public var spacingSM: CGFloat
    public var spacingMD: CGFloat

    // MARK: Headings
    public var headings: MarkdownHeadingStyles

    // MARK: Paragraph
    public var paragraphTextColor: Color
    public var blockBottomSpacing: CGFloat

    // MARK: Inline code
    public var inlineCodeBackground: Color

    // MARK: Blockquote
    public var blockQuoteFont: Font
    public var blockQuoteTextColor: Color
    public var blockQuoteBorderWidth: CGFloat
    public var blockQuoteHorizontalPadding: CGFloat

    // MARK: Lists
    public var listItemSpacing: CGFloat

    // MARK: Tables
    public var tableFont: Font

    // MARK: Code blocks
    public var codeBlockLineSpacing: CGFloat

    // MARK: Links
    public var showsLinkUnderline: Bool

    public init(
        baseFont: Font = .system(size: 12),
        monoFont: Font = .system(size: 11, design: .monospaced),
        labelFont: Font = .system(size: 10),
        textPrimary: Color = .primary,
        textSecondary: Color = .secondary,
        textTertiary: Color = .secondary,
        accent: Color = .accentColor,
        surfaceElevated: Color = Color(nsColor: .windowBackgroundColor),
        borderSubtle: Color = Color(nsColor: .separatorColor),
        radiusSmall: CGFloat = 4,
        spacingXS: CGFloat = 4,
        spacingSM: CGFloat = 6,
        spacingMD: CGFloat = 12,
        headings: MarkdownHeadingStyles = .init(
            h1: .init(font: .system(size: 14, weight: .bold),     color: .primary, topSpacing: 16, bottomSpacing: 8),
            h2: .init(font: .system(size: 13, weight: .semibold), color: .primary, topSpacing: 12, bottomSpacing: 6),
            h3: .init(font: .system(size: 12.5, weight: .medium), color: .primary, topSpacing: 10, bottomSpacing: 4),
            h4: .init(font: .system(size: 12.5),                  color: .secondary, topSpacing: 6, bottomSpacing: 4),
            h5: .init(font: .system(size: 12.5),                  color: .secondary, topSpacing: 6, bottomSpacing: 4),
            h6: .init(font: .system(size: 12.5),                  color: .secondary, topSpacing: 6, bottomSpacing: 4)
        ),
        paragraphTextColor: Color = .primary,
        blockBottomSpacing: CGFloat = 6,
        inlineCodeBackground: Color = Color(nsColor: .windowBackgroundColor),
        blockQuoteFont: Font = .system(size: 12),
        blockQuoteTextColor: Color = .secondary,
        blockQuoteBorderWidth: CGFloat = 2,
        blockQuoteHorizontalPadding: CGFloat = 8,
        listItemSpacing: CGFloat = 2,
        tableFont: Font = .system(size: 11),
        codeBlockLineSpacing: CGFloat = 2,
        showsLinkUnderline: Bool = true
    ) {
        self.baseFont = baseFont
        self.monoFont = monoFont
        self.labelFont = labelFont
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.accent = accent
        self.surfaceElevated = surfaceElevated
        self.borderSubtle = borderSubtle
        self.radiusSmall = radiusSmall
        self.spacingXS = spacingXS
        self.spacingSM = spacingSM
        self.spacingMD = spacingMD
        self.headings = headings
        self.paragraphTextColor = paragraphTextColor
        self.blockBottomSpacing = blockBottomSpacing
        self.inlineCodeBackground = inlineCodeBackground
        self.blockQuoteFont = blockQuoteFont
        self.blockQuoteTextColor = blockQuoteTextColor
        self.blockQuoteBorderWidth = blockQuoteBorderWidth
        self.blockQuoteHorizontalPadding = blockQuoteHorizontalPadding
        self.listItemSpacing = listItemSpacing
        self.tableFont = tableFont
        self.codeBlockLineSpacing = codeBlockLineSpacing
        self.showsLinkUnderline = showsLinkUnderline
    }
}
