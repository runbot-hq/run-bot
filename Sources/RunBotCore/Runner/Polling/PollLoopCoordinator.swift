// PollLoopCoordinator.swift
// RunBotCore
import Foundation

// MARK: - PollLoopCoordinator

/// Owns the two `Task` handles that drive `RunnerPoller`'s poll loop.
///
/// `RunnerPoller` holds this as a stored property, so all mutation is serialised
/// by the actor's own executor — no additional isolation annotation is needed
/// during normal operation.
///
/// **`@unchecked Sendable` — PRINCIPLE #4 EXCEPTION (documented sign-off)**
///
/// Project Principle #4 states: "no `@unchecked Sendable` escape hatches in
/// production types." `PollLoopCoordinator` is a production type that carries
/// this conformance. The exception is intentional and safe for the following
/// reasons, recorded here as the required sign-off:
///
/// 1. **Owned by a single actor.** `PollLoopCoordinator` is stored as
///    `private let pollLoop` on `RunnerPoller`. Swift actors serialise all
///    access to their stored properties on their own executor, so every call
///    to `setPollTask` and `setScopeObservationTask` is already serialised
///    without any additional locking.
///
/// 2. **`deinit` performs no reads or writes that race with concurrent callers.**
///    By the time `deinit` runs, all strong references are gone, so there are
///    no concurrent callers. Within `deinit`, `cancelAll()` calls `Task.cancel()`
///    (safe from any context) and then nils the stored handles. Both operations
///    are safe for exactly the same reason: no other code can observe or mutate
///    those properties after the last strong reference is released.
///
/// 3. **`deinit` runs after all strong references are gone.** By the time
///    `RunnerPoller.deinit` (and therefore `PollLoopCoordinator.deinit`) runs,
///    no concurrent mutation of the coordinator's task handles is possible.
///
/// The root cause of the conformance requirement is that Swift 6 forbids
/// accessing a stored property of a non-`Sendable` type from a nonisolated
/// `deinit`. Making the coordinator an `actor` would satisfy the compiler
/// without `@unchecked Sendable`, but would require every setter to be
/// `async` and every `deinit` call-site to spawn a detached `Task` — a
/// worse trade-off for a type that is only ever touched from one actor.
/// This exception is preferable; file a follow-up if a second store ever
/// needs to own a `PollLoopCoordinator`.
///
/// **Why a dedicated type?**
/// Swift's `private` modifier is file-scoped, not type-scoped. The poll-loop
/// state (`pollTask`, `scopeObservationTask`) cannot be moved into
/// `RunnerPoller+PollLoop.swift` as raw stored properties without widening
/// their access to `internal`. Wrapping them here makes the coordinator itself
/// `internal` while keeping the individual task slots private.
///
/// **PR-D review sign-off — all findings resolved (2026-06-21)**
///
/// The final review pass raised three findings; all are closed:
/// - 🔵 Sign-off comment precision: "no writes" → "no reads or writes that race
///   with concurrent callers" (point 2 above; `cancelAll()` does nil handles,
///   which is safe post-last-reference but is a mutable write — now stated
///   accurately).
/// - 🟡 `isSampling` rapid stop→start liveness: fixed in `SystemStatsViewModel`
///   via `samplingGeneration` counter — stale task's `defer` is a no-op
///   against a newer generation.
/// - 🔵 `#1256` tracking issue: confirmed closed 2026-06-09; `RunnerStore+PollLoop`
///   comment updated to note supersession by this PR.
final class PollLoopCoordinator: @unchecked Sendable {

    // MARK: - Stored task handles
    // These are intentionally private (not private(set)) — no external caller
    // needs to read raw Task handles. cancelAll() and the setters are the full
    // public surface for task lifecycle management.

    /// Active structured poll task. Cancelled and replaced on every `start()` call.
    private var pollTask: Task<Void, Never>?
    /// Observation task that restarts the poll loop when `activeScopes` changes.
    private var scopeObservationTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a new coordinator with all task handles set to `nil`.
    /// Called exclusively from `RunnerPoller.init` via `private let pollLoop = PollLoopCoordinator()`.
    init() {}

    // ⚠️ Load-bearing deinit: RunnerPoller's poll task captures `self` (RunnerPoller)
    // strongly via `while let self`. The cycle (RunnerPoller → pollLoop → Task → RunnerPoller)
    // is broken here — cancelAll() cancels the task, releasing its strong reference and
    // allowing ARC to complete deallocation. Do not remove cancelAll() from this deinit
    // without restoring [weak self] in RunnerPoller.start()'s poll task closure.
    deinit { cancelAll() }

    // MARK: - Mutation

    /// Cancels the existing poll task (if any) and replaces it with `task`.
    /// Passing `nil` cancels without installing a replacement.
    func setPollTask(_ task: Task<Void, Never>?) {
        pollTask?.cancel()
        pollTask = task
    }

    /// Cancels the existing scope-observation task (if any) and replaces it with `task`.
    /// Passing `nil` cancels without installing a replacement.
    func setScopeObservationTask(_ task: Task<Void, Never>?) {
        scopeObservationTask?.cancel()
        scopeObservationTask = task
    }

    /// Cancels both tasks and nils their handles.
    ///
    /// Niling after cancel keeps this method consistent with the setter contract
    /// (`setPollTask(nil)` also nils) and releases the `Task` references immediately,
    /// leaving the coordinator in a clean, fully-reset state.
    /// Called from `RunnerPoller.deinit` and this type's own `deinit`.
    func cancelAll() {
        pollTask?.cancel()
        pollTask = nil
        scopeObservationTask?.cancel()
        scopeObservationTask = nil
    }
}
