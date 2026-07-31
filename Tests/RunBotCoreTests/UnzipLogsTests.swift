// UnzipLogsTests.swift
// RunBotCoreTests
//
// Tests for unzipLogs / unzipLogsTyped against real ZIP bytes (issue #2369).
//
// These tests do NOT inject a ZipExtractor stub — the real /usr/bin/unzip
// subprocess is executed. This exercises the extraction path that the
// stub-based FetchStepLogTests cannot reach.
//
// The fixture ZIP contains two files mirroring the exact structure of the
// failing job from #2358:
//   release/2_Checkout.txt   — timestamp prefix + ANSI colour codes
//   release/7_Complete job.txt — synthetic step, no ##[group] markers
//
// Fixture generation (run once; result is committed as fixtureZipBase64):
//   mkdir -p /tmp/release
//   printf '2026-07-31T04:34:20.0000000Z \033[32mCheckout output\033[0m\n' \
//     > "/tmp/release/2_Checkout.txt"
//   printf '2026-07-31T04:34:23.0000000Z Cleaning up orphan processes\n' \
//     > "/tmp/release/7_Complete job.txt"
//   printf '2026-07-31T04:34:23.0000001Z ##[warning]Node.js 20 is deprecated.\n' \
//     >> "/tmp/release/7_Complete job.txt"
//   cd /tmp && zip -r logs.zip release/
//   base64 logs.zip | pbcopy

import Foundation
import Testing
@testable import RunBotCore

// MARK: - Fixture

/// Base64-encoded ZIP of the two-file test fixture.
/// Generated once from /tmp/release — see file header for the shell commands.
private let fixtureZipBase64 =
    "UEsDBBQAAAAIACp7/1zH8jSbMgAAADYAAAAWAAAAcmVsZWFzZS8yX0NoZWNrb3V0LnR4dDMyMD" +
    "LTNTDXNTYMMTCxMjaxMjLQM4CAKAXpaGOjXOeM1OTs/NISBSAuKC2RjjbI5QIAUEsDBBQAAAAI" +
    "ACp7/1x94DpHeAAAAKQAAAAaAAAAcmVsZWFzZS83X0NvbXBsZXRlIGpvYi50eHR1zbEKgzAURuH" +
    "dp/jB2RATacG1eycnS4dgbjUl5IbciK9fpEOnnv3jGG0unb52tp/0MNphNFbpbzNukVwKacWewS" +
    "VvLiEXXkiEpDF/ZT+jbR+HK6d93tmTeguMRhB4yoUWV8krTBvhxTHycT7cUgMnQXVlpYofaz5Q" +
    "SwECFAMUAAAACAAqe/9cx/I0mzIAAAA2AAAAFgAAAAAAAAAAAAAAgAEAAAAAcmVsZWFzZS8yX0No" +
    "ZWNrb3V0LnR4dFBLAQIUAxQAAAAIACp7/1x94DpHeAAAAKQAAAAaAAAAAAAAAAAAAACAAWYAAABy" +
    "ZWxlYXNlLzdfQ29tcGxldGUgam9iLnR4dFBLBQYAAAAAAgACAIwAAAAWAQAAAAA="

private var fixtureZip: Data {
    Data(base64Encoded: fixtureZipBase64, options: .ignoreUnknownCharacters)!
}

// MARK: - UnzipLogsTests

@Suite("unzipLogs — real subprocess")
struct UnzipLogsTests {

    /// Confirms the ZIP extracts both expected files with their archive-relative names.
    /// The .txt extension must be stripped (unzipLogs contract: name has no extension).
    @Test("Extracts expected file names from fixture ZIP")
    func extractsExpectedFileNames() async {
        let files = await unzipLogs(fixtureZip)
        #expect(files.contains(where: { $0.name == "release/2_Checkout" }),
            "release/2_Checkout must be present after extraction")
        #expect(files.contains(where: { $0.name == "release/7_Complete job" }),
            "release/7_Complete job must be present after extraction")
    }

    /// Confirms unzipLogs preserves raw content — timestamps and ANSI codes must NOT
    /// be stripped at this layer. Stripping is cleanLogText()'s responsibility, not
    /// unzipLogs'. A regression here would make cleanLogText() a no-op in practice.
    @Test("Preserves raw timestamp prefix and ANSI codes (no stripping at extraction layer)")
    func preservesRawTimestampAndAnsi() async {
        let files = await unzipLogs(fixtureZip)
        let checkout = files.first(where: { $0.name == "release/2_Checkout" })
        #expect(checkout != nil, "release/2_Checkout must be present")
        #expect(checkout?.text.contains("2026-07-31T") == true,
            "Timestamp prefix must survive extraction unchanged")
        #expect(checkout?.text.contains("\u{1B}[") == true,
            "ANSI escape sequence must survive extraction unchanged")
    }

    /// Confirms ##[warning] directive lines are preserved verbatim.
    /// unzipLogs must not interpret or strip GitHub Actions directive prefixes.
    @Test("Preserves ##[warning] directive lines verbatim")
    func preservesWarningDirective() async {
        let files = await unzipLogs(fixtureZip)
        let completeJob = files.first(where: { $0.name == "release/7_Complete job" })
        #expect(completeJob != nil, "release/7_Complete job must be present")
        #expect(completeJob?.text.contains("##[warning]") == true,
            "##[warning] directive must survive extraction unchanged")
    }
}
