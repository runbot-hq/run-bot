// TypographyTokens.swift
// RunBot
import SwiftUI

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
