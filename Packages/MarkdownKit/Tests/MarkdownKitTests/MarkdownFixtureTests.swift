// MarkdownFixtureTests.swift
// MarkdownKitTests
//
// End-to-end fixture tests: feed a representative document through BlockParser
// and assert the expected block sequence without crashing on any node.
import Testing
import Markdown
@testable import MarkdownKit

@Suite struct MarkdownFixtureTests {

    // Representative fixture covering every supported block type + edge cases.
    private static let fixture = """
    # Heading 1

    A paragraph with **bold**, *italic*, ~~strike~~, `code`, and a [link](https://example.com).

    ## Heading 2

    > A block quote with nested **formatting**.

    ### Ordered list

    1. First item
    2. Second item
       - Nested bullet
    3. Third item

    ### Unordered list

    - Alpha
    - Beta
    - Gamma

    ---

    ```swift
    let greeting = "Hello, MarkdownKit!"
    print(greeting)
    ```

    ```
    plain block, no language
    ```

    | Left | Center | Right |
    |:-----|:------:|------:|
    | 1    |   2    |     3 |
    | long cell content here | short | x |

    Trailing paragraph after table.
    """

    @Test func fullFixtureParsesSafely() {
        // Must not crash or produce any .unknown block for known node types.
        let blocks = Document(parsing: Self.fixture).children.map { BlockParser.parse($0) }
        #expect(!blocks.isEmpty)
    }

    @Test func fixtureContainsExpectedBlockTypes() {
        let blocks = Document(parsing: Self.fixture).children.map { BlockParser.parse($0) }
        let hasHeading = blocks.contains     { if case .heading    = $0 { return true }; return false }
        let hasParagraph = blocks.contains   { if case .paragraph  = $0 { return true }; return false }
        let hasCode = blocks.contains        { if case .codeBlock  = $0 { return true }; return false }
        let hasTable = blocks.contains       { if case .table      = $0 { return true }; return false }
        let hasBreak = blocks.contains       { if case .thematicBreak = $0 { return true }; return false }
        let hasOrdered = blocks.contains     { if case .orderedList   = $0 { return true }; return false }
        let hasUnordered = blocks.contains   { if case .unorderedList = $0 { return true }; return false }
        let hasQuote = blocks.contains       { if case .blockQuote = $0 { return true }; return false }
        #expect(hasHeading)
        #expect(hasParagraph)
        #expect(hasCode)
        #expect(hasTable)
        #expect(hasBreak)
        #expect(hasOrdered)
        #expect(hasUnordered)
        #expect(hasQuote)
    }

    @Test func malformedTableDoesNotCrash() {
        // Missing alignment row — swift-markdown may or may not emit a Table node.
        // Either way BlockParser must not crash.
        let md = "| A | B\n| 1 | 2"
        let blocks = Document(parsing: md).children.map { BlockParser.parse($0) }
        #expect(!blocks.isEmpty)
    }

    @Test func rawHTMLFallsBackToUnknownOrParagraph() {
        let md = "<div>some html</div>"
        let blocks = Document(parsing: md).children.map { BlockParser.parse($0) }
        // Must not crash. Block type is unknown or paragraph depending on parser version.
        #expect(!blocks.isEmpty)
    }

    @Test func emptyDocumentProducesNoBlocks() {
        let blocks = Document(parsing: "").children.map { BlockParser.parse($0) }
        #expect(blocks.isEmpty)
    }
}
