// MockUpdateState.swift
// AppUpdaterTests
import Foundation
@testable import AppUpdater

// MARK: - MockUpdateState

/// A recording test double for `UpdateStateProviding`.
///
/// Stores the most recent `UpdatePhase` applied and records every call to
/// `apply(_:)` in order, so tests can assert both the resulting phase and the
/// full sequence of transitions `AppUpdater` drove.
@MainActor
final class MockUpdateState: UpdateStateProviding {

    /// The current update phase; starts at `.idle`.
    private(set) var currentPhase: UpdatePhase = .idle

    /// Every phase passed to `apply(_:)`, in call order.
    private(set) var appliedPhases: [UpdatePhase] = []

    func apply(_ phase: UpdatePhase) {
        currentPhase = phase
        appliedPhases.append(phase)
    }

    /// Resets the mock to its initial state between tests.
    func reset() {
        currentPhase = .idle
        appliedPhases = []
    }
}
