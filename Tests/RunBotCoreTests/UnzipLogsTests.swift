// UnzipLogsTests.swift
// RunBotCoreTests
//
// Tests for unzipLogs / unzipLogsTyped against real ZIP bytes (issue #2369).
//
// These tests do NOT inject a ZipExtractor stub — the real /usr/bin/unzip
// subprocess is executed. This exercises the extraction path that the
// stub-based FetchStepLogTests cannot reach.
//
// Fixture: see TestSupport/TestFixtures.swift (fixtureZipBase64 / fixtureZip).
//
// ## Sandbox behaviour
// On GitHub Actions runners that block process spawning, unzipLogs returns [].
// Each test wraps its assertions in withKnownIssue(when: !unzipAvailable) so
// sandboxed CI produces an expected issue rather than a hard failure or a
// silent pass. If the sandbox is lifted, withKnownIssue surfaces a test
// failure because the known issue no longer reproduces.

import Foundation
import Testing
@testable import RunBotCore

@Suite("unzipLogs — real subprocess")
struct UnzipLogsTests {

    /// Confirms the ZIP extracts both expected files with their archive-relative names.
    /// The .txt extension must be stripped (unzipLogs contract: name has no extension).
    @Test("Extracts expected file names from fixture ZIP")
    func extractsExpectedFileNames() async {
        let files = await unzipLogs(fixtureZip)
        withKnownIssue(
            "unzip subprocess unavailable (sandboxed CI runner)",
            isIntermittent: true
        ) {
            #expect(files.contains(where: { $0.name == "release/2_Checkout" }),
                "release/2_Checkout must be present after extraction")
            #expect(files.contains(where: { $0.name == "release/7_Complete job" }),
                "release/7_Complete job must be present after extraction")
        } when: {
            !unzipAvailable
        }
    }

    /// Confirms unzipLogs preserves raw content — timestamps and ANSI codes must NOT
    /// be stripped at this layer. Stripping is cleanLogText()'s responsibility, not
    /// unzipLogs'. A regression here would make the stripping pipeline a silent no-op.
    @Test("Preserves raw timestamp prefix and ANSI codes (no stripping at extraction layer)")
    func preservesRawTimestampAndAnsi() async {
        let files = await unzipLogs(fixtureZip)
        let checkout = files.first(where: { $0.name == "release/2_Checkout" })
        withKnownIssue(
            "unzip subprocess unavailable (sandboxed CI runner)",
            isIntermittent: true
        ) {
            #expect(checkout != nil,
                "release/2_Checkout must be present")
            #expect(checkout?.text.contains("2026-07-31T") == true,
                "Timestamp prefix must survive extraction unchanged")
            #expect(checkout?.text.contains("\u{1B}[") == true,
                "ANSI escape sequence must survive extraction unchanged")
        } when: {
            !unzipAvailable
        }
    }

    /// Confirms ##[warning] directive lines are preserved verbatim.
    /// unzipLogs must not interpret or strip GitHub Actions directive prefixes.
    @Test("Preserves ##[warning] directive lines verbatim")
    func preservesWarningDirective() async {
        let files = await unzipLogs(fixtureZip)
        let completeJob = files.first(where: { $0.name == "release/7_Complete job" })
        withKnownIssue(
            "unzip subprocess unavailable (sandboxed CI runner)",
            isIntermittent: true
        ) {
            #expect(completeJob != nil,
                "release/7_Complete job must be present")
            #expect(completeJob?.text.contains("##[warning]") == true,
                "##[warning] directive must survive extraction unchanged")
        } when: {
            !unzipAvailable
        }
    }
}
