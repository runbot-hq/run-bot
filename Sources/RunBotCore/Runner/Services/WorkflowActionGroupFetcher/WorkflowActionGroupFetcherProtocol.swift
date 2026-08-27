// WorkflowActionGroupFetcherProtocol.swift
// RunBotCore
//
// Protocol allowing RunnerStore to store an existential instead of a concrete
// WorkflowActionGroupFetcher, making future RunnerStore integration tests easier
// to write (a stub conformer can return a predetermined [WorkflowActionGroup]
// without wiring up an HTTP stub).
//
// - Note: `Sendable` conformance is required so the existential can be stored as
//   a `let` inside `RunnerStore` (a custom `actor`) without triggering
//   non-Sendable-capture warnings at the actor boundary.
import Foundation

// MARK: - WorkflowActionGroupFetcherProtocol

/// Abstraction over fetching and grouping workflow action groups.
///
/// Introduced so that `RunnerStore` depends on an injected fetcher instead of
/// the concrete `WorkflowActionGroupFetcher`, enabling future unit tests of
/// `RunnerStore` itself to supply a stub that returns predetermined groups.
///
/// ## Production usage
/// ```swift
/// RunnerStore(…, actionGroupFetcher: WorkflowActionGroupFetcher())
/// ```
///
/// ## Test double
/// ```swift
/// struct StubActionGroupFetcher: WorkflowActionGroupFetcherProtocol {
///     func fetch(for scope: String, cache: [String: WorkflowActionGroup]) async -> [WorkflowActionGroup] { [] }
/// }
/// ```
public protocol WorkflowActionGroupFetcherProtocol: Sendable {
    /// Fetches active workflow runs for a repo scope, groups them by `head_sha`,
    /// enriches each group with its flattened job list, and returns groups sorted:
    /// in-progress first, then queued, then completed — newest first within each tier.
    ///
    /// - Parameters:
    ///   - scope: A repo scope string in the form `"owner/repo"`. Org scopes (no `/`) return empty.
    ///   - cache: An optional SHA-keyed cache of previously-fetched groups to avoid redundant API calls.
    /// - Returns: An array of `WorkflowActionGroup` values, one per unique `head_sha`.
    ///
    /// - Important: This requirement carries `@concurrent`, which strips the caller's
    ///   actor context. Conformers must be safe to run off any actor's executor.
    ///   An actor-isolated conformer will fail to satisfy this requirement at compile time.
    @concurrent
    func fetch(for scope: String, cache: [String: WorkflowActionGroup]) async -> [WorkflowActionGroup]
}

// MARK: - Default parameter conformance

/// Default `cache` parameter for callers that don't provide one.
extension WorkflowActionGroupFetcherProtocol {
    /// Fetches action groups without a cache.
    public func fetch(for scope: String) async -> [WorkflowActionGroup] {
        await fetch(for: scope, cache: [:])
    }
}
