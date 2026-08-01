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

    @Test("##[endgroup] with no open group is ignored")
    func test_endgroup_withNoOpenGroup_isIgnored() {
        let result = parseLogLines("##[endgroup]\nplain")
        #expect(result.count == 1)
        guard result.indices.contains(0),
              case .plain(_, let t) = result[0] else { Issue.record("Expected .plain at [0]"); return }
        #expect(t == "plain")
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
        guard case .annotation(_, let level, let text, let groupID) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(level == .warning)
        #expect(text == "Low disk space")
        #expect(groupID == nil)
    }

    @Test("##[error] produces .annotation with .error level")
    func test_errorAnnotation() {
        let result = parseLogLines("##[error]Build failed")
        #expect(result.count == 1)
        guard case .annotation(_, let level, let text, let groupID) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(level == .error)
        #expect(text == "Build failed")
        #expect(groupID == nil)
    }

    @Test("##[notice] produces .annotation with .notice level")
    func test_noticeAnnotation() {
        let result = parseLogLines("##[notice]Cache miss")
        #expect(result.count == 1)
        guard case .annotation(_, let level, let text, let groupID) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(level == .notice)
        #expect(text == "Cache miss")
        #expect(groupID == nil)
    }

    // MARK: - IDs

    @Test("IDs are unique and monotonically increasing across all line types")
    func test_ids_areUniqueAndMonotonic() {
        let raw = "##[group]G\nline\n##[endgroup]\n##[warning]W\nplain"
        let result = parseLogLines(raw)
        let ids = result.map { $0.id }
        #expect(ids == Array(0..<ids.count), "IDs must be 0-based and contiguous")
    }

    // MARK: - Default collapsed groups

    @Test("All groupHeader IDs are collectable into a Set for default-collapsed state")
    func test_defaultCollapsedSet() {
        let raw = "##[group]A\nline\n##[endgroup]\n##[group]B\nline2"
        let result = parseLogLines(raw)
        let collapsedIDs = Set(result.compactMap { line -> Int? in
            if case .groupHeader(let id, _) = line { return id } else { return nil }
        })
        #expect(collapsedIDs.count == 2)
    }

    @Test("##[warning] inside a group retains groupID")
    func test_warningInsideGroup_retainsGroupID() {
        let raw = "##[group]Lint\n##[warning]Trailing whitespace\n##[endgroup]"
        let result = parseLogLines(raw)
        #expect(result.count == 2)
        guard case .groupHeader(let gid, _) = result[0] else { Issue.record("Expected .groupHeader at [0]"); return }
        guard case .annotation(_, let level, let text, let groupID) = result[1] else {
            Issue.record("Expected .annotation at [1]")
            return
        }
        #expect(level == .warning)
        #expect(text == "Trailing whitespace")
        #expect(groupID == gid)
    }

    // MARK: - Whitespace trimming

    @Test("##[group] title with leading space is trimmed")
    func test_groupHeader_leadingSpace_trimmed() {
        let result = parseLogLines("##[group] Set up job")
        guard case .groupHeader(_, let title) = result[0] else { Issue.record("Expected .groupHeader"); return }
        #expect(title == "Set up job")
    }

    @Test("##[warning] text with leading space is trimmed")
    func test_warningAnnotation_leadingSpace_trimmed() {
        let result = parseLogLines("##[warning] Low disk space")
        guard case .annotation(_, _, let text, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(text == "Low disk space")
    }

    @Test("##[error] text with leading space is trimmed")
    func test_errorAnnotation_leadingSpace_trimmed() {
        let result = parseLogLines("##[error] Build failed")
        guard case .annotation(_, _, let text, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(text == "Build failed")
    }

    @Test("##[notice] text with leading space is trimmed")
    func test_noticeAnnotation_leadingSpace_trimmed() {
        let result = parseLogLines("##[notice] Cache miss")
        guard case .annotation(_, _, let text, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(text == "Cache miss")
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

    @Test("##[debug] produces .dimmed")
    func test_debugDirective_producesDimmed() {
        let result = parseLogLines("##[debug]Evaluating condition")
        #expect(result.count == 1)
        guard case .dimmed(_, let text, let groupID) = result[0] else { Issue.record("Expected .dimmed"); return }
        #expect(text == "Evaluating condition")
        #expect(groupID == nil)
    }

    @Test("##[command] with leading space is trimmed")
    func test_commandDirective_leadingSpace_trimmed() {
        let result = parseLogLines("##[command] /usr/bin/bash")
        guard case .dimmed(_, let text, _) = result[0] else { Issue.record("Expected .dimmed"); return }
        #expect(text == "/usr/bin/bash")
    }

    @Test("##[command] inside a group retains groupID")
    func test_commandInsideGroup_retainsGroupID() {
        let raw = "##[group]Run step\n##[command]/usr/bin/bash -e script.sh\n##[endgroup]"
        let result = parseLogLines(raw)
        #expect(result.count == 2)
        guard case .groupHeader(let gid, _) = result[0] else { Issue.record("Expected .groupHeader at [0]"); return }
        guard case .dimmed(_, let text, let groupID) = result[1] else { Issue.record("Expected .dimmed at [1]"); return }
        #expect(text == "/usr/bin/bash -e script.sh")
        #expect(groupID == gid)
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

    @Test("Unknown ##[ directive produces .dimmed (stop-commands)")
    func test_unknownDirective_stopCommands_isDimmed() {
        let directive = "##[" + "stop-commands]token"
        let result = parseLogLines(directive)
        #expect(result.count == 1)
        guard case .dimmed(_, _, _) = result[0] else { Issue.record("Expected .dimmed at [0]"); return }
    }

    // MARK: - Empty input

    @Test("Empty string returns empty array")
    func test_emptyInput() {
        #expect(parseLogLines("").isEmpty)
    }
}
