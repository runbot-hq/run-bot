// LogLineParserTests.swift
// RunBotCoreTests
import Testing
@testable import RunBotCore

@Suite("parseLogLines")
struct LogLineParserTests {

    // MARK: - Plain lines

    @Test("Plain lines are returned as .plain")
    func test_plainLines() {
        let result = parseLogLines("hello\nworld")
        #expect(result.count == 2)
        guard case .plain(_, let t1) = result[0] else { Issue.record("Expected .plain at [0]"); return }
        guard case .plain(_, let t2) = result[1] else { Issue.record("Expected .plain at [1]"); return }
        #expect(t1 == "hello")
        #expect(t2 == "world")
    }

    @Test("Trailing newline does not produce a blank plain line")
    func test_trailingNewline_notBlankLine() {
        let result = parseLogLines("hello\n")
        #expect(result.count == 1)
        guard case .plain(_, let t) = result[0] else { Issue.record("Expected .plain"); return }
        #expect(t == "hello")
    }

    // MARK: - Group directives

    @Test("##[group] produces .groupHeader with correct title")
    func test_groupHeader_title() {
        let result = parseLogLines("##[group]Set up job")
        #expect(result.count == 1)
        guard case .groupHeader(_, let title) = result[0] else { Issue.record("Expected .groupHeader"); return }
        #expect(title == "Set up job")
    }

    @Test("Lines between ##[group] and ##[endgroup] are .groupedLine with correct groupID")
    func test_groupedLines_haveGroupID() {
        let raw = "##[group]Build\nline one\nline two\n##[endgroup]\nafter"
        let result = parseLogLines(raw)
        #expect(result.count == 4)
        guard case .groupHeader(let gid, _) = result[0] else { Issue.record("Expected .groupHeader at [0]"); return }
        guard case .groupedLine(_, let t1, let g1) = result[1] else { Issue.record("Expected .groupedLine at [1]"); return }
        guard case .groupedLine(_, let t2, let g2) = result[2] else { Issue.record("Expected .groupedLine at [2]"); return }
        guard case .plain(_, let after) = result[3] else { Issue.record("Expected .plain at [3]"); return }
        #expect(t1 == "line one")
        #expect(t2 == "line two")
        #expect(g1 == gid)
        #expect(g2 == gid)
        #expect(after == "after")
    }

    @Test("Second ##[group] implicitly closes the previous group")
    func test_implicitGroupClose() {
        let raw = "##[group]First\ninside first\n##[group]Second\ninside second"
        let result = parseLogLines(raw)
        #expect(result.count == 4)
        guard case .groupHeader(let gid1, let t1) = result[0] else { Issue.record("Expected .groupHeader at [0]"); return }
        guard case .groupedLine(_, _, let g1) = result[1] else { Issue.record("Expected .groupedLine at [1]"); return }
        guard case .groupHeader(let gid2, let t2) = result[2] else { Issue.record("Expected .groupHeader at [2]"); return }
        guard case .groupedLine(_, _, let g2) = result[3] else { Issue.record("Expected .groupedLine at [3]"); return }
        #expect(t1 == "First")
        #expect(t2 == "Second")
        #expect(g1 == gid1)
        #expect(g2 == gid2)
        #expect(gid1 != gid2)
    }

    // MARK: - Annotation directives

    @Test("##[warning] produces .annotation with .warning level")
    func test_warningAnnotation() {
        let result = parseLogLines("##[warning]Low disk space")
        #expect(result.count == 1)
        guard case .annotation(_, let level, let text, _, let groupID) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(level == .warning)
        #expect(text == "Low disk space")
        #expect(groupID == nil)
    }

    @Test("##[warning] inside a group retains groupID")
    func test_warningInsideGroup_retainsGroupID() {
        let raw = "##[group]Lint\n##[warning]Trailing whitespace\n##[endgroup]"
        let result = parseLogLines(raw)
        #expect(result.count == 2)
        guard case .groupHeader(let gid, _) = result[0] else { Issue.record("Expected .groupHeader at [0]"); return }
        guard case .annotation(_, let level, let text, _, let groupID) = result[1] else {
            Issue.record("Expected .annotation at [1]")
            return
        }
        #expect(level == .warning)
        #expect(text == "Trailing whitespace")
        #expect(groupID == gid)
    }

    // MARK: - IDs

    @Test("IDs are unique and monotonically increasing across all line types")
    func test_ids_areUniqueAndMonotonic() {
        let raw = "##[group]G\nline\n##[endgroup]\n##[warning]W\nplain"
        let result = parseLogLines(raw)
        let ids = result.map { $0.id }
        #expect(ids == Array(0..<ids.count), "IDs must be 0-based and contiguous")
    }

    // MARK: - Dimmed directives

    @Test("##[command] produces .dimmed")
    func test_commandDirective_producesDimmed() {
        let result = parseLogLines("##[command]/usr/bin/bash -e /tmp/runner-script.sh")
        #expect(result.count == 1)
        guard case .dimmed(_, let text, let groupID) = result[0] else { Issue.record("Expected .dimmed"); return }
        #expect(text == "/usr/bin/bash -e /tmp/runner-script.sh")
        #expect(groupID == nil)
    }

    @Test("Unknown ##[ directive produces .dimmed (add-matcher)")
    func test_unknownDirective_addMatcher_isDimmed() {
        // Build the input string programmatically so the runner never sees a
        // literal ##[add-matcher] token in the test source and tries to load it
        // as a real problem-matcher file path.
        let directive = "##[" + "add-matcher].github/problem-matcher.json"
        let result = parseLogLines(directive)
        #expect(result.count == 1)
        guard case .dimmed(_, let text, let groupID) = result[0] else { Issue.record("Expected .dimmed at [0]"); return }
        #expect(text == directive)
        #expect(groupID == nil)
    }

    // MARK: - ::add-mask:: privacy filter

    @Test("::add-mask:: directive is suppressed entirely (privacy contract)")
    func addMaskDirectiveIsSuppressed() {
        // Build the string programmatically so the runner never sees the literal
        // ::add-mask:: token and tries to redact the argument in CI log output.
        let directive = "::" + "add-mask::secret"
        #expect(parseLogLines(directive).isEmpty)
    }

    // MARK: - ::warning / ::error / ::notice (bare, no params)

    @Test("::warning:: bare format produces .annotation with .warning level and nil params")
    func test_colonWarning_bare() {
        let result = parseLogLines("::warning::Something went wrong")
        #expect(result.count == 1)
        guard case .annotation(_, let level, let text, let params, let groupID) = result[0] else {
            Issue.record("Expected .annotation at [0]"); return
        }
        #expect(level == .warning)
        #expect(text == "Something went wrong")
        #expect(params == nil)
        #expect(groupID == nil)
    }

    // MARK: - ::warning with params

    @Test("::warning with all params parses title, file, line, endLine")
    func test_colonWarning_allParams() {
        let result = parseLogLines("::warning file=app.js,line=12,endLine=15,title=Lint Error::Missing semicolon")
        #expect(result.count == 1)
        guard case .annotation(_, let level, let text, let params, _) = result[0] else {
            Issue.record("Expected .annotation at [0]"); return
        }
        #expect(level == .warning)
        #expect(text == "Missing semicolon")
        #expect(params?.title == "Lint Error")
        #expect(params?.file == "app.js")
        #expect(params?.line == 12)
        #expect(params?.endLine == 15)
    }

    // MARK: - ##[section]

    @Test("##[section] produces .section with correct title")
    func test_sectionDirective() {
        let result = parseLogLines("##[section]Diagnostic Output")
        #expect(result.count == 1)
        guard case .section(_, let title, _) = result[0] else { Issue.record("Expected .section at [0]"); return }
        #expect(title == "Diagnostic Output")
    }

    // MARK: - decodeActionsEscapes (via parseAnnotationParams)

    @Test("Percent-encoded colon in title is decoded (%3A → :)")
    func test_annotationParams_percentEncodedColon() {
        let params = parseAnnotationParams("title=Build Error%3A missing")
        #expect(params?.title == "Build Error: missing")
    }

}

