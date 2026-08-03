// ANSIAttributedStringTests.swift
// RunBotCoreTests
import SwiftUI
import XCTest
@testable import RunBotCore

/// Unit tests for `ansiAttributedString(_:baseColor:font:)`.
///
/// Covers the GitHub Actions ANSI SGR subset defined in issue #2413:
/// reset, bold, dim, standard colours (31–36), bright variants (90–96),
/// unknown codes (silently ignored), and the no-ANSI fast path.
final class ANSIAttributedStringTests: XCTestCase {

    private let esc = "\u{001B}"
    private let base: Color = .white
    private let font: Font = .system(size: 11, design: .monospaced)

    // MARK: - Fast path

    func test_noANSI_fastPath() {
        let result = ansiAttributedString("plain text", baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "plain text")
        XCTAssertEqual(result.foregroundColor, base)
    }

    // MARK: - Reset

    func test_reset() {
        // Red segment followed by reset — second segment should carry base colour.
        let input = "\(esc)[31mred\(esc)[0mplain"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "redplain")
        // After reset the trailing segment colour must be the base colour.
        let runs = Array(result.runs)
        XCTAssertGreaterThanOrEqual(runs.count, 2)
        let lastRun = runs.last!
        XCTAssertEqual(lastRun.foregroundColor, base)
    }

    // MARK: - Bold

    func test_bold() {
        let input = "\(esc)[1mbold\(esc)[0m"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "bold")
        // Bold segment must carry a font different from the base (bold variant applied).
        let runs = Array(result.runs)
        let boldRun = runs.first(where: { $0.font != nil && $0.font != font })
        XCTAssertNotNil(boldRun, "Expected a bold-font run for \\e[1m")
    }

    // MARK: - Dim

    func test_dim() {
        let input = "\(esc)[2mdim\(esc)[0m"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "dim")
        // Dim substitutes a reduced-opacity colour — must not equal base colour.
        let runs = Array(result.runs)
        let dimRun = runs.first(where: { $0.foregroundColor != nil })
        XCTAssertNotEqual(dimRun?.foregroundColor, base)
    }

    // MARK: - Standard colours (31–36)

    func test_standardColors() {
        let codes: [Int] = [31, 32, 33, 34, 35, 36]
        for code in codes {
            let input = "\(esc)[\(code)mtext\(esc)[0m"
            let result = ansiAttributedString(input, baseColor: base, font: font)
            XCTAssertEqual(String(result.characters), "text", "code \(code): text must be preserved")
            let coloured = Array(result.runs).first(where: { $0.foregroundColor != base && $0.foregroundColor != nil })
            XCTAssertNotNil(coloured, "code \(code): expected a coloured run")
        }
    }

    // MARK: - Bright variants (90–96)

    func test_brightVariants() {
        let codes: [Int] = [90, 91, 92, 93, 94, 95, 96]
        for code in codes {
            let input = "\(esc)[\(code)mtext\(esc)[0m"
            let result = ansiAttributedString(input, baseColor: base, font: font)
            XCTAssertEqual(String(result.characters), "text", "code \(code): text must be preserved")
            let coloured = Array(result.runs).first(where: { $0.foregroundColor != base && $0.foregroundColor != nil })
            XCTAssertNotNil(coloured, "code \(code): expected a coloured run")
        }
    }

    // MARK: - Unknown codes silently stripped

    func test_unknownCodeStripped() {
        // Code 99 is outside the supported set — must not crash, text must survive,
        // and no colour attribute should be applied (falls back to base colour).
        let input = "\(esc)[99mtext\(esc)[0m"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "text")
        // All runs should carry base colour (no colour applied for code 99).
        for run in result.runs {
            if let c = run.foregroundColor {
                XCTAssertEqual(c, base, "Unknown code must not produce a non-base colour")
            }
        }
    }

    // MARK: - Semicolon-separated codes

    func test_semicolonCodes_boldAndColour() {
        // \e[1;32m — bold + green in a single sequence.
        let input = "\(esc)[1;32mbold-green\(esc)[0m"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "bold-green")
        let run = Array(result.runs).first(where: { $0.foregroundColor != base && $0.foregroundColor != nil })
        XCTAssertNotNil(run, "Expected a coloured run for bold-green")
        XCTAssertNotEqual(run?.font, font, "Expected bold font for bold-green")
    }
}
