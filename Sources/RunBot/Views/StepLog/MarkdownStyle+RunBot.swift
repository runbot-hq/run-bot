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
    /// - H3                : 12.5 pt medium · rbTextPrimary
    /// - H4–H6             : 12.5 pt regular · rbTextSecondary
    /// - Inline code       : monoSmall 11  · rbTextSecondary
    /// - Code block bg     : rbSurfaceElevated
    /// - Border            : rbBorderSubtle
    /// - Link              : rbAccent
    @MainActor static var runBot: MarkdownStyle {
        MarkdownStyle(
            baseFont: .system(size: 12, weight: .regular),
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
            spacingMD: RBSpacing.md,
            headings: MarkdownHeadingStyles(
                h1: MarkdownHeadingStyle(
                    font: .system(size: 14, weight: .bold),
                    color: .rbTextPrimary,
                    topSpacing: 16,
                    bottomSpacing: 8
                ),
                h2: MarkdownHeadingStyle(
                    font: .system(size: 13, weight: .semibold),
                    color: .rbTextPrimary,
                    topSpacing: 12,
                    bottomSpacing: 6
                ),
                h3: MarkdownHeadingStyle(
                    font: .system(size: 12.5, weight: .medium),
                    color: .rbTextPrimary,
                    topSpacing: 10,
                    bottomSpacing: 4
                ),
                h4: MarkdownHeadingStyle(
                    font: .system(size: 12.5, weight: .regular),
                    color: .rbTextSecondary,
                    topSpacing: 6,
                    bottomSpacing: 4
                ),
                h5: MarkdownHeadingStyle(
                    font: .system(size: 12.5, weight: .regular),
                    color: .rbTextSecondary,
                    topSpacing: 6,
                    bottomSpacing: 4
                ),
                h6: MarkdownHeadingStyle(
                    font: .system(size: 12.5, weight: .regular),
                    color: .rbTextSecondary,
                    topSpacing: 6,
                    bottomSpacing: 4
                )
            ),
            paragraphTextColor: .rbTextPrimary.opacity(0.75),
            blockBottomSpacing: 6,
            inlineCodeBackground: .rbSurfaceElevated,
            blockQuoteFont: .system(size: 12, weight: .regular).italic(),
            blockQuoteTextColor: .rbTextSecondary,
            blockQuoteBorderWidth: 2,
            blockQuoteHorizontalPadding: 9,
            listItemSpacing: 2,
            tableFont: .system(size: 11),
            codeBlockLineSpacing: 2.2,
            showsLinkUnderline: false
        )
    }
}
