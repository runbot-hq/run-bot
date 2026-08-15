// MigrationStatusIndicator.swift
// RunBot

import SwiftUI

/// Small circular status dot for workflow, job, and step rows.
struct MigrationStatusIndicator: View {
    /// The status whose colour fills the indicator circle.
    let status: RBStatus

    /// The status dot.
    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 10, height: 10)
            .padding(.top, 5)
    }
}
