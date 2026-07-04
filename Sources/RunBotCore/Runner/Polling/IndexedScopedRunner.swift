// IndexedScopedRunner.swift
// RunBotCore

import GitHubClient

// MARK: - IndexedScopedRunner

/// Carries a scope-fetched `GitHubRunner` alongside its source-scope string.
/// Used internally by `fetchAndEnrichRunners` to pass data through two
/// concurrent `withTaskGroup` phases without a 3-member tuple
/// (which would trigger the `large_tuple` SwiftLint rule).
///
/// ⚠️ The ordering of entries in the `indexed` array after Phase 1 is
/// non-deterministic: `withTaskGroup` tasks complete in arrival order.
/// This matches the previous `RunnerStore` behaviour; views sort
/// runners independently for display.
///
/// `fileprivate` would be narrower than `internal`, but this type is
/// accessed from `RunnerPoller+FetchAndEnrich.swift` — a separate file
/// in the same module — so `fileprivate` would confine it to this file
/// only and cause a compile error in that extension. `internal` (the
/// default) is therefore the narrowest correct access level given the
/// cross-file usage. This type has no intended public API surface and
/// is an implementation detail of `RunnerPoller.fetchAndEnrichRunners`.
///
/// **Sendable conformance**
/// Both stored properties are `let` and `GitHubRunner` is a value type, so
/// Swift synthesises unconditional `Sendable` conformance automatically.
/// No `@unchecked` annotation is needed.
struct IndexedScopedRunner: Sendable {
    /// The GitHub scope URL string (repo or org) this runner belongs to.
    let scope: String
    /// The enriched `GitHubRunner` value.
    /// Immutable — Phase 2 produces a new `IndexedScopedRunner` via
    /// `IndexedScopedRunner(scope:runner:)` rather than mutating this field.
    let runner: GitHubRunner
    /// The locally-resolved CPU/memory snapshot for this runner, if any.
    ///
    /// Populated by `enrichBusyRunners` during Phase 2 of `fetchAndEnrichRunners`.
    /// `GitHubRunner` does not store metrics (it is a pure API model), so the
    /// metrics are carried here alongside the runner until `applyMetrics` writes
    /// them back to the local store.
    let metrics: RunnerMetrics?

    /// Creates an `IndexedScopedRunner`.
    /// - Parameters:
    ///   - scope: The GitHub scope URL string (repo or org) this runner belongs to.
    ///   - runner: The enriched `GitHubRunner` value.
    ///   - metrics: The locally-resolved CPU/memory snapshot, if any.
    init(scope: String, runner: GitHubRunner, metrics: RunnerMetrics? = nil) {
        self.scope = scope
        self.runner = runner
        self.metrics = metrics
    }
}
