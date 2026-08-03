// ANSIAttributedString.swift
// RunBotCore
import AppKit
import SwiftUI

// MARK: - ansiAdaptive

/// Appearance-adaptive colour resolver for the ANSI palette.
/// Mirrors `Color.adaptive(light:dark:)` from RunBot.DesignTokens without that module's
/// dependency on a shared logger or `darkAppearanceNames` constant. Only called with
/// opaque sRGB values, so alpha loss through the NSColor bridge is irrelevant.
private func ansiAdaptive(light: Color, dark: Color) -> Color {
    Color(NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        guard let ns = NSColor(isDark ? dark : light).usingColorSpace(.genericRGB) else {
            return NSColor(isDark ? dark : light)
        }
        return ns
    })
}

// MARK: - ansiAttributedString

/// Converts a string that may contain GitHub Actions ANSI escape sequences into
/// an `AttributedString` with `.foregroundColor`, `.font`, and `.link` attributes
/// applied per segment.
///
/// Two escape families are handled:
///
/// **SGR** (`\e[…m`) — colour and style:
///
/// | Code       | Effect                                   |
/// |------------|------------------------------------------|
/// | `\e[0m`    | Reset all attributes                     |
/// | `\e[1m`    | Bold                                     |
/// | `\e[2m`    | Dim (opacity 0.5 applied to resolved colour) |
/// | `\e[31m`–`\e[36m` | Standard colours (red–cyan)     |
/// | `\e[90m`–`\e[96m` | Bright variants                  |
///
/// **OSC 8** (`\e]8;;url\e\\` or `\e]8;;url\u{0007}`) — hyperlinks:
///
/// | Sequence              | Effect                                |
/// |-----------------------|---------------------------------------|
/// | `\e]8;;url\e\\`       | Open hyperlink — sets `.link`         |
/// | `\e]8;;\e\\`          | Close hyperlink — clears `.link`      |
/// | BEL-terminated variant | `\e]8;;url\u{0007}` also supported   |
///
/// Any SGR code outside the supported set is **silently ignored**.
/// The `baseColor` and `font` become the container defaults, overridden
/// per-segment by recognised codes. SGR reset (`\e[0m`) does **not** clear
/// an active link — link state is controlled exclusively by OSC 8 open/close pairs.
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
    var currentLink: URL?            // nil = no active hyperlink

    var idx = text.startIndex
    var segmentStart = idx

    // Inline flush: appends text[segmentStart..<end] with current style state.
    let flush = { (end: String.Index) in
        guard segmentStart < end else { return }
        var seg = AttributedString(text[segmentStart..<end])
        let resolved = currentColor ?? baseColor
        seg.foregroundColor = isDim ? resolved.opacity(0.5) : resolved
        seg.font = isBold ? boldFont(font) : font
        seg.link = currentLink
        result += seg
    }

    while idx < text.endIndex {
        guard text[idx] == "\u{001B}",
              text.index(after: idx) < text.endIndex else {
            text.formIndex(after: &idx)
            continue
        }

        let nextIdx = text.index(after: idx)
        let nextChar = text[nextIdx]

        if nextChar == "[" {
            // SGR sequence (\e[...m) — flush text before this escape.
            flush(idx)

            // Advance past ESC[
            text.formIndex(&idx, offsetBy: 2)

            // Consume digits and semicolons up to the 'm' terminator.
            let codeStart = idx
            while idx < text.endIndex, text[idx] != "m" {
                text.formIndex(after: &idx)
            }
            guard idx < text.endIndex else {
                segmentStart = text.endIndex // suppress trailing flush — pre-escape text already in result
                break
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
        } else if nextChar == "]" {
            // MARK: OSC 8 sequence (\e]8;;url\e\ or \e]8;;url\u{0007})
            let oscStart = idx
            switch parseOSC8(in: text, from: &idx) {
            case .notOSC8:
                // Not OSC 8 — skip the ESC and keep scanning.
                text.formIndex(after: &idx)
                continue
            case .malformed:
                flush(oscStart) // flush text before malformed OSC
                segmentStart = text.endIndex
                // parseOSC8 already set idx = endIndex — while loop exits naturally.
            case .parsed(let url):
                flush(oscStart) // flush text before this OSC sequence
                currentLink = url
                segmentStart = idx
            }
        } else {
            // Unknown ESC sequence — skip the ESC byte and keep scanning.
            text.formIndex(after: &idx)
        }
    }

    flush(text.endIndex) // trailing segment

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
    // Standard colours — adaptive light/dark values.
    // Dark values match the xterm-256 terminal palette (dark-background convention).
    // Light values are darker/more-saturated variants tuned for WCAG AA contrast on white.
    case 31: color = ansiAdaptive(
        light: Color(red: 0.72, green: 0.11, blue: 0.11),
        dark: Color(red: 0.80, green: 0.20, blue: 0.20)) // red
    case 32: color = ansiAdaptive(
        light: Color(red: 0.08, green: 0.52, blue: 0.11),
        dark: Color(red: 0.18, green: 0.72, blue: 0.22)) // green
    case 33: color = ansiAdaptive(
        light: Color(red: 0.60, green: 0.42, blue: 0.00),
        dark: Color(red: 0.85, green: 0.65, blue: 0.13)) // yellow
    case 34: color = ansiAdaptive(
        light: Color(red: 0.10, green: 0.28, blue: 0.75),
        dark: Color(red: 0.24, green: 0.46, blue: 0.89)) // blue
    case 35: color = ansiAdaptive(
        light: Color(red: 0.50, green: 0.10, blue: 0.62),
        dark: Color(red: 0.69, green: 0.29, blue: 0.80)) // magenta
    case 36: color = ansiAdaptive(
        light: Color(red: 0.00, green: 0.48, blue: 0.54),
        dark: Color(red: 0.15, green: 0.68, blue: 0.73)) // cyan
    // Bright variants
    case 90: color = ansiAdaptive(
        light: Color(red: 0.35, green: 0.35, blue: 0.35),
        dark: Color(red: 0.55, green: 0.55, blue: 0.55)) // bright black
    case 91: color = ansiAdaptive(
        light: Color(red: 0.80, green: 0.15, blue: 0.15),
        dark: Color(red: 1.00, green: 0.40, blue: 0.40)) // bright red
    case 92: color = ansiAdaptive(
        light: Color(red: 0.10, green: 0.62, blue: 0.14),
        dark: Color(red: 0.38, green: 0.92, blue: 0.42)) // bright green
    case 93: color = ansiAdaptive(
        light: Color(red: 0.55, green: 0.38, blue: 0.00),
        dark: Color(red: 1.00, green: 0.85, blue: 0.35)) // bright yellow
    case 94: color = ansiAdaptive(
        light: Color(red: 0.18, green: 0.38, blue: 0.82),
        dark: Color(red: 0.45, green: 0.65, blue: 1.00)) // bright blue
    case 95: color = ansiAdaptive(
        light: Color(red: 0.62, green: 0.25, blue: 0.80),
        dark: Color(red: 0.88, green: 0.52, blue: 1.00)) // bright magenta
    case 96: color = ansiAdaptive(
        light: Color(red: 0.00, green: 0.55, blue: 0.62),
        dark: Color(red: 0.35, green: 0.90, blue: 0.95)) // bright cyan
    default: break // silently ignore unknown codes
    }
}

/// Returns a bold variant of `font`.
private func boldFont(_ font: Font) -> Font {
    font.bold()
}

// MARK: - OSC 8 parser

/// Result of attempting to parse an OSC 8 hyperlink sequence.
private enum OSC8Result {
    /// The sequence at the current index is not an OSC 8 sequence — caller should skip the ESC.
    case notOSC8
    /// OSC 8 header was valid but no ST (`\e\\`) or BEL terminator was found before end-of-string.
    case malformed
    /// Successfully parsed. `url` is non-nil for an opening sequence, nil for a closing one.
    case parsed(URL?)
}

/// Attempts to parse an OSC 8 hyperlink sequence starting at `idx` in `text`.
///
/// On entry `idx` points at the ESC (`\u{001B}`) of a potential OSC 8 sequence.
/// On exit:
/// - `.notOSC8`: `idx` is unchanged — caller advances past the ESC.
/// - `.malformed`: `idx` is at `text.endIndex`.
/// - `.parsed`: `idx` is positioned immediately after the ST or BEL terminator.
///
/// The function recognises both ST (`\e\\`) and BEL (`\u{0007}`) terminators.
/// The params field (`\e]8;params;url`) is correctly skipped — URL begins after
/// the *second* semicolon.
private func parseOSC8(in text: String, from idx: inout String.Index) -> OSC8Result {
    // Require \e]8;; — 5 characters minimum.
    let endIndex = text.endIndex
    let i1 = text.index(after: idx)              // ]
    guard i1 < endIndex else { return .notOSC8 }
    let i2 = text.index(after: i1)               // 8
    guard i2 < endIndex else { return .notOSC8 }
    let i3 = text.index(after: i2)               // first ;
    guard i3 < endIndex else { return .notOSC8 }
    let i4 = text.index(after: i3)               // second ;
    guard i4 < endIndex else { return .notOSC8 }

    guard text[i1] == "]", text[i2] == "8",
          text[i3] == ";", text[i4] == ";" else {
        return .notOSC8
    }

    // Advance past \e]8;; to the start of the URL.
    var scanIdx = text.index(after: i4)
    let urlStart = scanIdx

    // Scan for ST (\e\\) or BEL.
    while scanIdx < endIndex {
        if text[scanIdx] == "\u{0007}" {
            // BEL terminator.
            let url = String(text[urlStart..<scanIdx])
            text.formIndex(after: &scanIdx)  // consume BEL
            idx = scanIdx
            return .parsed(url.isEmpty ? nil : URL(string: url))
        } else if text[scanIdx] == "\u{001B}" {
            let afterEsc = text.index(after: scanIdx)
            if afterEsc < endIndex, text[afterEsc] == "\\" {
                // ST terminator.
                let url = String(text[urlStart..<scanIdx])
                text.formIndex(&scanIdx, offsetBy: 2)  // consume \e\\
                idx = scanIdx
                return .parsed(url.isEmpty ? nil : URL(string: url))
            }
        }
        text.formIndex(after: &scanIdx)
    }

    // Reached end of string without finding a terminator.
    idx = endIndex
    return .malformed
}
