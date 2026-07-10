// TestDoubles.swift
// RunBotCoreTests
// Shared test doubles — extracted per #1447.
import Foundation
import RunBotCore

// MARK: - SpyLabelsService

/// Spy conformance for `RunnerLabelsService`.
///
/// Implemented as an `actor` so Swift's compiler enforces isolation without
/// requiring `@unchecked Sendable`. The `result` and recorded-call properties
/// are accessed from the test body before/after `execute(...)` — never concurrently.
actor SpyLabelsService: RunnerLabelsService {
    // MARK: Stub return values
    // Note: defaults to [] (empty array), not nil — tests that don't call setUp will
    // silently receive an empty label list rather than a failure. Configure via setUp(result:).
    private var result: [String]? = []

    // MARK: Observation (assert on after execute)
    private(set) var callCount = 0
    private(set) var lastScope: String?
    private(set) var lastRunnerID: Int?
    private(set) var lastLabels: [String]?

    /// Configures the value returned by `patch(...)`. Call from the test body before `execute`.
    func setUp(result: [String]?) { self.result = result }

    func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]? {
        callCount += 1
        lastScope = scope
        lastRunnerID = runnerID
        lastLabels = labels
        return result
    }
}

// MARK: - SpyConfigStore

/// Spy conformance for `RunnerConfigStoreProtocol`.
///
/// Implemented as an `actor` — see `SpyLabelsService` for rationale.
actor SpyConfigStore: RunnerConfigStoreProtocol {
    // MARK: Stub return values
    /// Mutable by design — set from the test body to control what `load(at:)` returns.
    var loadResult: RunnerConfig = RunnerConfig(workFolder: "_work", disableUpdate: false)

    // MARK: Throw-control flags (configure via setUp)
    private var shouldThrowOnSave                = false
    private var shouldThrowOnLoad                = false
    private var shouldThrowOnDecode              = false
    private var shouldThrowMalformedOnSave       = false
    private var shouldThrowIOReadFailedOnSave    = false

    // MARK: Observation (assert on after execute)
    private(set) var saveCalled = false
    private(set) var savedConfig: RunnerConfig?

    /// Configures throw behaviour for all operations in a single call, resetting any
    /// previously set flags. Omitted parameters default to `false` (no throw).
    func setUp(
        shouldThrowOnSave: Bool               = false,
        shouldThrowOnLoad: Bool               = false,
        shouldThrowOnDecode: Bool             = false,
        shouldThrowMalformedOnSave: Bool      = false,
        shouldThrowIOReadFailedOnSave: Bool   = false
    ) {
        self.shouldThrowOnSave              = shouldThrowOnSave
        self.shouldThrowOnLoad              = shouldThrowOnLoad
        self.shouldThrowOnDecode            = shouldThrowOnDecode
        self.shouldThrowMalformedOnSave     = shouldThrowMalformedOnSave
        self.shouldThrowIOReadFailedOnSave  = shouldThrowIOReadFailedOnSave
    }

    func load(at installPath: String) async throws(RunnerConfigStoreError) -> RunnerConfig {
        if shouldThrowOnLoad   { throw RunnerConfigStoreError.readFailed(installPath, TestError.saveFailed) }
        if shouldThrowOnDecode { throw RunnerConfigStoreError.decodeFailed(installPath) }
        return loadResult
    }
    func save(_ config: borrowing RunnerConfig, at installPath: String) async throws(RunnerConfigStoreError) {
        // Copy the borrowed value before storing — a `borrowing` parameter cannot be consumed.
        let config = copy config
        // Flag priority: shouldThrowOnSave (.writeFailed) fires first, then
        // shouldThrowMalformedOnSave, then shouldThrowIOReadFailedOnSave.
        // Setting more than one simultaneously is not meaningful — configure
        // exactly one throw flag per test to avoid ambiguity.
        if shouldThrowOnSave             { throw RunnerConfigStoreError.writeFailed(installPath, TestError.saveFailed) }
        if shouldThrowMalformedOnSave    { throw RunnerConfigStoreError.malformedExistingFile(installPath) }
        if shouldThrowIOReadFailedOnSave { throw RunnerConfigStoreError.ioReadFailedDuringSave(installPath, TestError.saveFailed) }
        saveCalled = true
        savedConfig = config
    }
}

// MARK: - SpyProxyStore

/// Spy conformance for `RunnerProxyStoreProtocol`.
///
/// Implemented as an `actor` — see `SpyLabelsService` for rationale.
actor SpyProxyStore: RunnerProxyStoreProtocol {
    // MARK: Throw-control flags (configure via setUp)
    private var shouldThrowOnSave = false

    // MARK: Observation (assert on after execute)
    private(set) var saveCalled = false
    private(set) var savedConfig: RunnerProxyConfig?

    /// Configures throw behaviour for all operations in a single call, resetting any
    /// previously set flags. Omitted parameters default to `false` (no throw).
    func setUp(shouldThrowOnSave: Bool = false) { self.shouldThrowOnSave = shouldThrowOnSave }

    func load(at _: String) async -> RunnerProxyConfig { RunnerProxyConfig() }
    func save(_ config: RunnerProxyConfig, at installPath: String) async throws(RunnerProxyStoreError) {
        if shouldThrowOnSave { throw RunnerProxyStoreError.writeFailed(["spy: save not allowed"]) }
        saveCalled = true
        savedConfig = config
    }
}

// MARK: - HookCounter

/// Actor-isolated counter for tracking fireFailureHook call counts in async tests.
actor HookCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - MockScopePreferencesStore

/// Stub conformance for `ScopePreferencesStoreProtocol` (Actor-constrained).
///
/// Implemented as an `actor` to satisfy the protocol constraint.
/// All stored properties return defaults — only the protocol surface needed by
/// `FailureHookRunnerUseCase` tests is implemented.
actor MockScopePreferencesStore: ScopePreferencesStoreProtocol {
    func preferences(for _: String) -> ScopePreferences { ScopePreferences() }
    func setPreferences(_: ScopePreferences, for _: String) {}
    func alias(for _: String) -> String? { nil }
    func setAlias(_: String?, for _: String) {}
    func displayName(for scope: String) -> String { scope }
    func pollingInterval(for _: String) -> Int? { nil }
    func setPollingInterval(_: Int?, for _: String) {}
    func notifyOnSuccess(for _: String) -> Bool? { nil }
    func setNotifyOnSuccess(_: Bool?, for _: String) {}
    func notifyOnFailure(for _: String) -> Bool? { nil }
    func setNotifyOnFailure(_: Bool?, for _: String) {}
    func cleanUp(scope _: String) {}
    func modifyPreferences(for _: String, with mutation: @Sendable (inout ScopePreferences) -> Void) {
        var prefs = ScopePreferences()
        mutation(&prefs)
    }
}

// MARK: - SpyTerminalLauncher

/// Spy conformance for `TerminalLauncherProtocol`.
///
/// `final class` + `@unchecked Sendable`: `open(command:)` is `@MainActor` so
/// all mutations of `openCallCount` and `lastCommand` occur exclusively on the
/// main actor — `@unchecked` is safe here.
final class SpyTerminalLauncher: TerminalLauncherProtocol, @unchecked Sendable {
    private(set) var openCallCount = 0
    private(set) var lastCommand: String?

    @MainActor func open(_ command: String) {
        openCallCount += 1
        lastCommand = command
    }
}

// MARK: - TestError

enum TestError: Error { case saveFailed }
