// MarkdownCodeBlockView.swift
// RunBot
import SwiftUI

/// Renders a fenced code block with Highlightr syntax highlighting.
///
/// Falls back to plain text when Highlightr returns `nil` (unknown language,
/// JSCore failure). Language label displayed above the block when present.
@MainActor
public struct MarkdownCodeBlockView: View {
    /// The raw code string to highlight and display.
    public let code: String
    /// Lowercased language identifier passed to Highlightr (e.g. `"swift"`, `"bash"`).
    public let language: String?
    /// Style tokens controlling typography, colours, and geometry.
    public let style: MarkdownStyle

    @Environment(\.colorScheme) private var colorScheme

    /// Creates a code block view for the given code, optional language, and style.
    public init(code: String, language: String?, style: MarkdownStyle) {
        self.code = code
        self.language = language
        self.style = style
    }

    /// SwiftUI view body — see type-level doc for rendering contract.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                Text(lang.uppercased())
                    .font(style.labelFont)
                    .foregroundColor(style.textTertiary)
                    .padding(.horizontal, style.spacingSM)
                    .padding(.top, style.spacingXS)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    let effectiveLang = language.flatMap { $0.isEmpty ? nil : $0 } ?? "plaintext"
                    if let attributed = MarkdownHighlighter.shared.highlight(
                        code,
                        language: effectiveLang,
                        colorScheme: colorScheme
                    ) {
                        Text(attributed)
                    } else {
                        Text(code)
                            .font(style.monoFont)
                            .foregroundColor(style.textSecondary)
                    }
                }
                .font(style.monoFont)
                .lineSpacing(style.codeBlockLineSpacing)
                .fixedSize(horizontal: true, vertical: false)
                .padding(style.spacingSM)
            }
            .frame(maxWidth: .infinity)
        }
        .background(style.surfaceElevated)
        .cornerRadius(style.radiusSmall)
        .overlay(
            RoundedRectangle(cornerRadius: style.radiusSmall)
                .strokeBorder(style.borderSubtle, lineWidth: 0.5)
        )
        .padding(.bottom, style.blockBottomSpacing)
    }
}
