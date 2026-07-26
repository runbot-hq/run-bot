// GitHubTransportShims.swift
// GitHubClient

import Foundation

// MARK: - Process-wide transport instance

/// Internal backing storage for the process-wide default transport.
///
/// Written exactly once by `GitHubClient.init` (the production init) before
/// any concurrent reads, satisfying the once-written invariant that makes
/// `nonisolated(unsafe)` safe here. All internal shim functions read this
/// indirectly via `currentTransport`.
///
/// WHY `nonisolated(unsafe)` (not a global actor or a lock):
/// - `GitHubClient.init` is `@MainActor`-isolated and runs before any shim
///   is called, so the write always precedes all reads — no data race in
///   practice.
/// - A `@MainActor` annotation on a module-level var would force every shim
///   call site to be `@MainActor`-isolated or async, which is unnecessarily
///   viral for a read-only-after-init global.
/// - A `Mutex` or `OSAllocatedUnfairLock` would add synchronisation overhead
///   on every shim call for a value that never changes after init.
/// - `nonisolated(unsafe)` opts out of the Swift 6 actor-isolation check and
///   shifts the safety proof to the once-written invariant above. If you are
///   reading this because you want to write to this var outside of
///   `GitHubClient.init`, stop — add a new property on `GitHubClient` instead.
nonisolated(unsafe) internal var sharedTransportStorage: any GitHubTransportProtocol = GitHubTransport()

// MARK: - @TaskLocal transport

/// Task-local override for the active transport, scoped to the current task tree.
///
/// `nil` by default — `nil` is a value-type constant and is safe to freeze at
/// module load. The public `currentTransport` computed property resolves `nil`
/// to `sharedTransportStorage` at access time, picking up the live authenticated
/// instance wired by `GitHubClient.init`.
///
/// Do not read this directly. Use `currentTransport` or `withTransport(_:operation:)`.
@TaskLocal private var taskLocalTransport: (any GitHubTransportProtocol)?

/// The effective transport for the current task.
///
/// Returns the innermost `withTransport` override if one is in scope;
/// otherwise falls back to `sharedTransportStorage` — the live authenticated
/// instance wired by `GitHubClient.init` — evaluated at call time.
///
/// WHY `var` AND NOT `let`:
/// Swift requires `var` for any property with a getter body — `let` is a
/// syntax error for a computed property. This is a read-only computed accessor
/// with no setter; the `var` keyword carries no mutability implication here.
/// There is no stored backing field and no write path. The compiler enforces
/// immutability: any attempt to assign to `currentTransport` is a compile error
/// ("cannot assign to property: 'currentTransport' is a get-only property").
///
/// WHY `nonisolated` IS NOT NEEDED HERE:
/// `@TaskLocal` storage is task-scoped, not actor-scoped. Reading
/// `taskLocalTransport` does not require an actor hop and is safe from any
/// isolation context. `sharedTransportStorage` carries its own
/// `nonisolated(unsafe)` annotation. There is no isolation mismatch to resolve.
public var currentTransport: any GitHubTransportProtocol {
    taskLocalTransport ?? sharedTransportStorage
}

/// Scopes a transport override to the current task and all child tasks.
///
/// Use in tests to inject a mock without touching any global:
/// ```swift
/// await withTransport(MockTransport()) {
///     let orgs = await fetchUserOrgs()
/// }
/// ```
///
/// WHY `nonisolated`:
/// Task-local storage is task-scoped, not actor-scoped. There is no actor
/// state to protect and no hop needed. Marking `nonisolated` lets callers
/// on any actor (including `@MainActor`-isolated `AppDelegate`) call this
/// without an isolation mismatch warning.
///
/// The `@Sendable` closure and `T: Sendable` bound are required because
/// `$taskLocalTransport.withValue` crosses task boundaries under strict
/// concurrency checking.
nonisolated public func withTransport<T: Sendable>(
    _ transport: any GitHubTransportProtocol,
    operation: @Sendable () async throws -> T
) async rethrows -> T {
    try await $taskLocalTransport.withValue(transport, operation: operation)
}

// MARK: - Domain shims

/// Thin GET alias used widely across the module.
@concurrent
public func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await currentTransport.apiAsync(endpoint, timeout: timeout)
}

/// Fire-and-forget POST alias. Returns `true` on 2xx.
@concurrent
@discardableResult
public func ghPost(_ endpoint: String) async -> Bool {
    let transport = currentTransport
    let result = await transport.post(endpoint)
    let success = result != nil
    transport.logger?.log("ghPost › \(endpoint) success=\(success)", category: "transport")
    return success
}

/// Deregisters a runner from GitHub via DELETE.
@concurrent
@discardableResult
public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
    await currentTransport.deleteRunnerByID(scope: scopeString, runnerID: runnerID)
}

/// Replaces all custom labels on a runner.
@concurrent
@discardableResult
public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    await currentTransport.patchRunnerLabels(scope: scopeString, runnerID: runnerID, labels: labels)
}

/// Fetches a runner registration token.
@concurrent
public func fetchRegistrationToken(scope scopeString: String) async -> String? {
    await currentTransport.fetchRegistrationToken(scope: scopeString)
}

/// Fetches a runner removal token.
@concurrent
public func fetchRemovalToken(scope scopeString: String) async -> String? {
    await currentTransport.fetchRemovalToken(scope: scopeString)
}

/// Cancels a workflow run.
@concurrent
@discardableResult
public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    await currentTransport.cancelRun(runID: runID, scope: scopeString)
}
