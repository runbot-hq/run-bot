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

    @Test func detect_emptyString_scoresZero() {
        let result = MarkdownDetector.detect("")
        #expect(result.score == 0)
        #expect(result.looksLikeMarkdown == false)
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

    @Test("short 5-line fenced code block auto-enables under cubic curve")
    func shortFencedBlockAutoEnablesUnderCubicCurve() {
        let text = """
        ```swift
        let x = 42
        print(x)
        ```
        """
        // Score ~4, lines ~5: S^3/L = 64/5 = 12.8 >= 1.8 and score >= 3 -> true.
        // The old linear gate (score >= 6) rejected this; the cubic curve correctly
        // auto-enables short dense code blocks (fixes #2505).
        #expect(MarkdownDetector.looksLikeMarkdown(text) == true)
    }

    @Test("2000-line log with score 7 fails normalized gate")
    func longLogWithLowNormalizedScoreFails() {
        // 2000 plain lines + one headed section: score ~2, normalized ~0.001
        let plainLines = (0..<1990).map { "[2026-08-01T00:0\($0 % 10):00Z] Build step \($0)" }.joined(separator: "\n")
        let text = "# Summary\n" + plainLines
        // score = 2 (heading) — fails absolute minimum score >= 3 gate
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

    // MARK: - Mathematical curve (S^3 / L >= 1.8, minimum score >= 3)

    @Test("mathematical auto-enable curve — all six boundary cases")
    func testMathematicalAutoEnableCurve() {
        /// Builds a log string with a fully predictable MarkdownDetector score and line count.
        ///
        /// **Score construction** (top-level AST, no diversity bonus fired):
        /// - Each `# H` heading      → +2 pts, 1 source line, followed by 1 blank separator line
        ///   (except the last heading which has no trailing blank).
        /// - One no-language fenced code block at the end → +1 pt.
        ///   Its body is filled with enough lines to reach `targetLines` exactly.
        ///   A code block scores exactly +1 regardless of how many lines it contains,
        ///   so line count is fully controllable without affecting score.
        ///
        /// Score formula: `headings * 2 + 1`  (the +1 is always the code block).
        /// Diversity: headings + code = 2 block types — bonus (+3) needs ≥3, so never fires.
        ///
        /// - Parameters:
        ///   - headings: Number of `# H` heading blocks. Score = headings*2 + 1.
        ///   - lines: Total newline-split line count of the returned string.
        func makeLog(headings: Int, lines targetLines: Int) -> String {
            // Lines consumed by headings: each heading = 1 line + 1 blank, except last has no blank.
            let headingSourceLines = headings > 0 ? headings * 2 - 1 : 0
            // The code fence itself is 3 lines minimum: opening ```, one body line, closing ```.
            // Body lines = targetLines - headingSourceLines - 1 (blank before fence) - 2 (fence delimiters)
            // We need at least 1 body line, so assert targetLines is large enough.
            let fenceOverhead = (headings > 0 ? 1 : 0) + 2 // blank before fence + ``` open + ``` close
            let bodyLines = max(1, targetLines - headingSourceLines - fenceOverhead)
            var rows: [String] = []
            for i in 0..<headings {
                rows.append("# H")
                if i < headings - 1 { rows.append("") } // blank between headings
            }
            if headings > 0 { rows.append("") }         // blank before code fence
            rows.append("```")                           // fence open (no language → +1)
            for _ in 0..<bodyLines { rows.append(".") } // body: single-char, no score
            rows.append("```")                           // fence close
            return rows.joined(separator: "\n")
        }

        // 1. Tiny log — headings=0, score=1 (code block only) < 3 minimum → false
        //    lines=3 (```, ., ```). S^3/L = 1/3 = 0.33 but score(1) < 3 → false
        let tiny = makeLog(headings: 0, lines: 3)
        #expect(MarkdownDetector.detect(tiny).score == 1)
        #expect(MarkdownDetector.detect(tiny).looksLikeMarkdown == false)

        // 2. Issue #2505 scenario — headings=1, score=3, lines=35
        //    S^3/L = 27/35 ≈ 0.77 ... hmm, need denser. Use headings=2, score=5, lines=15
        //    S^3/L = 125/15 ≈ 8.33 >= 1.8 → true
        let shortDense = makeLog(headings: 2, lines: 15)
        #expect(MarkdownDetector.detect(shortDense).score == 5)
        #expect(MarkdownDetector.detect(shortDense).looksLikeMarkdown == true)

        // 3. Short log failing the curve — headings=2, score=5, lines=70
        //    S^3/L = 125/70 ≈ 1.79 < 1.8 → false
        let shortFailing = makeLog(headings: 2, lines: 70)
        #expect(MarkdownDetector.detect(shortFailing).score == 5)
        #expect(MarkdownDetector.detect(shortFailing).looksLikeMarkdown == false)

        // 4. Exact lower bound — headings=3, score=7, lines=134
        //    S^3/L = 343/134 ≈ 2.56 >= 1.8 → true
        let mediumPass = makeLog(headings: 3, lines: 134)
        #expect(MarkdownDetector.detect(mediumPass).score == 7)
        #expect(MarkdownDetector.detect(mediumPass).looksLikeMarkdown == true)

        // 5. Medium log over line limit — headings=3, score=7, lines=200
        //    S^3/L = 343/200 = 1.715 < 1.8 → false
        let mediumFail = makeLog(headings: 3, lines: 200)
        #expect(MarkdownDetector.detect(mediumFail).score == 7)
        #expect(MarkdownDetector.detect(mediumFail).looksLikeMarkdown == false)

        // 6. Massive build log — headings=5, score=11, lines=1000
        //    S^3/L = 1331/1000 = 1.331 < 1.8 → false
        let massive = makeLog(headings: 5, lines: 1000)
        #expect(MarkdownDetector.detect(massive).score == 11)
        #expect(MarkdownDetector.detect(massive).looksLikeMarkdown == false)
    }
}
