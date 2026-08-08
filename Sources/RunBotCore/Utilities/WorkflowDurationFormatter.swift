// WorkflowDurationFormatter.swift
// RunBot
import Foundation

/// Formats workflow durations for compact user-facing presentation.
public enum WorkflowDurationFormatter {
    /// Returns a compact duration using `h`, `min`, and `sec` units.
    ///
    /// Rounds to the nearest whole second, omits zero-value units, and permits
    /// hour values greater than 24.
    ///
    /// Examples:
    /// - `0` → `"0sec"`
    /// - `272` → `"4min 32sec"`
    /// - `3_872` → `"1h 4min 32sec"`
    public static func string(from duration: TimeInterval) -> String {
        let totalSeconds = Int(max(0, duration).rounded())
        let hours   = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        var parts: [String] = []

        if hours > 0 {
            parts.append("\(hours)h")
        }

        if minutes > 0 {
            parts.append("\(minutes)min")
        }

        if seconds > 0 || parts.isEmpty {
            parts.append("\(seconds)sec")
        }

        return parts.joined(separator: " ")
    }
}
