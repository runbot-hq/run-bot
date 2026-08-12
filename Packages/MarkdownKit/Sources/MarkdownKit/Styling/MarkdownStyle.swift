// MarkdownStyle.swift
// RunBot
//
// Rendering tokens consumed by all MarkdownKit views.
// Must NOT reference any RunBot-specific symbol (RBFont, RBSpacing, etc.).
// RunBot maps its design tokens onto this struct via MarkdownStyle+RunBot.swift
// inside the RunBot target.
import SwiftUI

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
        spacingMD: CGFloat = 12
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
    }
}
