// FormatElapsed.swift
// RunBotCore
import Foundation

/// Returns a human-readable `mm:ss` elapsed duration string.
///
/// Centralises the elapsed-time formatting logic shared by `ActiveJob`,
/// `JobStep`, and `WorkflowActionGroup+Progress` so that any future
/// change to the display format (e.g. switching to `h:mm:ss` for long
/// runs) only needs to be made in one place.
///
/// - Parameters:
///   - start: The start date, or `nil` if timing data is unavailable.
///   - end:   The end date, or `nil` to use `Date()` (i.e. still running).
///   - isCompleted: When `true` and `start` is `nil`, returns `"--:--"`
///     (timing data unavailable) instead of `"00:00"` (not yet started).
/// - Returns: A `mm:ss` string such as `"02:47"`, or a sentinel value
///   (`"--:--"` / `"00:00"`) when timing data is absent.
public func formatElapsed(
    start: Date?,
    end: Date?,
    isCompleted: Bool,
    now: Date = Date()
) -> String {
    guard let start else {
        return isCompleted ? "--:--" : "00:00"
    }
    let resolved = end ?? now
    let secs = max(0, Int(resolved.timeIntervalSince(start)))
    return String(format: "%02d:%02d", secs / 60, secs % 60)
}
