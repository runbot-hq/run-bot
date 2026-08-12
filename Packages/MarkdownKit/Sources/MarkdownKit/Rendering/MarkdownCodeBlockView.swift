// MarkdownCodeBlockView.swift
// RunBot
import SwiftUI

/// Renders a fenced code block with Highlightr syntax highlighting.
///
/// Falls back to plain text when Highlightr returns `nil` (unknown language,
/// JSCore failure). Language label displayed above the block when present.
@MainActor
public struct MarkdownCodeBlockView: View {
    public let code: String
    public let language: String?
    public let style: MarkdownStyle

    @Environment(\.colorScheme) private var colorScheme

    public init(code: String, language: String?, style: MarkdownStyle) {
        self.code = code
        self.language = language
        self.style = style
    }

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
        .padding(.bottom, 6)
    }
}
