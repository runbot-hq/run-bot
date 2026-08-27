// Color+RunnerModel.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - Color extension for RunnerModel.StatusColor

/// Design-system `Color` mapping for `RunnerModel.StatusColor`.
///
/// Centralises the runner-status dot colour used by `LocalRunnersView`
/// and `RunnerDetailSheet` (resolves #1643).
extension RunnerModel.StatusColor {
    /// The design-system `Color` that represents this status category.
    ///
    /// - `.running`  → `Color.rbSuccess`      (green — agent process is up, idle)
    /// - `.busy`     → `Color.rbWarning`       (amber — agent is executing a job)
    /// - `.idle`     → `Color.rbTextTertiary`  (grey  — not running locally, GitHub online)
    /// - `.offline`  → `Color.rbDanger`        (red   — offline or lifecycle error)
    var color: Color {
        switch self {
        case .running: return Color.rbSuccess
        case .busy:    return Color.rbWarning
        case .idle:    return Color.rbTextTertiary
        case .offline: return Color.rbDanger
        }
    }
}
