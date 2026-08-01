// MarkdownTheme+RunBot.swift
// RunBot
//
// RunBot font group for LiYanan2004/MarkdownView, wired to design tokens.
//
// Token cross-reference (§5 of #2394):
// ┏━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
// ┃ Markdown element   ┃ Token                                ┃
// ┡━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┩
// ┃ Body text          ┃ system .body                         ┃
// ┃ Code blocks        ┃ caption-sized monospaced             ┃
// ┃ Headings h1–h3     ┃ system title sizes (semibold via CSS) ┃
// ┗━━━━━━━━━━━━━━━━━━━━┻━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
//
// ⚠️ RBFont.mono is .system(.caption, design: .monospaced) — cross-check
// this size is right for rendered code blocks vs. the raw log font. (§5 of #2394)
import AppKit
import MarkdownView
import SwiftUI

/// A `MarkdownFontGroup` that maps RunBot design tokens to MarkdownView components.
struct RunBotMarkdownFontGroup: MarkdownFontGroup {
    /// Body text font — system `.body`, matches prose readability at log panel widths.
    var body: any CustomCTFontConvertible {
        NSFont.preferredFont(forTextStyle: .body)
    }

    /// Code block font — caption-sized monospaced, matching the `RBFont.mono` token.
    /// If this reads too small compared to the raw log font, bump to `.callout` here.
    var codeBlock: any CustomCTFontConvertible {
        NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
    }

    /// h1 heading font — system `.largeTitle`.
    var h1: any CustomCTFontConvertible {
        NSFont.preferredFont(forTextStyle: .largeTitle)
    }

    /// h2 heading font — system `.title1`.
    var h2: any CustomCTFontConvertible {
        NSFont.preferredFont(forTextStyle: .title1)
    }

    /// h3 heading font — system `.title2`.
    var h3: any CustomCTFontConvertible {
        NSFont.preferredFont(forTextStyle: .title2)
    }
}
