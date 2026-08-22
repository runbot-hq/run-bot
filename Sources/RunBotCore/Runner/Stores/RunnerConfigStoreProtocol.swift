// RunnerConfigStoreProtocol.swift
// RunBotCore
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation

// MARK: - RunnerConfigStoreProtocol

/// Abstraction over `RunnerConfigStore` that enables test doubles.
///
/// `RunnerConfigStore` conforms to this protocol. Inject a spy in unit tests;
/// pass `RunnerConfigStore.shared` in production.
public protocol RunnerConfigStoreProtocol: Sendable {
    /// Loads the typed runner config from `installPath/.runner`.
    func load(at installPath: String) async throws(RunnerConfigStoreError) -> RunnerConfig
    /// Saves the typed runner config to `installPath/.runner`.
    ///
    /// `config` is declared `borrowing` — conformers must not consume or transfer
    /// the value (e.g. store it in an actor property or pass it `consuming`). Read
    /// it for encoding only; copy explicitly with `copy config` if persistence is needed.
    ///
    /// - Parameters:
    ///   - config: The runner configuration to save. Borrowing; do not consume or transfer. Read-only for encoding. Copy explicitly with `copy config` if persistence is needed.
    ///   - installPath: The file system path where the runner config will be saved.
    /// - Throws: `RunnerConfigStoreError` if there is a failure saving the config.
    func save(_ config: borrowing RunnerConfig, at installPath: String) async throws(RunnerConfigStoreError)
}
