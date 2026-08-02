// Theme+RunBot.swift
// RunBot
//
// RunBot-native markdown theme for gonzalezreal/swift-markdown-ui.
// All values sourced from DesignTokens.swift.
//
// Design intent: monochrome with one accent.
// No coloured headings, no tinted surfaces beyond the grey code block background.
// Matches the low-colour aesthetic of the rest of the app.
//
// Token cross-reference (#2398):
// ┏━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
// ┃ Node               ┃ Token                                  ┃
// ┡━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┩
// ┃ Base / paragraph   ┃ size 12 regular · rbTextPrimary        ┃
// ┃ H1                 ┃ size 14 bold · rbTextPrimary           ┃
// ┃ H2                 ┃ size 13 semibold · rbTextPrimary       ┃
// ┃ H3                 ┃ size 12.5 medium · rbTextPrimary       ┃
// ┃ H4–H6              ┃ sectionKey (12.5pt) · rbTextSecondary   ┃
// ┃ Inline code        ┃ monoSmall 11pt · rbTextSecondary       ┃
// ┃ Code block         ┃ monoSmall · bg rbSurfaceElevated        ┃
// ┃ Blockquote         ┃ italic · rbTextSecondary · 2pt border  ┃
// ┃ Link               ┃ rbAccent · no underline                ┃
// ┗━━━━━━━━━━━━━━━━━━━━┻━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
import MarkdownUI
import SwiftUI

/// `Theme` extensions providing the RunBot-native markdown rendering theme.
extension Theme {
    /// RunBot-native markdown theme built from design tokens.
    ///
    /// Use via `.markdownTheme(.runBot)` on any `Markdown` view.
    @MainActor static var runBot: Theme {
        Theme()
            // MARK: Base text
            .text {
                FontSize(12)
                FontWeight(.regular)
                ForegroundColor(.rbTextPrimary)
            }
            // MARK: Headings
            .heading1 { config in
                config.label
                    .markdownTextStyle {
                        FontSize(14)
                        FontWeight(.bold)
                        ForegroundColor(.rbTextPrimary)
                    }
                    .markdownMargin(top: 12, bottom: 4)
            }
            .heading2 { config in
                config.label
                    .markdownTextStyle {
                        FontSize(13)
                        FontWeight(.semibold)
                        ForegroundColor(.rbTextPrimary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading3 { config in
                config.label
                    .markdownTextStyle {
                        FontSize(12.5)
                        FontWeight(.medium)
                        ForegroundColor(.rbTextPrimary)
                    }
                    .markdownMargin(top: 8, bottom: 2)
            }
            .heading4 { config in
                config.label
                    .markdownTextStyle {
                        FontSize(12.5)
                        FontWeight(.regular)
                        ForegroundColor(.rbTextSecondary)
                    }
                    .markdownMargin(top: 6, bottom: 2)
            }
            .heading5 { config in
                config.label
                    .markdownTextStyle {
                        FontSize(12.5)
                        FontWeight(.regular)
                        ForegroundColor(.rbTextSecondary)
                    }
                    .markdownMargin(top: 6, bottom: 2)
            }
            .heading6 { config in
                config.label
                    .markdownTextStyle {
                        FontSize(12.5)
                        FontWeight(.regular)
                        ForegroundColor(.rbTextSecondary)
                    }
                    .markdownMargin(top: 6, bottom: 2)
            }
            // MARK: Paragraph
            .paragraph { config in
                config.label
                    .markdownTextStyle {
                        FontSize(12)
                        FontWeight(.regular)
                        ForegroundColor(.rbTextPrimary)
                    }
                    .markdownMargin(top: 0, bottom: 4)
            }
            // MARK: Inline code (.code = inline code style in swift-markdown-ui v2)
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(11)
                ForegroundColor(.rbTextSecondary)
                BackgroundColor(.rbSurfaceElevated)
            }
            // MARK: Code block
            .codeBlock { config in
                CodeBlockView(config: config)
            }
            // MARK: Blockquote
            .blockquote { config in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.rbBorderSubtle)
                        .frame(width: 2)
                    config.label
                        .markdownTextStyle {
                            FontStyle(.italic)
                            ForegroundColor(.rbTextSecondary)
                        }
                        .relativePadding(.horizontal, length: .em(0.75))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // MARK: List item
            .listItem { config in
                config.label
                    .markdownMargin(top: 2, bottom: 0)
            }
            // MARK: Table
            .table { config in
                config.label
                    .markdownTextStyle {
                        FontSize(11)
                        ForegroundColor(.rbTextPrimary)
                    }
            }
            // MARK: Table cell
            .tableCell { config in
                config.label
                    .markdownTextStyle {
                        FontSize(11)
                        ForegroundColor(.rbTextPrimary)
                    }
                    .padding(RBSpacing.xs)
            }
            // MARK: Thematic break
            .thematicBreak {
                Divider()
                    .overlay(Color.rbBorderSubtle)
                    .markdownMargin(top: 4, bottom: 4)
            }
            // MARK: Link
            .link {
                ForegroundColor(.rbAccent)
                UnderlineStyle(.init(pattern: .solid, color: .clear))
            }
    }
}

// MARK: - CodeBlockView

/// Renders a markdown code block with syntax highlighting via `HighlightrService`.
///
/// Falls back to plain text if Highlightr returns `nil` (unknown language, JSCore failure).
/// Must live outside the `Theme` extension so it can declare `@Environment(\..colorScheme)`.
struct CodeBlockView: View {
    /// The code block configuration supplied by `swift-markdown-ui`.
    let config: CodeBlockConfiguration
    /// Current colour scheme — forwarded to `HighlightrService` for theme selection.
    @Environment(\.colorScheme) var colorScheme

    /// Highlighted code block, with optional language label and plain-text fallback.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = config.language, !lang.isEmpty {
                Text(lang.uppercased())
                    .font(RBFont.statLabel)
                    .foregroundColor(Color.rbTextTertiary)
                    .padding(.horizontal, RBSpacing.sm)
                    .padding(.top, RBSpacing.xs)
            }
            Group {
                if let attributed = HighlightrService.shared.highlight(
                    config.content,
                    language: config.language?.isEmpty == false ? config.language! : "plaintext",
                    colorScheme: colorScheme
                ) {
                    Text(attributed)
                } else {
                    // Fallback: plain text with same visual layout
                    config.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(11)
                            ForegroundColor(.rbTextSecondary)
                        }
                }
            }
            .font(RBFont.monoSmall)
            .relativeLineSpacing(.em(0.2))
            .padding(RBSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.rbSurfaceElevated)
        .cornerRadius(RBRadius.small)
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.small)
                .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
        )
        .markdownMargin(top: 0, bottom: 4)
    }
}
