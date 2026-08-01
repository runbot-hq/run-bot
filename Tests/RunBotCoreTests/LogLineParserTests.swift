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
        guard case .annotation(_, let level, let text, _, let groupID) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(level == .warning)
        #expect(text == "Low disk space")
        #expect(groupID == nil)
    }

    @Test("##[error] produces .annotation with .error level")
    func test_errorAnnotation() {
        let result = parseLogLines("##[error]Build failed")
        #expect(result.count == 1)
        guard case .annotation(_, let level, let text, _, let groupID) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(level == .error)
        #expect(text == "Build failed")
        #expect(groupID == nil)
    }

    @Test("##[notice] produces .annotation with .notice level")
    func test_noticeAnnotation() {
        let result = parseLogLines("##[notice]Cache miss")
        #expect(result.count == 1)
        guard case .annotation(_, let level, let text, _, let groupID) = result[0] else { Issue.record("Expected .annotation"); return }
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
        guard case .annotation(_, let level, let text, _, let groupID) = result[1] else {
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
        guard case .annotation(_, _, let text, _, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(text == "Low disk space")
    }

    @Test("##[error] text with leading space is trimmed")
    func test_errorAnnotation_leadingSpace_trimmed() {
        let result = parseLogLines("##[error] Build failed")
        guard case .annotation(_, _, let text, _, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(text == "Build failed")
    }

    @Test("##[notice] text with leading space is trimmed")
    func test_noticeAnnotation_leadingSpace_trimmed() {
        let result = parseLogLines("##[notice] Cache miss")
        guard case .annotation(_, _, let text, _, _) = result[0] else { Issue.record("Expected .annotation"); return }
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

    // MARK: - ::debug:: directive

    @Test("::debug:: produces .dimmed")
    func test_colonDebug_isDimmed() {
        let result = parseLogLines("::debug::Set the Octocat variable")
        #expect(result.count == 1)
        guard case .dimmed(_, let text, let groupID) = result[0] else { Issue.record("Expected .dimmed at [0]"); return }
        #expect(text == "Set the Octocat variable")
        #expect(groupID == nil)
    }

    // MARK: - ::add-mask:: and ::echo:: filter

    @Test("::add-mask:: is filtered out entirely — produces no LogLine")
    func test_addMask_isFiltered() {
        // Build the string programmatically so the runner never sees the literal
        // ::add-mask:: token and tries to redact the argument in CI log output.
        let line = "::" + "add-mask::supersecret"
        let result = parseLogLines(line)
        #expect(result.isEmpty, "::add-mask:: must produce no LogLine")
    }

    @Test("::echo:: is filtered out entirely — produces no LogLine")
    func test_echo_isFiltered() {
        let result = parseLogLines("::echo::on")
        #expect(result.isEmpty, "::echo:: must produce no LogLine")
    }

    @Test("::add-mask:: between plain lines leaves plain lines intact")
    func test_addMask_betweenPlainLines() {
        let line = "::" + "add-mask::topsecret"
        let raw = "before\n\(line)\nafter"
        let result = parseLogLines(raw)
        #expect(result.count == 2)
        guard case .plain(_, let t0) = result[0] else { Issue.record("Expected .plain at [0]"); return }
        guard case .plain(_, let t1) = result[1] else { Issue.record("Expected .plain at [1]"); return }
        #expect(t0 == "before")
        #expect(t1 == "after")
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

    @Test("::WARNING:: mixed-case produces .annotation — case-insensitive per ActionCommandManager.cs OrdinalIgnoreCase")
    func test_colonWarning_upperCase() {
        let result = parseLogLines("::WARNING::Uppercase command")
        #expect(result.count == 1)
        guard case .annotation(_, let level, let text, _, _) = result[0] else {
            Issue.record("Expected .annotation at [0]"); return
        }
        #expect(level == .warning)
        #expect(text == "Uppercase command")
    }

    @Test("::warning-extra::msg does not false-match ::warning — word-boundary guard")
    func test_colonWarning_extendedCommandName_doesNotFalseMatch() {
        // ::warning-extra:: starts with ::warning but is a different command name.
        // It must not be classified as a .warning annotation.
        let result = parseLogLines("::warning-extra::some message")
        #expect(result.count == 1)
        guard case .dimmed = result[0] else {
            Issue.record("Expected .dimmed at [0], not a false .annotation"); return
        }
    }

    @Test("::error:: bare format produces .annotation with .error level")
    func test_colonError_bare() {
        let result = parseLogLines("::error::Build failed")
        #expect(result.count == 1)
        guard case .annotation(_, let level, _, _, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(level == .error)
    }

    @Test("::notice:: bare format produces .annotation with .notice level")
    func test_colonNotice_bare() {
        let result = parseLogLines("::notice::FYI")
        #expect(result.count == 1)
        guard case .annotation(_, let level, _, _, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(level == .notice)
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

    @Test("::error with file and line but no title")
    func test_colonError_fileAndLine_noTitle() {
        let result = parseLogLines("::error file=src/main.swift,line=42::cannot convert value")
        guard case .annotation(_, _, let text, let params, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(text == "cannot convert value")
        #expect(params?.file == "src/main.swift")
        #expect(params?.line == 42)
        #expect(params?.title == nil)
    }

    @Test("::warning with only title param")
    func test_colonWarning_onlyTitle() {
        let result = parseLogLines("::warning title=My Title::message text")
        guard case .annotation(_, _, let text, let params, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(text == "message text")
        #expect(params?.title == "My Title")
        #expect(params?.file == nil)
        #expect(params?.line == nil)
    }

    // MARK: - parseAnnotationParams

    @Test("::warning with only line= (no file=) yields nil params.file and nil fileBadge-equivalent")
    func test_colonWarning_lineOnlyNoFile() {
        let result = parseLogLines("::warning line=42::bare line number")
        guard case .annotation(_, _, let text, let params, _) = result[0] else { Issue.record("Expected .annotation"); return }
        #expect(text == "bare line number")
        #expect(params?.line == 42)
        #expect(params?.file == nil)
        // fileBadge suppresses the badge when file is absent — no ":42" should appear
    }

    @Test("parseAnnotationParams returns nil for empty string")
    func test_parseAnnotationParams_empty() {
        #expect(parseAnnotationParams("") == nil)
    }

    @Test("parseAnnotationParams ignores unknown keys")
    func test_parseAnnotationParams_unknownKeys() {
        let params = parseAnnotationParams("col=5,unknown=foo")
        #expect(params == nil)
    }

    @Test("parseAnnotationParams handles malformed pair gracefully")
    func test_parseAnnotationParams_malformedPair() {
        let params = parseAnnotationParams("title=Good,badpair,line=3")
        #expect(params?.title == "Good")
        #expect(params?.line == 3)
    }

    // MARK: - ##[section]

    @Test("##[section] produces .section with correct title")
    func test_sectionDirective() {
        let result = parseLogLines("##[section]Diagnostic Output")
        #expect(result.count == 1)
        guard case .section(_, let title, _) = result[0] else { Issue.record("Expected .section at [0]"); return }
        #expect(title == "Diagnostic Output")
    }

    @Test("##[section] with leading space in title is trimmed")
    func test_sectionDirective_leadingSpaceTrimmed() {
        let result = parseLogLines("##[section] My Section")
        guard case .section(_, let title, _) = result[0] else { Issue.record("Expected .section"); return }
        #expect(title == "My Section")
    }

    @Test("##[section] does not affect currentGroupID")
    func test_sectionDirective_doesNotOpenGroup() {
        let raw = "##[section]Header\nplain line"
        let result = parseLogLines(raw)
        #expect(result.count == 2)
        guard case .section(_, _, _) = result[0] else { Issue.record("Expected .section at [0]"); return }
        guard case .plain(_, _) = result[1] else { Issue.record("Expected .plain at [1]"); return }
    }
}

