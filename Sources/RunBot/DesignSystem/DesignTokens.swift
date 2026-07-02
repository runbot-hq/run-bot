// DesignTokens.swift
// RunBot
import AppKit
import RunBotCore
import SwiftUI

// MARK: - Adaptive Color Helper

/// Helpers for creating appearance-adaptive `Color` values that respond to light/dark mode.
extension Color {
    /// Returns a color that resolves to `light` in light-appearance contexts and `dark` in dark-appearance contexts.
    /// Covers all dark-family appearances including vibrant dark and high-contrast variants.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil) { appearance in
            let darkMatches: [NSAppearance.Name] = [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]
            let best = appearance.bestMatch(from: darkMatches + [.aqua])
            return darkMatches.contains(best ?? .aqua)
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}

// MARK: - Color Tokens

/// Semantic color tokens used throughout RunBot for status, surface, and text styling.
extension Color {
    /// Primary blue accent — adaptive light/dark pair for in-progress status indicators.
    static let rbBlue = Color.adaptive(
        light: Color(red: 0.0, green: 0.48, blue: 1.0),
        dark: Color(red: 0.3, green: 0.64, blue: 1.0)
    )
    /// Green success color — adaptive light/dark pair for completed / passing status.
    static let rbSuccess = Color.adaptive(
        light: Color(red: 0.18, green: 0.64, blue: 0.18),
        dark: Color(red: 0.25, green: 0.80, blue: 0.25)
    )
    /// Amber warning color — adaptive light/dark pair for queued / pending status.
    static let rbWarning = Color.adaptive(
        light: Color(red: 0.80, green: 0.55, blue: 0.05),
        dark: Color(red: 1.0, green: 0.75, blue: 0.20)
    )
    /// Red danger color — adaptive light/dark pair for failed / error status.
    static let rbDanger = Color.adaptive(
        light: Color(red: 0.85, green: 0.18, blue: 0.18),
        dark: Color(red: 1.0, green: 0.35, blue: 0.35)
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

    /// Base panel background surface.
    /// macOS 26+: near-zero opacity so glass backdrop shows through.
    /// Pre-26: standard vibrancy opacities.
    static var rbSurface: Color {
        if #available(macOS 26, *) {
            return Color.adaptive(
                light: Color(white: 0.95).opacity(0.04),
                dark: Color(white: 0.11).opacity(0.04)
            )
        } else {
            return Color.adaptive(
                light: Color(white: 0.95).opacity(0.88),
                dark: Color(white: 0.11).opacity(0.45)
            )
        }
    }

    /// Elevated row/card surface — slightly lighter than `rbSurface`.
    /// macOS 26+: near-zero opacity so glass backdrop shows through.
    /// Pre-26: standard vibrancy opacities.
    static var rbSurfaceElevated: Color {
        if #available(macOS 26, *) {
            return Color.adaptive(
                light: Color(white: 0.88).opacity(0.05),
                dark: Color(white: 0.15).opacity(0.05)
            )
        } else {
            return Color.adaptive(
                light: Color(white: 0.88).opacity(0.92),
                dark: Color(white: 0.15).opacity(0.25)
            )
        }
    }

    /// Subtle border — low-contrast outline for cards and separators.
    /// macOS 26+: light opacity bumped to 0.12 for better visibility on glass.
    static var rbBorderSubtle: Color {
        if #available(macOS 26, *) {
            return Color.adaptive(
                light: Color(white: 0.0).opacity(0.12),
                dark: Color(white: 1.0).opacity(0.06)
            )
        } else {
            return Color.adaptive(
                light: Color(white: 0.0).opacity(0.08),
                dark: Color(white: 1.0).opacity(0.06)
            )
        }
    }

    /// Primary text — high contrast body and heading text.
    static let rbTextPrimary = Color.adaptive(
        light: .black,
        dark: .white
    )
    /// Secondary text — reduced-emphasis labels and descriptions.
    static let rbTextSecondary = Color.adaptive(
        light: Color(white: 0.40),
        dark: Color(white: 0.55)
    )
    /// Tertiary text — lowest-emphasis metadata and timestamps.
    static let rbTextTertiary = Color.adaptive(
        light: Color(white: 0.58),
        dark: Color(white: 0.39)
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
    static let xs: CGFloat = 4
    /// 6 pt — tight gap between related elements.
    static let sm: CGFloat = 6
    /// 10 pt — default row horizontal padding.
    static let md: CGFloat = 10
}

/// Corner-radius constants for consistent rounding across components.
enum RBRadius {
    /// 10 pt — standard card corner radius.
    static let card: CGFloat = 10
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
    static let mono: Font = .system(.caption, design: .monospaced)
    /// 11 pt regular monospaced — small metric values.
    static let monoSmall: Font = .system(size: 11, weight: .regular, design: .monospaced)
    /// 13 pt medium — standard row/list label.
    static let label: Font = .system(size: 13, weight: .medium)
    /// 12.5 pt regular — section key labels.
    static let sectionKey: Font = .system(size: 12.5, weight: .regular)
    /// Alias for `sectionKey` — section header labels.
    static let sectionHeader: Font = sectionKey
    /// 9 pt semibold — uppercase section caption badges.
    static let sectionCaption: Font = .system(size: 9, weight: .semibold)
    /// 9 pt semibold monospaced — stat label (CPU, MEM, etc.).
    static let statLabel: Font = .system(size: 9, weight: .semibold, design: .monospaced)
    /// 10 pt regular monospaced — numeric stat value.
    static let statValue: Font = .system(size: 10, weight: .regular, design: .monospaced)
}
