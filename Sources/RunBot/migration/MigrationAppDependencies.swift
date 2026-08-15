// MigrationAppDependencies.swift
// RunBot
import Observation
import RunBotCore

// MARK: - MigrationAppDependencies

/// Owns and configures the minimum domain dependencies required by the windowed app.
///
/// `LocalRunnerStore.configure(viewModel:)` must be the very first call,
/// synchronously, before any view is mounted. This mirrors the ordering rule
/// documented in `AppDelegate+StoreSetup.swift` (fix for issue #1741).
@MainActor
@Observable
final class MigrationAppDependencies {
    let runnerState: RunnerState
    let localRunnerStore: LocalRunnerStore

    init() {
        let state = RunnerState()
        self.runnerState = state
        LocalRunnerStore.configure(viewModel: state)
        self.localRunnerStore = LocalRunnerStore.shared
    }
}
