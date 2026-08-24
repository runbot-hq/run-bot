// MetricsTokens.swift
// RunBot
import CoreGraphics

// MARK: - Metrics Tokens

/// Miscellaneous scalar constants that don't belong to spacing, radius, or typography.
enum RBMetrics {
    /// Scale factor applied to `ProgressView` in the update action row.
    /// 0.7 keeps the spinner visually consistent with the `.small` control size of adjacent buttons.
    static let updateProgressScale: CGFloat = 0.7
    /// Maximum width for the commit/PR title label in `ActionRowView` (#2130).
    /// Caps the greedy `.layoutPriority(1)` text so it can't consume the full row width.
    /// The existing `.lineLimit(1)` + `.truncationMode(.tail)` produce an ellipsis at this cap.
    static let actionRowTitleMaxWidth: CGFloat = 160
    /// Maximum width for the head-branch label in `ActionRowView`.
    /// Kept narrower than `actionRowTitleMaxWidth` since branch names are lower priority (#1194).
    static let actionRowBranchMaxWidth: CGFloat = 80
}
