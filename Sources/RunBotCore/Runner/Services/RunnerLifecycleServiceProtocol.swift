// RunnerLifecycleServiceProtocol.swift
// RunBotCore
import Foundation

// MARK: - RunnerLifecycleServiceProtocol

/// Abstraction over macOS launchctl runner lifecycle operations (start, stop, remove).
///
/// Introduced so the local-runner UI and any future consumers can depend on the
/// protocol rather than the concrete `RunnerLifecycleService`, enabling unit testing
/// with a stub that does not spawn real `svc.sh` processes.
///
/// `Sendable` conformance is required so the existential can be stored as a
/// `let` inside `@MainActor` views without triggering isolation warnings (P4).
///
/// ## Production usage
/// ```swift
/// let lifecycleService: any RunnerLifecycleServiceProtocol = RunnerLifecycleService()
/// ```
///
/// ## Test double
/// ```swift
/// struct StubLifecycleService: RunnerLifecycleServiceProtocol {
///     func start(runner: RunnerModel) async -> LifecycleResult { .success }
///     func stop(runner: RunnerModel) async -> LifecycleResult { .success }
///     func remove(runner: RunnerModel) async -> LifecycleResult { .success }
/// }
/// ```
public protocol RunnerLifecycleServiceProtocol: Sendable {
    /// Starts the runner's launchctl service. Returns `.success` or a failure/corrupt-install result.
    @discardableResult
    func start(runner: RunnerModel) async -> LifecycleResult
    /// Stops the runner's launchctl service. Returns `.success` or a failure/corrupt-install result.
    @discardableResult
    func stop(runner: RunnerModel) async -> LifecycleResult
    /// Removes the runner via `svc.sh remove` and unregisters it from GitHub.
    /// Returns `.success` on full deregistration, `.failed` if deregistration failed,
    /// or `.corruptInstall` if both `config.sh` and the API fallback detected a broken install.
    @discardableResult
    func remove(runner: RunnerModel) async -> LifecycleResult
}
