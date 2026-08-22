// ANSIAttributedStringTests.swift
// RunBotCoreTests
import SwiftUI
import XCTest
@testable import RunBotCore

/// Unit tests for `ansiAttributedString(_:baseColor:font:)`.
///
/// Five consolidated contracts:
///   sgrStyleStateContract        - reset, bold, dim, bold+colour, multiple segments
///   sgrColorCodeContract         - all supported standard+bright codes
///   unknownAndMalformedSGRContract - unsupported / malformed sequences
///   osc8HyperlinkContract        - valid ST/BEL links, close, mixed SGR
///   malformedOSC8Contract        - no terminator, incomplete close, text preservation
final class ANSIAttributedStringTests: XCTestCase {

    private let esc  = "\u{001B}"
    private let base: Color = .white
    private let font: Font  = .system(size: 11, design: .monospaced)

    // MARK: - 1. SGR state contract

    func test_sgrStyleStateContract() {
        typealias Verify = (AttributedString) -> Void
        struct Case {
            let label: String
            let input: String
            let expectedText: String
            let verify: Verify
        }

        let esc  = self.esc
        let base = self.base
        let font = self.font

        let cases: [Case] = [
            Case(
                label: "reset restores base",
                input: "\(esc)[31mred\(esc)[0mplain",
                expectedText: "redplain",
                verify: { result in
                    let runs = Array(result.runs)
                    XCTAssertGreaterThanOrEqual(runs.count, 2)
                    XCTAssertEqual(runs.last?.foregroundColor, base)
                }
            ),
            Case(
                label: "bold",
                input: "\(esc)[1mbold\(esc)[0m",
                expectedText: "bold",
                verify: { result in
                    let boldRun = Array(result.runs).first { $0.font != nil && $0.font != font }
                    XCTAssertNotNil(boldRun, "Expected a bold-font run for \\e[1m")
                }
            ),
            Case(
                label: "dim",
                input: "\(esc)[2mdim\(esc)[0m",
                expectedText: "dim",
                verify: { result in
                    let dimRun = Array(result.runs).first { $0.foregroundColor != nil }
                    XCTAssertNotEqual(dimRun?.foregroundColor, base)
                }
            ),
            Case(
                label: "combined bold and colour",
                input: "\(esc)[1;32mbold-green\(esc)[0m",
                expectedText: "bold-green",
                verify: { result in
                    let run = Array(result.runs).first { $0.foregroundColor != base && $0.foregroundColor != nil }
                    XCTAssertNotNil(run, "Expected a coloured run for bold-green")
                    XCTAssertNotEqual(run?.font, font, "Expected bold font for bold-green")
                }
            ),
            Case(
                label: "dim plus colour preserves opacity",
                input: "\(esc)[2m\(esc)[32mtext\(esc)[0m",
                expectedText: "text",
                verify: { result in
                    let coloured = Array(result.runs).first { $0.foregroundColor != nil }
                    XCTAssertNotEqual(coloured?.foregroundColor, base,
                        "dim+colour should resolve to the ANSI colour, not base")
                    if let c = coloured?.foregroundColor,
                       let resolved = c.cgColor,
                       let components = resolved.components {
                        XCTAssertLessThan(components.last ?? 1.0, 1.0,
                            "dim must reduce opacity of the resolved colour")
                    }
                }
            ),
        ]

        for testCase in cases {
            let result = ansiAttributedString(testCase.input, baseColor: base, font: font)
            XCTAssertEqual(String(result.characters), testCase.expectedText, testCase.label)
            testCase.verify(result)
        }
    }

    // MARK: - 2. Colour code contract

    func test_sgrColorCodeContract() {
        let codes = [31, 32, 33, 34, 35, 36, 90, 91, 92, 93, 94, 95, 96]
        for code in codes {
            let result = ansiAttributedString(
                "\(esc)[\(code)mtext\(esc)[0m",
                baseColor: base, font: font
            )
            XCTAssertEqual(String(result.characters), "text", "code \(code)")
            let coloured = Array(result.runs).first {
                $0.foregroundColor != base && $0.foregroundColor != nil
            }
            XCTAssertNotNil(coloured, "code \(code): expected a coloured run")
        }
    }

    // MARK: - 3. Unknown and malformed SGR contract

    func test_unknownAndMalformedSGRContract() {
        let cases: [(label: String, input: String, expectedText: String)] = [
            ("unknown code 99 stripped",
             "\(esc)[99mtext\(esc)[0m",
             "text"),
            ("truncated escape text preserved",
             "hello\(esc)[31",
             "hello"),
            ("escape without m terminator drops tail",
             "before\(esc)[31Xafter",
             "before"),
            ("non-numeric code",
             "\(esc)[abcmtext",
             "text"),
        ]

        for testCase in cases {
            let result = ansiAttributedString(testCase.input, baseColor: base, font: font)
            XCTAssertEqual(
                String(result.characters), testCase.expectedText,
                testCase.label
            )
        }
    }

    // MARK: - 4. OSC 8 hyperlink contract

    func test_osc8HyperlinkContract() {
        let st  = "\(esc)\\"
        let bel = "\u{0007}"

        // ST-terminated link: text, URL, close, plain suffix
        let st_input = "\(esc)]8;;https://example.com\(st)click here\(esc)]8;;\(st)"
        let st_result = ansiAttributedString(st_input, baseColor: base, font: font)
        XCTAssertEqual(String(st_result.characters), "click here")
        let stLinked = Array(st_result.runs).first { $0.link != nil }
        XCTAssertNotNil(stLinked, "Expected a run with .link set")
        XCTAssertEqual(stLinked?.link, URL(string: "https://example.com"))

        // Close resets link: trailing plain text must have no link
        let close_input = "\(esc)]8;;https://example.com\(st)linked\(esc)]8;;\(st)plain"
        let close_result = ansiAttributedString(close_input, baseColor: base, font: font)
        XCTAssertEqual(String(close_result.characters), "linkedplain")
        XCTAssertNil(Array(close_result.runs).last?.link,
            "Plain text after closing OSC 8 must have no link")

        // BEL-terminated link
        let bel_input = "\(esc)]8;;https://example.com\(bel)click\(esc)]8;;\(bel)"
        let bel_result = ansiAttributedString(bel_input, baseColor: base, font: font)
        XCTAssertEqual(String(bel_result.characters), "click",
            "BEL must be consumed, not appear in output characters")
        let belLinked = Array(bel_result.runs).first { $0.link != nil }
        XCTAssertNotNil(belLinked, "Expected a run with .link set for BEL-terminated OSC 8")
        XCTAssertEqual(belLinked?.link, URL(string: "https://example.com"))

        // SGR colour + OSC 8: run must carry both colour and link
        let mixed_input = "\(esc)[32m\(esc)]8;;https://example.com\(st)green link\(esc)]8;;\(st)\(esc)[0m"
        let mixed_result = ansiAttributedString(mixed_input, baseColor: base, font: font)
        XCTAssertEqual(String(mixed_result.characters), "green link")
        let linkedRun = Array(mixed_result.runs).first { $0.link != nil }
        XCTAssertNotNil(linkedRun, "Expected a run with .link set")
        XCTAssertEqual(linkedRun?.link, URL(string: "https://example.com"))
        XCTAssertNotEqual(linkedRun?.foregroundColor, base,
            "The linked run must also carry the SGR green colour")
    }

    // MARK: - 5. Malformed OSC 8 contract

    func test_malformedOSC8Contract() {
        let cases: [(label: String, input: String, expectedText: String)] = [
            ("no terminator — text before preserved",
             "before\(esc)]8;;https://example.com",
             "before"),
            ("text after with no terminator intentionally dropped",
             "before\(esc)]8;;https://example.comafter",
             "before"),
        ]

        for testCase in cases {
            let result = ansiAttributedString(testCase.input, baseColor: base, font: font)
            XCTAssertEqual(
                String(result.characters), testCase.expectedText,
                testCase.label
            )
            // No accidental hyperlink attribute on any run
            for run in result.runs {
                XCTAssertNil(run.link, "\(testCase.label): unexpected link attribute")
            }
        }
    }
}
