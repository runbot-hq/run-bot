// MarkdownStyle.swift
// RunBot
//
// Rendering tokens consumed by all MarkdownKit views.
// Must NOT reference any RunBot-specific symbol (RBFont, RBSpacing, etc.).
// RunBot maps its design tokens onto this struct via MarkdownStyle+RunBot.swift
// inside the RunBot target.
import SwiftUI

// MARK: - Heading style value types

/// Per-level heading typography, colour, and spacing.
public struct MarkdownHeadingStyle: Sendable {
    /// Typeface used for this heading level.
    public var font: Font
    /// Foreground colour for this heading level.
    public var color: Color
    /// Vertical space inserted above the heading.
    public var topSpacing: CGFloat
    /// Vertical space inserted below the heading.
    public var bottomSpacing: CGFloat

    /// Creates a heading style with the given typography and spacing values.
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
    /// Style for first-level headings (`#`).
    public var h1: MarkdownHeadingStyle
    /// Style for second-level headings (`##`).
    public var h2: MarkdownHeadingStyle
    /// Style for third-level headings (`###`).
    public var h3: MarkdownHeadingStyle
    /// Style for fourth-level headings (`####`).
    public var h4: MarkdownHeadingStyle
    /// Style for fifth-level headings (`#####`).
    public var h5: MarkdownHeadingStyle
    /// Style for sixth-level headings (`######`).
    public var h6: MarkdownHeadingStyle

    /// Creates a heading styles container with styles for all six levels.
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
    /// Base proportional font used for body text, paragraphs, and list items.
    public var baseFont: Font
    /// Monospaced font used for inline code and code block content.
    public var monoFont: Font
    /// Small label font used for language tags above code blocks.
    public var labelFont: Font

    // MARK: Colours
    /// Primary text colour used for headings and body content.
    public var textPrimary: Color
    /// Secondary text colour used for captions and de-emphasised content.
    public var textSecondary: Color
    /// Tertiary text colour used for the least prominent labels.
    public var textTertiary: Color
    /// Accent colour used for links and interactive affordances.
    public var accent: Color
    /// Elevated surface background used behind code blocks.
    public var surfaceElevated: Color
    /// Subtle border colour used for dividers and table separators.
    public var borderSubtle: Color

    // MARK: Geometry
    /// Small corner radius applied to inline code chips and code block containers.
    public var radiusSmall: CGFloat
    /// Extra-small spacing unit (typically 4 pt).
    public var spacingXS: CGFloat
    /// Small spacing unit (typically 6 pt).
    public var spacingSM: CGFloat
    /// Medium spacing unit (typically 12 pt).
    public var spacingMD: CGFloat

    // MARK: Headings
    /// Per-level heading styles for H1–H6.
    public var headings: MarkdownHeadingStyles

    // MARK: Paragraph
    /// Foreground colour for paragraph body text.
    public var paragraphTextColor: Color
    /// Vertical space appended below each block element.
    public var blockBottomSpacing: CGFloat

    // MARK: Inline code
    /// Background fill for inline code spans.
    public var inlineCodeBackground: Color

    // MARK: Blockquote
    /// Font used inside block-quote runs.
    public var blockQuoteFont: Font
    /// Text colour inside block-quote runs.
    public var blockQuoteTextColor: Color
    /// Width of the leading accent border on block quotes.
    public var blockQuoteBorderWidth: CGFloat
    /// Leading and trailing padding inside block-quote containers.
    public var blockQuoteHorizontalPadding: CGFloat

    // MARK: Lists
    /// Vertical spacing between list items.
    public var listItemSpacing: CGFloat

    // MARK: Tables
    /// Font used for table cell content.
    public var tableFont: Font

    // MARK: Code blocks
    /// Line spacing applied inside fenced code blocks.
    public var codeBlockLineSpacing: CGFloat

    // MARK: Links
    /// Whether link text is rendered with an underline.
    public var showsLinkUnderline: Bool

    /// Creates a `MarkdownStyle` with sensible system-font defaults.
    ///
    /// All parameters have defaults so callers only need to override tokens
    /// that differ from the generic baseline. Use `MarkdownStyle.runBot` in
    /// the RunBot target rather than constructing a value directly.
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
