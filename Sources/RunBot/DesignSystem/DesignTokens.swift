// DesignTokens.swift
// RunBot
import AppKit
import OSLog
import RunBotCore
import SwiftUI

// MARK: - Adaptive Color Helper

/// The set of NSAppearance names that map to "dark" mode.
/// Shared by `Color.adaptive` and `Color.adaptiveGrayscale` so that adding a new
/// dark-family appearance (e.g. a future high-contrast variant) only requires
/// a single edit.
///
/// SCOPE NOTE: This is `private` at file scope intentionally — both consumers
/// (`adaptive` and `adaptiveGrayscale`) live in this file, and `private` is the
/// tightest correct access level. If either helper is ever moved to a separate
/// file, promote this constant to `fileprivate` or extract it into a shared
/// internal file; do NOT duplicate the array.
private let darkAppearanceNames: [NSAppearance.Name] = [
    .darkAqua,
    .vibrantDark,
    .accessibilityHighContrastDarkAqua,
    .accessibilityHighContrastVibrantDark
]

private let logger = Logger(subsystem: "com.runbot-hq.RunBot", category: "DesignTokens")

/// Helpers for creating appearance-adaptive `Color` values that respond to light/dark mode.
extension Color {
    /// Returns a color that resolves to `light` in light-appearance contexts and `dark` in dark-appearance contexts.
    /// Covers all dark-family appearances including vibrant dark and high-contrast variants.
    ///
    /// Implementation note: inside the dynamic `NSColor` provider, `NSColor(resolved)` converts
    /// the SwiftUI `Color` to `NSColor` via AppKit's init(_ color: Color) bridge. **This bridge is
    /// itself the lossy step for sub-1% alpha** — it can silently drop near-zero alpha values before
    /// `usingColorSpace` is ever called. `usingColorSpace(.genericRGB)` converts color space only;
    /// it does not recover alpha that was already dropped by the bridge.
    ///
    /// The real safeguard is that all `adaptive(light:dark:)` call sites pass **opaque** sRGB
    /// `Color` values (status colors, text colors) where alpha loss is irrelevant. If a call site
    /// ever needs sub-1% alpha, it must use `adaptiveGrayscale` instead — which constructs
    /// `NSColor(white:alpha:)` directly, bypassing the SwiftUI bridge entirely.
    ///
    /// `usingColorSpace` guards against a nil return (e.g. catalog or pattern colors that can't
    /// be expressed in genericRGB). If it returns nil — which is unreachable with current sRGB
    /// call sites — `logger.fault` fires in all builds and `assertionFailure` fires in Debug.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: darkAppearanceNames + [.aqua])
            let resolved = darkAppearanceNames.contains(best ?? .aqua) ? dark : light
            // NOTE: NSColor(resolved) is the lossy step for sub-1% alpha — usingColorSpace
            // converts color space only and does NOT recover alpha dropped by the bridge above.
            // This guard catches nil returns (e.g. catalog/pattern colors) — not alpha loss.
            // All current call sites pass opaque sRGB colors, so both failure modes are unreachable.
            guard let ns = NSColor(resolved).usingColorSpace(.genericRGB) else {
                // os_log fires in all build configurations (including Release).
                // assertionFailure is a Debug-only safety net on top.
                logger.fault(
                    "Color.adaptive: usingColorSpace(.genericRGB) returned nil — surface will render clear. " +
                    "Ensure all adaptive(light:dark:) call sites pass plain sRGB Color values."
                )
                assertionFailure(
                    "Color.adaptive: could not convert resolved color to genericRGB. " +
                    "Ensure all adaptive(light:dark:) call sites pass plain sRGB Color values."
                )
                return .clear
            }
            return ns
        })
    }

    /// Builds a dynamic `Color` from explicit grayscale `(white:alpha:)` components for light and dark appearances.
    ///
    /// `white` is the full NSColor grayscale axis: **0.0 = black, 1.0 = white**, intermediate
    /// values are grey. Both endpoints are valid and intentional — `rbBorderSubtle` uses
    /// `white: 0.0` (black tint) in light mode and `white: 1.0` (white tint) in dark mode.
    /// These are not edge cases; they are standard grayscale values.
    ///
    /// - Both `white` and `alpha` must be in `0...1`.
    /// - A `precondition` enforces this range. **Unlike `assert`, `precondition` fires in both
    ///   Debug and Release builds.** This is intentional: out-of-range token values are
    ///   programmer errors that must never ship. A crash at token-definition time (during
    ///   development or CI) is the correct contract — it is far preferable to a silent visual
    ///   artefact in production. All current call sites pass hardcoded literals within range.
    ///   Do NOT downgrade to `assert` without understanding this tradeoff.
    ///
    /// Preferred over `adaptive(light:dark:)` when alpha is critical (e.g. near-zero glass
    /// surface tokens) because it constructs `NSColor(white:alpha:)` directly, bypassing any
    /// SwiftUI `Color` intermediate that could silently drop sub-1% alpha values (root cause
    /// of #2098).
    ///
    /// For full-colour (RGB) adaptive tokens, use `adaptive(light:dark:)` with explicit
    /// `Color(red:green:blue:)` values.
    static func adaptiveGrayscale(
        light: (white: Double, alpha: Double),
        dark:  (white: Double, alpha: Double)
    ) -> Color {
        // PLACEMENT NOTE: this precondition is intentionally OUTSIDE the NSColor closure.
        // It fires when adaptiveGrayscale(_:_:) is called (i.e. when the static var token
        // is accessed), not inside the provider which runs lazily per AppKit paint/resolve.
        // This is correct: out-of-range inputs are a programmer error caught at call time,
        // not an appearance-resolution error caught at render time.
        precondition(
            (0...1).contains(light.white)  && (0...1).contains(light.alpha) &&
            (0...1).contains(dark.white)   && (0...1).contains(dark.alpha),
            "adaptiveGrayscale: white and alpha components must be in 0...1. " +
            "light=\(light) dark=\(dark)"
        )
        return Color(NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: darkAppearanceNames + [.aqua])
            let components = darkAppearanceNames.contains(best ?? .aqua) ? dark : light
            return NSColor(white: components.white, alpha: components.alpha)
        })
    }
}

// MARK: - Color Tokens

/// Semantic color tokens used throughout RunBot for status, surface, and text styling.
extension Color {
    /// Primary blue accent — adaptive light/dark pair for in-progress status indicators.
    static let rbBlue = Color.adaptive(
        light: Color(red: 0.0, green: 0.48, blue: 1.0),
        dark:  Color(red: 0.3, green: 0.64, blue: 1.0)
    )
    /// Green success color — adaptive light/dark pair for completed / passing status.
    static let rbSuccess = Color.adaptive(
        light: Color(red: 0.18, green: 0.64, blue: 0.18),
        dark:  Color(red: 0.25, green: 0.80, blue: 0.25)
    )
    /// Amber warning color — adaptive light/dark pair for queued / pending status.
    static let rbWarning = Color.adaptive(
        light: Color(red: 0.80, green: 0.55, blue: 0.05),
        dark:  Color(red: 1.0,  green: 0.75, blue: 0.20)
    )
    /// Red danger color — adaptive light/dark pair for failed / error status.
    static let rbDanger = Color.adaptive(
        light: Color(red: 0.85, green: 0.18, blue: 0.18),
        dark:  Color(red: 1.0,  green: 0.35, blue: 0.35)
    )
    /// Primary accent alias — resolves to `rbBlue`.
    static let rbAccent = rbBlue

    // MARK: Surface & Border Tokens
    //
    // DESIGN TOKEN NOTE:
    // On macOS 26+ the panel chrome uses NSGlassEffectView which provides its own
    // backdrop blur and tinting. Surface tokens must use near-zero opacity so the
    // glass layer shows through. Pre-26 values use the existing vibrancy opacities.
    //
    // ⚠️ TRANSLUCENCY CONTRACT — DO NOT REMOVE THIS COMMENT.
    // NSVisualEffectView uses .hudWindow (.behindWindow). MUST stay opacity < 1.0.
    // ❌ NEVER set opacity 1.0 — kills vibrancy.
    // ❌ NEVER switch PanelChrome material back to .popover — warm brown tint.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    //
    // FIX (#2098): Surface tokens now use `adaptiveGrayscale` instead of
    // `adaptive(light:dark:)` + `.opacity()`. The old path converted a SwiftUI
    // `Color` (already carrying sub-1% opacity) to `NSColor`, which silently
    // dropped the alpha and rendered surfaces fully opaque in light mode.
    // `adaptiveGrayscale` passes the alpha directly to `NSColor(white:alpha:)`,
    // bypassing the lossy SwiftUI intermediate entirely.
    //
    // WHY static var AND NOT static let?
    // These tokens use `#available(macOS 26, *)` branching to return different
    // values at runtime. Swift does not allow stored static properties with
    // `#available` branching — the compiler requires a computed property for
    // runtime OS checks. `static var` is therefore required, not a style choice.
    // `adaptiveGrayscale` constructs a new NSColor closure on each access of these
    // static var tokens. Cost is negligible (four range-checks + closure alloc),
    // but these are not cached — static let is not possible with #available branching.

    /// Base panel background surface.
    /// macOS 26+: near-zero opacity so glass backdrop shows through.
    /// Pre-26: standard vibrancy opacities.
    static var rbSurface: Color {
        if #available(macOS 26, *) {
            return Color.adaptiveGrayscale(
                light: (white: 0.95, alpha: 0.04),
                dark:  (white: 0.11, alpha: 0.04)
            )
        } else {
            return Color.adaptiveGrayscale(
                light: (white: 0.95, alpha: 0.88),
                dark:  (white: 0.11, alpha: 0.45)
            )
        }
    }

    /// Elevated row/card surface — slightly lighter than `rbSurface`.
    /// macOS 26+: near-zero opacity so glass backdrop shows through.
    /// Pre-26: standard vibrancy opacities.
    static var rbSurfaceElevated: Color {
        if #available(macOS 26, *) {
            return Color.adaptiveGrayscale(
                light: (white: 0.88, alpha: 0.05),
                dark:  (white: 0.15, alpha: 0.05)
            )
        } else {
            return Color.adaptiveGrayscale(
                light: (white: 0.88, alpha: 0.92),
                dark:  (white: 0.15, alpha: 0.25)
            )
        }
    }

    /// Subtle border — low-contrast outline for cards and separators.
    ///
    /// NOTE: `white: 0.0` (light mode) and `white: 1.0` (dark mode) are correct and intentional.
    /// They are standard grayscale endpoints — black tint on light backgrounds, white tint on
    /// dark backgrounds. They are not edge cases or mistakes; do not "fix" them.
    /// macOS 26+: light opacity bumped to 0.12 for better visibility on glass.
    static var rbBorderSubtle: Color {
        if #available(macOS 26, *) {
            return Color.adaptiveGrayscale(
                light: (white: 0.0, alpha: 0.12), // black tint — correct, not an error
                dark:  (white: 1.0, alpha: 0.06)  // white tint — correct, not an error
            )
        } else {
            return Color.adaptiveGrayscale(
                light: (white: 0.0, alpha: 0.08),
                dark:  (white: 1.0, alpha: 0.06)
            )
        }
    }

    /// Primary text — high contrast body and heading text.
    static let rbTextPrimary = Color.adaptive(
        light: .black,
        dark:  .white
    )
    /// Secondary text — reduced-emphasis labels and descriptions.
    static let rbTextSecondary = Color.adaptive(
        light: Color(white: 0.40),
        dark:  Color(white: 0.55)
    )
    /// Tertiary text — lowest-emphasis metadata and timestamps.
    static let rbTextTertiary = Color.adaptive(
        light: Color(white: 0.58),
        dark:  Color(white: 0.39)
    )
}

// MARK: - Status helpers

/// UI-layer color extension for `RBStatus`.
/// `RBStatus` cases are defined in `RunBotCore/RBStatus.swift`.
extension RBStatus {
    /// The primary foreground color associated with this status.
    var color: Color {
        switch self {
        case .inProgress: return .rbBlue
        case .success:    return .rbSuccess
        case .failed:     return .rbDanger
        case .queued:     return .rbWarning
        case .unknown:    return .rbTextTertiary
        }
    }
}

// MARK: - Spacing & Geometry Tokens

/// Fixed spacing constants derived from an 8-pt grid. Use these instead of raw `CGFloat` literals.
enum RBSpacing {
    /// 2 pt — hairline gap between tightly packed elements.
    static let xxs: CGFloat = 2
    /// 4 pt — compact inner padding (e.g. badge insets).
    static let xs: CGFloat  = 4
    /// 6 pt — tight gap between related elements.
    static let sm: CGFloat  = 6
    /// 10 pt — default row horizontal padding.
    static let md: CGFloat  = 10
}

/// Corner-radius constants for consistent rounding across components.
enum RBRadius {
    /// 10 pt — standard card corner radius.
    static let card: CGFloat  = 10
    /// 6 pt — small card or row corner radius.
    static let small: CGFloat = 6
}

// MARK: - Metrics Tokens

/// Miscellaneous scalar constants that don't belong to spacing, radius, or typography.
enum RBMetrics {
    /// Scale factor applied to `ProgressView` in the update action row.
    /// 0.7 keeps the spinner visually consistent with the `.small` control size of adjacent buttons.
    static let updateProgressScale: CGFloat = 0.7
}

// MARK: - Typography Tokens

/// Shared font constants. Prefer these over inline `.system(size:weight:design:)` calls.
enum RBFont {
    /// Caption-sized monospaced font — general-purpose code/metric labels.
    static let mono: Font        = .system(.caption, design: .monospaced)
    /// 11 pt regular monospaced — small metric values.
    static let monoSmall: Font   = .system(size: 11,   weight: .regular,   design: .monospaced)
    /// 13 pt medium — standard row/list label.
    static let label: Font       = .system(size: 13,   weight: .medium)
    /// 12.5 pt regular — section key labels.
    static let sectionKey: Font  = .system(size: 12.5, weight: .regular)
    /// Alias for `sectionKey` — section header labels.
    static let sectionHeader: Font = sectionKey
    /// 9 pt semibold — uppercase section caption badges.
    static let sectionCaption: Font = .system(size: 9, weight: .semibold)
    /// 9 pt semibold monospaced — stat label (CPU, MEM, etc.).
    static let statLabel: Font   = .system(size: 9,  weight: .semibold, design: .monospaced)
    /// 10 pt regular monospaced — numeric stat value.
    static let statValue: Font   = .system(size: 10, weight: .regular,  design: .monospaced)
}
