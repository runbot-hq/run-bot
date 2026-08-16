// MigrationWorkflowRowFormatting.swift
// RunBot

import Foundation

// MARK: - MigrationRowDateFormatter

/// Shared compact date formatter used by workflow and job rows.
///
/// Produces strings like "Aug 16, 13:44" — no seconds, no time zone.
/// Defined once here so both row types use an identical format.
final class MigrationRowDateFormatter: @unchecked Sendable {

    /// Shared instance.
    static let shared = MigrationRowDateFormatter()

    /// Underlying `DateFormatter` configured for compact output.
    private let formatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, HH:mm"
        return dateFormatter
    }()

    /// Private initialiser; use `shared`.
    private init() {}

    /// Formats `date` as e.g. "Aug 16, 13:44".
    func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
