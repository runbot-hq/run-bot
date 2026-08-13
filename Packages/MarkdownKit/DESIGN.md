# Design principles

## Native SwiftUI

Rendering uses SwiftUI views rather than HTML or a web view.

## Keep parsing off-main

Use `BlockParser.parseAsync(_:)` for user-facing content. Respect task
cancellation before publishing parsed blocks.

## Separate parsing and rendering

Parsing produces `[MarkdownBlock]`. Rendering consumes those blocks through
`MarkdownDocumentView`.

## Inject visual style

The engine owns generic rendering behavior. Consumers provide their visual
language through `MarkdownStyle`.

## Prefer graceful fallback

Unsupported syntax should remain readable as plain text rather than disappear
or fail rendering.

## Treat input as untrusted

Only HTTP and HTTPS links are interactive. Avoid logging source Markdown, code,
URLs, or other content.

## Keep dependencies focused

`swift-markdown` owns parsing. `Highlightr` owns syntax highlighting. New
dependencies require a clear capability that existing dependencies cannot
provide.
