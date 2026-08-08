// WorkflowDurationFormatter.swift
// RunBot
import Foundation

/// Formats completed workflow durations using compact stopwatch notation.
public enum WorkflowDurationFormatter {
    /// Returns `mm:ss` below one hour and `h:mm:ss` at one hour or above.
    ///
    /// The duration is rounded to the nearest whole second. Negative input is
    /// clamped to zero. Hours are not capped or zero-padded.
    ///
    /// Examples:
    /// - `0`      → `"00:00"`
    /// - `272`    → `"04:32"`
    /// - `3_872`  → `"1:04:32"`
    public static func string(from duration: TimeInterval) -> String {
        let totalSeconds = Int(max(0, duration).rounded())
        let hours   = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                seconds
            )
        }

        let totalMinutes = totalSeconds / 60

        return String(
            format: "%02d:%02d",
            totalMinutes,
            seconds
        )
    }
}
