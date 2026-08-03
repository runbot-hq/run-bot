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

    func test_dimPlusColour() {
        // \e[2m\e[32m: dim then green. The rendered colour must be green-ish
        // (not the base colour) and must have reduced opacity (< 1.0).
        let input = "\(esc)[2m\(esc)[32mtext\(esc)[0m"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "text")
        let runs = Array(result.runs)
        let coloured = runs.first(where: { $0.foregroundColor != nil })
        // Colour must not be the base colour (green, not base)
        XCTAssertNotEqual(coloured?.foregroundColor, base,
            "dim+colour should resolve to the ANSI colour, not base")
        // Opacity must be reduced (dim applied as .opacity(0.5) on resolved colour)
        if let c = coloured?.foregroundColor,
           let resolved = c.cgColor,
           let components = resolved.components {
            // alpha component is the last one in RGBA
            XCTAssertLessThan(components.last ?? 1.0, 1.0,
                "dim must reduce opacity of the resolved colour")
        }
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

    // MARK: - Malformed / truncated escape

    func test_malformedEscape_trailingTextPreserved() {
        // Truncated escape sequence — missing `m` terminator.
        // Everything before the ESC must be present; the partial escape
        // itself may be dropped, but no silent loss of preceding text.
        let input = "hello\(esc)[31"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "hello",
            "Text preceding a truncated escape must be preserved exactly — no duplication, no raw ESC bytes")
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

    // MARK: - OSC 8 hyperlinks

    func test_osc8_linkAttribute() {
        // Basic OSC 8: \e]8;;url\e\ link text \e]8;;\e\
        let st = "\(esc)\\"
        let input = "\(esc)]8;;https://example.com\(st)click here\(esc)]8;;\(st)"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "click here")
        let runs = Array(result.runs)
        let linked = runs.first(where: { $0.link != nil })
        XCTAssertNotNil(linked, "Expected a run with .link set")
        XCTAssertEqual(linked?.link, URL(string: "https://example.com"))
    }

    func test_osc8_closingResetsLink() {
        // Open link, text, close link, then plain text — second run must have no link.
        let st = "\(esc)\\"
        let input = "\(esc)]8;;https://example.com\(st)linked\(esc)]8;;\(st)plain"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "linkedplain")
        let runs = Array(result.runs)
        let lastRun = runs.last
        XCTAssertNil(lastRun?.link, "Plain text after closing OSC 8 must have no link")
    }

    func test_osc8_malformed_noTerminator() {
        // Truncated OSC 8 — no ST or BEL terminator.
        // Text before the sequence must be preserved; no crash.
        let input = "before\(esc)]8;;https://example.com"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "before",
            "Text before a malformed OSC 8 must be preserved; no raw ESC bytes")
    }

    func test_osc8_mixedWithSGR() {
        // SGR green colour combined with OSC 8 link — run must have both attributes.
        let st = "\(esc)\\"
        let input = "\(esc)[32m\(esc)]8;;https://example.com\(st)green link\(esc)]8;;\(st)\(esc)[0m"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "green link")
        let runs = Array(result.runs)
        let linkedRun = runs.first(where: { $0.link != nil })
        XCTAssertNotNil(linkedRun, "Expected a run with .link set")
        XCTAssertEqual(linkedRun?.link, URL(string: "https://example.com"))
        XCTAssertNotEqual(linkedRun?.foregroundColor, base,
            "The linked run must also carry the SGR green colour")
    }

    func test_osc8_malformed_textAfterPreserved() {
        // Malformed OSC 8 mid-line — text before is preserved, text after is dropped (intentional).
        let input = "before\(esc)]8;;https://example.comafter"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "before",
            "Text before malformed OSC preserved; text after intentionally dropped (no terminator)")
    }

    func test_osc8_belTerminator() {
        // BEL-terminated OSC 8 variant.
        let bel = "\u{0007}"
        let input = "\(esc)]8;;https://example.com\(bel)click\(esc)]8;;\(bel)"
        let result = ansiAttributedString(input, baseColor: base, font: font)
        XCTAssertEqual(String(result.characters), "click",
            "BEL must be consumed, not appear in output characters")
        let runs = Array(result.runs)
        let linked = runs.first(where: { $0.link != nil })
        XCTAssertNotNil(linked, "Expected a run with .link set for BEL-terminated OSC 8")
        XCTAssertEqual(linked?.link, URL(string: "https://example.com"))
    }
}
