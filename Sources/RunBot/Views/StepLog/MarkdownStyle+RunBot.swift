// MarkdownStyle+RunBot.swift
// RunBot
//
// Maps RunBot design tokens onto `MarkdownStyle`.
// Lives in the RunBot target so MarkdownKit stays import-free of app symbols.
import MarkdownKit
import SwiftUI

/// RunBot-specific `MarkdownStyle` presets.
extension MarkdownStyle {
    /// `MarkdownStyle` preset that matches RunBot's visual language.
    ///
    /// Tokens source from:
    /// - Typography  → `RBFont`
    /// - Spacing     → `RBSpacing` / `RBRadius`
    /// - Colour      → `Color.rb*` semantic palette
    static var runBot: MarkdownStyle {
        MarkdownStyle(
            baseFont: .system(size: 12, weight: .regular),
            monoFont: RBFont.monoSmall,
            labelFont: RBFont.statLabel,
            textPrimary: Color.rbTextPrimary,
            textSecondary: Color.rbTextSecondary,
            textTertiary: Color.rbTextTertiary,
            accent: Color.rbAccent,
            surfaceElevated: Color.rbSurfaceElevated,
            borderSubtle: Color.rbBorderSubtle,
            radiusSmall: RBRadius.small,
            spacingXS: RBSpacing.xs,
            spacingSM: RBSpacing.sm,
            spacingMD: RBSpacing.md,
            headings: MarkdownHeadingStyles(
                h1: MarkdownHeadingStyle(
                    font: .system(size: 14, weight: .bold),
                    color: Color.rbTextPrimary,
                    topSpacing: 16,
                    bottomSpacing: 8
                ),
                h2: MarkdownHeadingStyle(
                    font: .system(size: 13, weight: .semibold),
                    color: Color.rbTextPrimary,
                    topSpacing: 12,
                    bottomSpacing: 6
                ),
                h3: MarkdownHeadingStyle(
                    font: .system(size: 12.5, weight: .medium),
                    color: Color.rbTextPrimary,
                    topSpacing: 10,
                    bottomSpacing: 4
                ),
                h4: MarkdownHeadingStyle(
                    font: .system(size: 12.5),
                    color: Color.rbTextSecondary,
                    topSpacing: 6,
                    bottomSpacing: 4
                ),
                h5: MarkdownHeadingStyle(
                    font: .system(size: 12.5),
                    color: Color.rbTextSecondary,
                    topSpacing: 6,
                    bottomSpacing: 4
                ),
                h6: MarkdownHeadingStyle(
                    font: .system(size: 12.5),
                    color: Color.rbTextSecondary,
                    topSpacing: 6,
                    bottomSpacing: 4
                )
            ),
            paragraphTextColor: Color.rbTextPrimary.opacity(0.75),
            blockBottomSpacing: RBSpacing.sm,
            inlineCodeBackground: Color.rbSurfaceElevated,
            blockQuoteFont: .system(size: 12, weight: .regular).italic(),
            blockQuoteTextColor: Color.rbTextSecondary,
            blockQuoteBorderWidth: 2,
            blockQuoteHorizontalPadding: 9,
            listItemSpacing: 2,
            tableFont: .system(size: 11, weight: .regular),
            codeBlockLineSpacing: 2.2,
            showsLinkUnderline: false
        )
    }
}
