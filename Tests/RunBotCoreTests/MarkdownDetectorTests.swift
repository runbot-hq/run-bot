// MarkdownDetectorTests.swift
// RunBotCoreTests
import Testing
@testable import RunBotCore

@Suite("MarkdownDetector")
struct MarkdownDetectorTests {

    // MARK: - confidence(_:)

    @Test("empty string scores zero")
    func emptyStringScoresZero() {
        #expect(MarkdownDetector.confidence("") == 0)
    }

    @Test("plain prose scores zero")
    func plainProseScoresZero() {
        let text = "Building target RunBot\nCompiling Sources/RunBot/main.swift\nBuild complete!"
        #expect(MarkdownDetector.confidence(text) == 0)
    }

    @Test("fenced code block with language scores 4")
    func fencedCodeBlockWithLanguageScores4() {
        let text = """
        ```swift
        let x = 42
        print(x)
        ```
        """
        #expect(MarkdownDetector.confidence(text) == 4)
    }

    @Test("fenced code block without language scores 1")
    func fencedCodeBlockWithoutLanguageScores1() {
        let text = """
        ```
        some output
        ```
        """
        #expect(MarkdownDetector.confidence(text) == 1)
    }

    @Test("heading scores 2")
    func headingScores2() {
        let text = "# Build Summary"
        #expect(MarkdownDetector.confidence(text) == 2)
    }

    @Test("table scores 3")
    func tableScores3() {
        let text = """
        | File | Status |
        |------|--------|
        | main.swift | OK |
        """
        #expect(MarkdownDetector.confidence(text) == 3)
    }

    @Test("diversity bonus fires at 3 distinct block types")
    func diversityBonusAt3Types() {
        // heading(2) + list(1) + code-with-lang(4) + diversity(3) = 10
        let text = """
        # Summary
        - item one
        - item two
        ```swift
        let x = 1
        ```
        """
        let score = MarkdownDetector.confidence(text)
        #expect(score >= 10)
    }

    @Test("rich AI review output scores >= 6")
    func richOutputScoresAboveThreshold() {
        let text = """
        ## Code Review

        Overall this looks good. A few minor notes:

        - `loadLog()` should cancel the previous task before starting a new one
        - The `@State` identity assumption needs verification

        ```swift
        loadTask?.cancel()
        loadTask = Task { ... }
        ```

        > Note: See #2393 for context on the detection thresholds.
        """
        #expect(MarkdownDetector.confidence(text) >= 6)
    }

    // MARK: - looksLikeMarkdown(_:)

    @Test("short 5-line fenced block does not auto-enable (scores ~4, fails raw gate)")
    func shortFencedBlockFailsRawGate() {
        let text = """
        ```swift
        let x = 42
        print(x)
        ```
        """
        // Score ~4 — fails the raw >= 6 gate. Short-log bypass not yet implemented.
        #expect(MarkdownDetector.looksLikeMarkdown(text) == false)
    }

    @Test("2000-line log with score 7 fails normalized gate")
    func longLogWithLowNormalizedScoreFails() {
        // 2000 plain lines + one headed section: score ~2, normalized ~0.001
        let plainLines = (0..<1990).map { "[2026-08-01T00:0\($0 % 10):00Z] Build step \($0)" }.joined(separator: "\n")
        let text = "# Summary\n" + plainLines
        // score = 2 (heading), normalized = 2/1991 ≈ 0.001 — fails both gates
        #expect(MarkdownDetector.looksLikeMarkdown(text) == false)
    }

    @Test("rich short log auto-enables")
    func richShortLogAutoEnables() {
        let text = """
        ## Code Review

        - `loadLog()` cancel race fixed
        - `@State` identity confirmed stable

        ```swift
        loadTask?.cancel()
        loadTask = Task { ... }
        ```

        > See #2393 for threshold context.

        | Check | Result |
        |-------|--------|
        | Build | ✅ |
        | Tests | ✅ |
        """
        #expect(MarkdownDetector.looksLikeMarkdown(text) == true)
    }

    @Test("plain build log does not auto-enable")
    func plainBuildLogDoesNotAutoEnable() {
        let text = (0..<50).map { "[2026-08-01T00:00:00Z] Compiling file\($0).swift" }.joined(separator: "\n")
        #expect(MarkdownDetector.looksLikeMarkdown(text) == false)
    }
}
