// MigrationRowMetadata.swift
// RunBot

import SwiftUI

/// Compact secondary metadata line shown below a row title.
///
/// Accepts an array of optional strings. Nil and empty values are filtered out
/// so no separator is inserted between empty fields.
struct MigrationRowMetadata: View {
    let values: [String?]

    private var items: [String] {
        values.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    /// The metadata line — hidden when all values are empty.
    var body: some View {
        if !items.isEmpty {
            Text(items.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
