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
    /// Observable runner state that `LocalRunnerStore` pushes snapshots into.
    let runnerState: RunnerState
    /// The configured local-runner store, ready for injection into views.
    let localRunnerStore: LocalRunnerStore

    /// Configures `LocalRunnerStore` synchronously then captures the shared instance.
    init() {
        let state = RunnerState()
        self.runnerState = state
        LocalRunnerStore.configure(viewModel: state)
        self.localRunnerStore = LocalRunnerStore.shared
    }
}
