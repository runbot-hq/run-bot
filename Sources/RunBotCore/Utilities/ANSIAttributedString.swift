// ANSIAttributedString.swift
// RunBotCore
import SwiftUI

// MARK: - ansiAttributedString

/// Converts a string that may contain GitHub Actions ANSI SGR escape sequences into
/// an `AttributedString` with `.foregroundColor` and `.font` attributes applied per
/// segment.
///
/// Only the subset that GitHub's own runner emits is handled:
///
/// | Code       | Effect                                   |
/// |------------|------------------------------------------|
/// | `\e[0m`    | Reset all attributes                     |
/// | `\e[1m`    | Bold                                     |
/// | `\e[2m`    | Dim (opacity 0.5 applied to resolved colour) |
/// | `\e[31m`–`\e[36m` | Standard colours (red–cyan)     |
/// | `\e[90m`–`\e[96m` | Bright variants                  |
///
/// Any code outside this set is **silently ignored** — it does not appear in the
/// returned `AttributedString`. The `baseColor` and `font` become the container
/// defaults, overridden per-segment by recognised ANSI codes.
///
/// **Fast path:** if `text` contains no ESC character (`\u{001B}`), the function
/// returns a plain `AttributedString(text)` with container attributes applied,
/// skipping the parse loop entirely.
///
/// - Parameters:
///   - text:      Raw log line text, potentially containing ANSI sequences.
///   - baseColor: The default foreground colour for unstyled segments.
///   - font:      The base font for the returned string.
/// - Returns: An `AttributedString` ready to pass to `Text(attributedString:)`.
public func ansiAttributedString(
    _ text: String,
    baseColor: Color,
    font: Font
) -> AttributedString {
    // Fast path: nothing to parse.
    guard text.contains("\u{001B}") else {
        var plain = AttributedString(text)
        plain.foregroundColor = baseColor
        plain.font = font
        return plain
    }

    var result = AttributedString()
    // Container defaults
    result.foregroundColor = baseColor
    result.font = font

    // Accumulated per-segment state.
    var currentColor: Color?         // nil = use baseColor
    var isBold = false
    var isDim  = false

    var idx = text.startIndex
    var segmentStart = idx

    while idx < text.endIndex {
        guard text[idx] == "\u{001B}",
              text.index(after: idx) < text.endIndex,
              text[text.index(after: idx)] == "[" else {
            text.formIndex(after: &idx)
            continue
        }

        // Flush the text segment before this escape sequence.
        if segmentStart < idx {
            var seg = AttributedString(text[segmentStart..<idx])
            let resolved = currentColor ?? baseColor
            seg.foregroundColor = isDim ? resolved.opacity(0.5) : resolved
            seg.font = isBold ? boldFont(font) : font
            result += seg
        }

        // Advance past ESC[
        text.formIndex(&idx, offsetBy: 2)

        // Consume digits and semicolons up to the 'm' terminator.
        let codeStart = idx
        while idx < text.endIndex, text[idx] != "m" {
            text.formIndex(after: &idx)
        }
        guard idx < text.endIndex else {
            break // pre-escape text already flushed above; drop partial escape
        }
        let codeStr = String(text[codeStart..<idx])
        text.formIndex(after: &idx)              // consume 'm'
        segmentStart = idx

        // Parse semicolon-separated codes and apply each.
        for part in codeStr.split(separator: ";", omittingEmptySubsequences: true) {
            guard let code = Int(part) else { continue }
            applyANSICode(code, color: &currentColor, bold: &isBold, dim: &isDim)
        }
        // Empty code string (bare `\e[m`) acts as reset.
        if codeStr.isEmpty {
            currentColor = nil; isBold = false; isDim = false
        }
    }

    // Flush trailing text segment.
    if segmentStart < text.endIndex {
        var seg = AttributedString(text[segmentStart...])
        let resolved = currentColor ?? baseColor
        seg.foregroundColor = isDim ? resolved.opacity(0.5) : resolved
        seg.font = isBold ? boldFont(font) : font
        result += seg
    }

    return result
}

// MARK: - Helpers

/// Applies a single ANSI SGR integer code to the mutable attribute state.
///
/// Codes outside the GitHub Actions subset are silently ignored (no state change).
private func applyANSICode(
    _ code: Int,
    color: inout Color?,
    bold: inout Bool,
    dim: inout Bool
) {
    switch code {
    case 0:  color = nil; bold = false; dim = false
    case 1:  bold = true
    case 2:  dim = true
    // Standard colours
    case 31: color = Color(red: 0.80, green: 0.20, blue: 0.20) // red
    case 32: color = Color(red: 0.18, green: 0.72, blue: 0.22) // green
    case 33: color = Color(red: 0.85, green: 0.65, blue: 0.13) // yellow
    case 34: color = Color(red: 0.24, green: 0.46, blue: 0.89) // blue
    case 35: color = Color(red: 0.69, green: 0.29, blue: 0.80) // magenta
    case 36: color = Color(red: 0.15, green: 0.68, blue: 0.73) // cyan
    // Bright variants
    case 90: color = Color(red: 0.55, green: 0.55, blue: 0.55) // bright black (dark grey)
    case 91: color = Color(red: 1.00, green: 0.40, blue: 0.40) // bright red
    case 92: color = Color(red: 0.38, green: 0.92, blue: 0.42) // bright green
    case 93: color = Color(red: 1.00, green: 0.85, blue: 0.35) // bright yellow
    case 94: color = Color(red: 0.45, green: 0.65, blue: 1.00) // bright blue
    case 95: color = Color(red: 0.88, green: 0.52, blue: 1.00) // bright magenta
    case 96: color = Color(red: 0.35, green: 0.90, blue: 0.95) // bright cyan
    default: break // silently ignore unknown codes
    }
}

/// Returns a bold variant of `font`.
private func boldFont(_ font: Font) -> Font {
    font.bold()
}
