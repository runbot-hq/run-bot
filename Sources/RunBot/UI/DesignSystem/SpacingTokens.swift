// SpacingTokens.swift
// RunBot
import CoreGraphics

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
