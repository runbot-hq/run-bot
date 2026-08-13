# MarkdownKit

A native SwiftUI Markdown engine with syntax-highlighted code blocks, GFM
tables, configurable styling, and asynchronous off-main parsing.

## Features

- Native SwiftUI rendering
- Fenced code blocks with syntax highlighting
- GFM tables with column alignment and horizontal scrolling
- Headings, paragraphs, links, blockquotes, lists, thematic breaks, and inline code
- Bold, italic, strikethrough, and nested inline formatting
- Asynchronous, cancellation-aware parsing
- Configurable fonts, colors, spacing, and geometry
- Plain-text fallback for unsupported syntax
- Markdown detection and confidence scoring

## Requirements

- Swift 6.2
- macOS 26

## Dependencies

| Package | Purpose |
|---|---|
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown parsing and AST generation |
| [Highlightr](https://github.com/raspu/Highlightr) | Syntax highlighting for fenced code blocks |

Dependencies are pinned to exact revisions in `Package.swift`.

## Usage

```swift
import MarkdownKit
import SwiftUI

struct MarkdownView: View {
    let markdown: String

    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        MarkdownDocumentView(
            blocks: blocks,
            style: MarkdownStyle()
        )
        .task(id: markdown) {
            blocks = await BlockParser.parseAsync(markdown)
        }
    }
}
```

`MarkdownStyle` provides defaults and can be customized with application fonts,
colors, spacing, heading styles, table typography, and code-block presentation.

See [Design principles](DESIGN.md) for architectural constraints.

## Development

```bash
swift build --package-path Packages/MarkdownKit
swift test --package-path Packages/MarkdownKit
```
