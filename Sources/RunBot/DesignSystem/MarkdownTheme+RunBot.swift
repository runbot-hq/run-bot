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
    // Body: system body text — matches prose readability at log panel widths
    var body: any CustomCTFontConvertible {
        NSFont.preferredFont(forTextStyle: .body)
    }

    // Code blocks: caption-sized monospaced — matches RBFont.mono token
    // ⚠️ If this looks too small compared to the raw log font, bump to .callout here.
    var codeBlock: any CustomCTFontConvertible {
        NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
    }

    // Headings h1–h3 use system title styles; h4–h6 fall back to protocol defaults
    var h1: any CustomCTFontConvertible {
        NSFont.preferredFont(forTextStyle: .largeTitle)
    }
    var h2: any CustomCTFontConvertible {
        NSFont.preferredFont(forTextStyle: .title1)
    }
    var h3: any CustomCTFontConvertible {
        NSFont.preferredFont(forTextStyle: .title2)
    }
}
