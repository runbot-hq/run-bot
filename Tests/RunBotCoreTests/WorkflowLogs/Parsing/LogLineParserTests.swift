// LogLineParserTests.swift
// RunBotCoreTests
import Testing
@testable import RunBotCore

@Suite("parseLogLines")
struct LogLineParserTests {

    @Test("Group structure: explicit close, grouped annotations, implicit close")
    func groupStructureContract() {
        // Explicit close + grouped warning retaining its group ID.
        let explicit = parseLogLines("""
            ##[group]Lint
            first
            ##[warning]Trailing whitespace
            ##[endgroup]
            after
            """)

        guard case .groupHeader(let groupID, let title) = explicit[0] else {
            Issue.record("Expected group header")
            return
        }
        #expect(title == "Lint")

        guard case .groupedLine(_, let first, let firstGroupID) = explicit[1] else {
            Issue.record("Expected grouped plain line")
            return
        }
        #expect(first == "first")
        #expect(firstGroupID == groupID)

        guard case .annotation(_, let level, let text, _, let warningGroupID) = explicit[2] else {
            Issue.record("Expected grouped annotation")
            return
        }
        #expect(level == .warning)
        #expect(text == "Trailing whitespace")
        #expect(warningGroupID == groupID)

        guard case .plain(_, let after) = explicit[3] else {
            Issue.record("Expected trailing plain line")
            return
        }
        #expect(after == "after")

        // A second header implicitly closes the first group.
        let implicit = parseLogLines("""
            ##[group]First
            one
            ##[group]Second
            two
            """)

        let headers = implicit.compactMap { line -> Int? in
            if case .groupHeader(let id, _) = line { return id }
            return nil
        }
        let groupedIDs = implicit.compactMap { line -> Int? in
            if case .groupedLine(_, _, let groupID) = line { return groupID }
            return nil
        }

        #expect(headers.count == 2)
        #expect(headers[0] != headers[1])
        #expect(groupedIDs == [headers[0], headers[1]])
    }

    @Test("Directive classification routes every wire format to the right case")
    func directiveClassificationContract() {
        // Built programmatically so the runner never sees a literal token in the
        // test source and tries to load a matcher file / redact the argument.
        let matcherDirective = "##[" + "add-matcher]matcher.json"
        let maskedDirective = "::" + "add-mask::secret-value"

        let result = parseLogLines("""
            plain text
            ##[command]/usr/bin/bash
            \(matcherDirective)
            ::debug::diagnostic
            \(maskedDirective)
            ##[section]Diagnostic Output
            """)

        // The masked line must be filtered out entirely (privacy contract).
        #expect(result.count == 5)

        guard case .plain(_, let plainText) = result[0] else {
            Issue.record("Expected .plain at [0]")
            return
        }
        #expect(plainText == "plain text")

        guard case .dimmed(_, let commandText, _) = result[1] else {
            Issue.record("Expected .dimmed at [1]")
            return
        }
        #expect(commandText == "/usr/bin/bash")

        guard case .dimmed(_, let matcherText, _) = result[2] else {
            Issue.record("Expected .dimmed at [2]")
            return
        }
        #expect(matcherText == matcherDirective)

        guard case .dimmed(_, let debugText, _) = result[3] else {
            Issue.record("Expected .dimmed at [3]")
            return
        }
        #expect(debugText == "diagnostic")

        guard case .section(_, let sectionTitle, _) = result[4] else {
            Issue.record("Expected .section at [4]")
            return
        }
        #expect(sectionTitle == "Diagnostic Output")

        // Suppression asserted separately so no assertion payload can echo the secret.
        #expect(parseLogLines(maskedDirective).isEmpty)
    }

    @Test("Annotation metadata across legacy and modern syntaxes")
    func annotationMetadataContract() {
        struct Case {
            let label: String
            let input: String
            let expectedLevel: LogLine.AnnotationLevel
            let expectedText: String
            let expectedTitle: String?
            let expectedFile: String?
            let expectedLine: Int?
            let expectedEndLine: Int?
        }

        let cases: [Case] = [
            Case(label: "legacy bare format",
                 input: "##[warning]Build warning",
                 expectedLevel: .warning,
                 expectedText: "Build warning",
                 expectedTitle: nil,
                 expectedFile: nil,
                 expectedLine: nil,
                 expectedEndLine: nil),
            Case(label: "modern bare format",
                 input: "::warning::Bare warning",
                 expectedLevel: .warning,
                 expectedText: "Bare warning",
                 expectedTitle: nil,
                 expectedFile: nil,
                 expectedLine: nil,
                 expectedEndLine: nil),
            Case(label: "error with partial metadata",
                 input: "::error file=src/main.swift,line=42::Build failed",
                 expectedLevel: .error,
                 expectedText: "Build failed",
                 expectedTitle: nil,
                 expectedFile: "src/main.swift",
                 expectedLine: 42,
                 expectedEndLine: nil),
            Case(label: "full metadata with percent-decoding",
                 input: "::warning title=Build Error%3A missing,file=src/main.swift,line=12,endLine=15::Message",
                 expectedLevel: .warning,
                 expectedText: "Message",
                 expectedTitle: "Build Error: missing",
                 expectedFile: "src/main.swift",
                 expectedLine: 12,
                 expectedEndLine: 15),
            Case(label: "notice bare format",
                 input: "::notice::Informational",
                 expectedLevel: .notice,
                 expectedText: "Informational",
                 expectedTitle: nil,
                 expectedFile: nil,
                 expectedLine: nil,
                 expectedEndLine: nil),
        ]

        for testCase in cases {
            let result = parseLogLines(testCase.input)
            guard case .annotation(_, let level, let text, let params, _) = result.first else {
                Issue.record("\(testCase.label): expected annotation")
                continue
            }
            #expect(level == testCase.expectedLevel, "\(testCase.label)")
            #expect(text == testCase.expectedText, "\(testCase.label)")
            #expect(params?.title == testCase.expectedTitle, "\(testCase.label)")
            #expect(params?.file == testCase.expectedFile, "\(testCase.label)")
            #expect(params?.line == testCase.expectedLine, "\(testCase.label)")
            #expect(params?.endLine == testCase.expectedEndLine, "\(testCase.label)")
        }
    }
}
