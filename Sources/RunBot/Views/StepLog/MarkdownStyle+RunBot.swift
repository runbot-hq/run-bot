// MarkdownStyle+RunBot.swift
// RunBot
//
// Maps RunBot design tokens onto MarkdownStyle.
// No MarkdownKit symbol is allowed in DesignTokens.swift or vice-versa.
// This file is the only bridge between the two.
import MarkdownKit
import SwiftUI

/// RunBot design-token mapping for `MarkdownStyle`.
extension MarkdownStyle {
    /// RunBot-native style built from design tokens.
    ///
    /// Token cross-reference (mirrors Theme+RunBot.swift):
    /// - Base / paragraph  : 12 pt regular · rbTextPrimary
    /// - H1                : 14 pt bold    · rbTextPrimary
    /// - H2                : 13 pt semi    · rbTextPrimary
    /// - H3–H6             : 12.5 pt       · rbTextSecondary
    /// - Inline code       : monoSmall 11  · rbTextSecondary
    /// - Code block bg     : rbSurfaceElevated
    /// - Border            : rbBorderSubtle
    /// - Link              : rbAccent
    @MainActor static var runBot: MarkdownStyle {
        MarkdownStyle(
            baseFont: .system(size: 12),
            monoFont: RBFont.monoSmall,
            labelFont: RBFont.statLabel,
            textPrimary: .rbTextPrimary,
            textSecondary: .rbTextSecondary,
            textTertiary: .rbTextTertiary,
            accent: .rbAccent,
            surfaceElevated: .rbSurfaceElevated,
            borderSubtle: .rbBorderSubtle,
            radiusSmall: RBRadius.small,
            spacingXS: RBSpacing.xs,
            spacingSM: RBSpacing.sm,
            spacingMD: RBSpacing.md
        )
    }
}
